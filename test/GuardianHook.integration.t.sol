// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "../src/GuardianHook.sol";
import "../src/GuardianHookFactory.sol";
import "../src/HookMiner.sol";
import {Deployers} from "@uniswap/v4-core/test/utils/Deployers.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";

contract GuardianHookIntegrationTest is Test, Deployers {
    using StateLibrary for IPoolManager;

    address internal constant CALLBACK_SENDER = address(0xCB01);

    GuardianHookFactory internal hookFactory;
    GuardianHook internal guardianHook;
    PoolId internal poolId;

    function setUp() public {
        deployFreshManagerAndRouters();
        (currency0, currency1) = deployMintAndApprove2Currencies();

        hookFactory = new GuardianHookFactory();

        bytes32 initCodeHash = keccak256(
            abi.encodePacked(type(GuardianHook).creationCode, abi.encode(address(manager), CALLBACK_SENDER, address(this)))
        );
        (bytes32 salt,) = HookMiner.find(address(hookFactory), initCodeHash, 0, 200000);
        guardianHook = hookFactory.deploy(address(manager), CALLBACK_SENDER, address(this), salt);

        key = PoolKey(currency0, currency1, 3000, 60, IHooks(address(guardianHook)));
        poolId = key.toId();

        manager.initialize(key, SQRT_PRICE_1_1);
        guardianHook.registerPool(key);
        modifyLiquidityRouter.modifyLiquidity(key, ModifyLiquidityParams(-120, 120, 1e18, bytes32(0)), ZERO_BYTES);
    }

    function testRealPoolManagerSwapInvokesHookAndUpdatesState() public {
        swap(key, true, -1e18, ZERO_BYTES);

        (
            bool registered,
            bool paused,
            uint160 lastSqrtPriceX96,
            int24 lastTick,
            uint128 liquidity,
            GuardianHook.ActionType lastAction,
            uint256 lastUpdatedAt,
            string memory lastAlertReason,
            uint256 lastAlertAt
        ) = guardianHook.getPoolState(PoolId.unwrap(poolId));

        (uint160 currentSqrtPriceX96, int24 currentTick,,) = manager.getSlot0(poolId);
        uint128 currentLiquidity = manager.getLiquidity(poolId);

        assertTrue(registered);
        assertFalse(paused);
        assertEq(uint256(lastSqrtPriceX96), uint256(currentSqrtPriceX96));
        assertEq(int256(lastTick), int256(currentTick));
        assertEq(uint256(liquidity), uint256(currentLiquidity));
        assertEq(uint256(lastAction), uint256(GuardianHook.ActionType.Swap));
        assertGt(lastUpdatedAt, 0);
        assertEq(bytes(lastAlertReason).length, 0);
        assertEq(lastAlertAt, 0);
    }

    function testPausedPoolBlocksRealPoolManagerSwap() public {
        guardianHook.pausePool(PoolId.unwrap(poolId), "MANUAL_PAUSE");

        vm.expectRevert();
        swap(key, true, -1e18, ZERO_BYTES);
    }

    function testFactoryDeployedHookKeepsRequiredPermissionBitsInRealSetup() public view {
        uint160 masked = uint160(address(guardianHook)) & uint160((1 << 14) - 1);
        assertEq(uint256(masked), uint256((1 << 7) | (1 << 6)));
    }
}
