// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Script.sol";
import "forge-std/console2.sol";

import "../src/GuardianHook.sol";
import "../src/GuardianHookFactory.sol";
import "../src/HookMiner.sol";
import "../src/ReactiveContract.sol";

import { PoolManager } from "@uniswap/v4-core/src/PoolManager.sol";
import { IHooks } from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import { Currency } from "@uniswap/v4-core/src/types/Currency.sol";
import { PoolKey } from "@uniswap/v4-core/src/types/PoolKey.sol";
import { PoolId, PoolIdLibrary } from "@uniswap/v4-core/src/types/PoolId.sol";
import { BalanceDelta, toBalanceDelta } from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import { ModifyLiquidityParams, SwapParams } from "@uniswap/v4-core/src/types/PoolOperation.sol";
import { PoolModifyLiquidityTest } from "@uniswap/v4-core/src/test/PoolModifyLiquidityTest.sol";
import { PoolSwapTest } from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import { StateLibrary } from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import { TestERC20 } from "@uniswap/v4-core/src/test/TestERC20.sol";

contract LocalDemoScript is Script {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for PoolManager;

    address internal constant CALLBACK_SENDER = address(0xCB01);
    address internal constant DEMO_ADMIN = address(0xA11CE);
    address internal constant DEMO_USER = address(0xBEEF);
    address internal constant DEMO_RVM_ID = address(0xD00D);
    address internal constant VM_SERVICE = address(0x600D);
    uint256 internal constant ORIGIN_CHAIN_ID = 11155111;
    uint256 internal constant DESTINATION_CHAIN_ID = 11155111;
    uint64 internal constant CALLBACK_GAS_LIMIT = 250000;
    uint160 internal constant SQRT_PRICE_1_1 = 79228162514264337593543950336;
    uint160 internal constant MIN_PRICE_LIMIT = 4295128740;
    bytes internal constant ZERO_BYTES = new bytes(0);

    function run() external {
        PoolManager manager = new PoolManager(DEMO_ADMIN);
        PoolModifyLiquidityTest modifyLiquidityRouter = new PoolModifyLiquidityTest(manager);
        PoolSwapTest swapRouter = new PoolSwapTest(manager);

        TestERC20 tokenA = new TestERC20(type(uint128).max);
        TestERC20 tokenB = new TestERC20(type(uint128).max);

        address currency0Address =
            address(tokenA) < address(tokenB) ? address(tokenA) : address(tokenB);
        address currency1Address =
            address(tokenA) < address(tokenB) ? address(tokenB) : address(tokenA);

        TestERC20(currency0Address).approve(address(modifyLiquidityRouter), type(uint256).max);
        TestERC20(currency0Address).approve(address(swapRouter), type(uint256).max);
        TestERC20(currency1Address).approve(address(modifyLiquidityRouter), type(uint256).max);
        TestERC20(currency1Address).approve(address(swapRouter), type(uint256).max);

        GuardianHookFactory hookFactory = new GuardianHookFactory();
        bytes32 initCodeHash = keccak256(
            abi.encodePacked(
                type(GuardianHook).creationCode,
                abi.encode(address(manager), CALLBACK_SENDER, DEMO_ADMIN)
            )
        );
        (bytes32 salt, address predictedHook) =
            HookMiner.find(address(hookFactory), initCodeHash, 0, 200000);
        GuardianHook guardianHook =
            hookFactory.deploy(address(manager), CALLBACK_SENDER, DEMO_ADMIN, salt);

        PoolKey memory key = PoolKey({
            currency0: Currency.wrap(currency0Address),
            currency1: Currency.wrap(currency1Address),
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(address(guardianHook))
        });
        PoolId poolId = key.toId();

        manager.initialize(key, SQRT_PRICE_1_1);
        vm.prank(DEMO_ADMIN);
        guardianHook.registerPool(key);
        vm.prank(DEMO_ADMIN);
        guardianHook.setTrustedReactiveRvmId(DEMO_RVM_ID);

        ReactiveContract reactiveVmContract = new ReactiveContract(
            VM_SERVICE,
            ORIGIN_CHAIN_ID,
            DESTINATION_CHAIN_ID,
            address(guardianHook),
            PoolId.unwrap(poolId),
            CALLBACK_GAS_LIMIT
        );

        modifyLiquidityRouter.modifyLiquidity(
            key,
            ModifyLiquidityParams({
                tickLower: -120,
                tickUpper: 120,
                liquidityDelta: 1e18,
                salt: bytes32(0)
            }),
            ZERO_BYTES
        );

        console2.log("AegisHook local demo");
        console2.log("PoolManager:", address(manager));
        console2.log("GuardianHookFactory:", address(hookFactory));
        console2.log("Predicted hook:", predictedHook);
        console2.log("GuardianHook:", address(guardianHook));
        console2.log("Pool ID:");
        console2.logBytes32(PoolId.unwrap(poolId));
        _logPoolState("Initial state", manager, guardianHook, poolId);

        swapRouter.swap(
            key,
            SwapParams({
                zeroForOne: true,
                amountSpecified: -1e18,
                sqrtPriceLimitX96: MIN_PRICE_LIMIT
            }),
            PoolSwapTest.TestSettings({ takeClaims: false, settleUsingBurn: false }),
            ZERO_BYTES
        );
        _logPoolState("After healthy swap", manager, guardianHook, poolId);

        vm.prank(address(manager));
        guardianHook.beforeSwap(
            DEMO_USER,
            key,
            SwapParams({
                zeroForOne: true,
                amountSpecified: -1e18,
                sqrtPriceLimitX96: MIN_PRICE_LIMIT
            }),
            ZERO_BYTES
        );
        vm.prank(address(manager));
        guardianHook.afterSwap(
            DEMO_USER,
            key,
            SwapParams({
                zeroForOne: true,
                amountSpecified: -1e18,
                sqrtPriceLimitX96: MIN_PRICE_LIMIT
            }),
            toBalanceDelta(0, 0),
            ZERO_BYTES
        );
        _logPoolState("After simulated suspicious callback", manager, guardianHook, poolId);

        IReactive.LogRecord memory log = IReactive.LogRecord({
            chain_id: ORIGIN_CHAIN_ID,
            _contract: address(guardianHook),
            topic_0: uint256(keccak256("EmergencyAlert(bytes32,string,uint256)")),
            topic_1: uint256(PoolId.unwrap(poolId)),
            topic_2: 0,
            topic_3: 0,
            data: abi.encode("NO_OP_ALERT", block.timestamp),
            block_number: block.number,
            op_code: 0,
            block_hash: uint256(blockhash(block.number - 1)),
            tx_hash: 0,
            log_index: 0
        });

        reactiveVmContract.react(log);

        vm.prank(CALLBACK_SENDER);
        guardianHook.reactivePause(DEMO_RVM_ID, PoolId.unwrap(poolId), "NO_OP_ALERT");
        _logPoolState("After Reactive pause", manager, guardianHook, poolId);
    }

    function _logPoolState(
        string memory label,
        PoolManager manager,
        GuardianHook guardianHook,
        PoolId poolId
    ) internal view {
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

        console2.log("");
        console2.log(label);
        console2.log("registered:", registered);
        console2.log("paused:", paused);
        console2.log("hook sqrtPriceX96:", uint256(lastSqrtPriceX96));
        console2.log("manager sqrtPriceX96:", uint256(currentSqrtPriceX96));
        console2.log("hook tick:", int256(lastTick));
        console2.log("manager tick:", int256(currentTick));
        console2.log("hook liquidity:", uint256(liquidity));
        console2.log("manager liquidity:", uint256(currentLiquidity));
        console2.log("last action:", uint256(lastAction));
        console2.log("last updated at:", lastUpdatedAt);
        console2.log("last alert reason:", lastAlertReason);
        console2.log("last alert at:", lastAlertAt);
    }
}
