// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "./GuardianHook.sol";
import "./GuardianHookFactory.sol";
import "./HookMiner.sol";
import { IExtsload } from "@uniswap/v4-core/src/interfaces/IExtsload.sol";
import { IExttload } from "@uniswap/v4-core/src/interfaces/IExttload.sol";
import { IHooks } from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import { Currency } from "@uniswap/v4-core/src/types/Currency.sol";
import { PoolId, PoolIdLibrary } from "@uniswap/v4-core/src/types/PoolId.sol";
import { PoolKey } from "@uniswap/v4-core/src/types/PoolKey.sol";
import { SwapParams } from "@uniswap/v4-core/src/types/PoolOperation.sol";
import { toBalanceDelta } from "@uniswap/v4-core/src/types/BalanceDelta.sol";

contract FrontendDemoPoolManager is IExtsload, IExttload {
    using PoolIdLibrary for PoolKey;

    bytes32 internal constant POOLS_SLOT = bytes32(uint256(6));
    uint256 internal constant LIQUIDITY_OFFSET = 3;
    address public constant DEMO_RVM_ID = address(0xD00D);

    mapping(bytes32 => bytes32) internal slots;

    GuardianHookFactory public immutable hookFactory;
    GuardianHook public immutable guardianHook;
    bytes32 public immutable hookSalt;
    bytes32 public immutable poolId;
    address public immutable predictedHook;

    PoolKey private poolKey;
    bool public demoInitialized;
    uint256 public healthySwapCount;

    event DemoReset(bytes32 indexed poolId);
    event DemoHealthySwap(bytes32 indexed poolId, uint160 sqrtPriceX96, int24 tick);
    event DemoWarningTriggered(bytes32 indexed poolId, string reason);
    event DemoReactivePause(bytes32 indexed poolId, string reason);

    constructor() {
        hookFactory = new GuardianHookFactory();

        bytes32 initCodeHash = keccak256(
            abi.encodePacked(
                type(GuardianHook).creationCode,
                abi.encode(address(this), address(this), address(this))
            )
        );
        (bytes32 minedSalt, address minedHook) =
            HookMiner.find(address(hookFactory), initCodeHash, 0, 200000);
        hookSalt = minedSalt;
        predictedHook = minedHook;
        guardianHook = hookFactory.deploy(address(this), address(this), address(this), minedSalt);

        poolKey = PoolKey({
            currency0: Currency.wrap(address(0x1000)),
            currency1: Currency.wrap(address(0x2000)),
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(address(guardianHook))
        });
        poolId = PoolId.unwrap(poolKey.toId());

        _setPoolState(poolId, uint160(1000), int24(10), uint128(500));
    }

    function initializeDemo() external {
        if (demoInitialized) return;
        demoInitialized = true;

        guardianHook.registerPool(poolKey);
        guardianHook.setTrustedReactiveRvmId(DEMO_RVM_ID);
    }

    function resetDemo() external {
        healthySwapCount = 0;
        _setPoolState(poolId, uint160(1000), int24(10), uint128(500));
        guardianHook.unpausePool(poolId);
        guardianHook.resetPoolAlert(poolId);
        guardianHook.syncPoolState(poolId);

        emit DemoReset(poolId);
    }

    function simulateHealthySwap() external {
        SwapParams memory params = SwapParams({
            zeroForOne: true,
            amountSpecified: int256(10),
            sqrtPriceLimitX96: uint160(0)
        });

        guardianHook.beforeSwap(msg.sender, poolKey, params, "");

        healthySwapCount += 1;
        uint160 nextPrice = uint160(1000 + (healthySwapCount * 100));
        int24 nextTick = int24(int256(10 + healthySwapCount));
        _setPoolState(poolId, nextPrice, nextTick, uint128(500));

        guardianHook.afterSwap(msg.sender, poolKey, params, toBalanceDelta(10, -10), "");

        emit DemoHealthySwap(poolId, nextPrice, nextTick);
    }

    function triggerWarning() external {
        SwapParams memory params = SwapParams({
            zeroForOne: true,
            amountSpecified: int256(10),
            sqrtPriceLimitX96: uint160(0)
        });

        guardianHook.beforeSwap(msg.sender, poolKey, params, "");
        guardianHook.afterSwap(msg.sender, poolKey, params, toBalanceDelta(0, 0), "");

        emit DemoWarningTriggered(poolId, "NO_OP_ALERT");
    }

    function triggerReactivePause(string calldata reason) external {
        guardianHook.reactivePause(DEMO_RVM_ID, poolId, reason);

        emit DemoReactivePause(poolId, reason);
    }

    function extsload(bytes32 slot) external view returns (bytes32 value) {
        return slots[slot];
    }

    function extsload(bytes32 startSlot, uint256 nSlots)
        external
        view
        returns (bytes32[] memory values)
    {
        values = new bytes32[](nSlots);
        for (uint256 i = 0; i < nSlots; i++) {
            values[i] = slots[bytes32(uint256(startSlot) + i)];
        }
    }

    function extsload(bytes32[] calldata querySlots)
        external
        view
        returns (bytes32[] memory values)
    {
        values = new bytes32[](querySlots.length);
        for (uint256 i = 0; i < querySlots.length; i++) {
            values[i] = slots[querySlots[i]];
        }
    }

    function exttload(bytes32) external pure returns (bytes32 value) {
        return value;
    }

    function exttload(bytes32[] calldata querySlots)
        external
        pure
        returns (bytes32[] memory values)
    {
        values = new bytes32[](querySlots.length);
    }

    function _setPoolState(bytes32 id, uint160 sqrtPriceX96, int24 tick, uint128 liquidity)
        internal
    {
        bytes32 stateSlot = keccak256(abi.encodePacked(id, POOLS_SLOT));
        slots[stateSlot] = _encodeSlot0(sqrtPriceX96, tick, 0, 0);
        slots[bytes32(uint256(stateSlot) + LIQUIDITY_OFFSET)] = bytes32(uint256(liquidity));
    }

    function _encodeSlot0(uint160 sqrtPriceX96, int24 tick, uint24 protocolFee, uint24 lpFee)
        internal
        pure
        returns (bytes32 data)
    {
        uint24 tickBits = uint24(tick);
        data = bytes32(
            uint256(sqrtPriceX96) | (uint256(tickBits) << 160) | (uint256(protocolFee) << 184)
                | (uint256(lpFee) << 208)
        );
    }
}
