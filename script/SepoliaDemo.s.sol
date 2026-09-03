// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Script.sol";
import "forge-std/console2.sol";

import "../src/GuardianHook.sol";

import { IPoolManager } from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import { IHooks } from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import { Currency } from "@uniswap/v4-core/src/types/Currency.sol";
import { PoolKey } from "@uniswap/v4-core/src/types/PoolKey.sol";
import { PoolId, PoolIdLibrary } from "@uniswap/v4-core/src/types/PoolId.sol";
import { SwapParams } from "@uniswap/v4-core/src/types/PoolOperation.sol";
import { PoolSwapTest } from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import { StateLibrary } from "@uniswap/v4-core/src/libraries/StateLibrary.sol";

/// The judge demo, driven entirely by real Sepolia transactions. No cheatcodes: every beat
/// is a broadcast tx with an Etherscan link.
///
///   forge script script/SepoliaDemo.s.sol:SepoliaDemoScript --sig "healthySwap()" \
///     --rpc-url sepolia --account aegis-sepolia --sender <ADDR> --broadcast
///
/// Beats, in order: healthySwap() -> dustSwap() -> pause() -> provePaused()
/// status() is read-only and safe to run at any point. unpause() resets for a second run.
contract SepoliaDemoScript is Script {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    address internal constant POOL_MANAGER = 0xE03A1074c86CFeDd5C142C4F04F1a1536e203543;
    address internal constant POOL_SWAP_TEST = 0x9B6b46e2c869aa39918Db7f52f5557FE577B6eEe;
    address internal constant TRUSTED_RVM_ID = 0x00000000000000000000000000000000000d00D0;

    uint24 internal constant FEE = 3000;
    int24 internal constant TICK_SPACING = 60;
    uint160 internal constant MIN_PRICE_LIMIT = 4295128740;
    uint160 internal constant SQRT_PRICE_1_1 = 79228162514264337593543950336;
    bytes internal constant ZERO_BYTES = new bytes(0);

    function _key() internal view returns (PoolKey memory key, GuardianHook hook) {
        hook = GuardianHook(vm.envAddress("GUARDIAN_HOOK"));
        address token0 = vm.envAddress("TOKEN0");
        address token1 = vm.envAddress("TOKEN1");
        key = PoolKey({
            currency0: Currency.wrap(token0),
            currency1: Currency.wrap(token1),
            fee: FEE,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(address(hook))
        });
    }

    function _swap(PoolKey memory key, int256 amountSpecified) internal {
        PoolSwapTest(POOL_SWAP_TEST).swap(
            key,
            SwapParams({
                zeroForOne: true,
                amountSpecified: amountSpecified,
                sqrtPriceLimitX96: MIN_PRICE_LIMIT
            }),
            PoolSwapTest.TestSettings({ takeClaims: false, settleUsingBurn: false }),
            ZERO_BYTES
        );
    }

    /// Beat 1: an economically real swap. Price moves, no alert is raised.
    function healthySwap() external {
        (PoolKey memory key, GuardianHook hook) = _key();
        vm.startBroadcast();
        _swap(key, -1e15);
        vm.stopBroadcast();
        _report("BEAT 1 - healthy swap", key, hook);
    }

    /// Beat 2: a 1-wei swap is entirely consumed as fee, so price, tick and liquidity are
    /// unchanged across the checkpoint. afterSwap sees that and raises NO_OP_ALERT.
    ///
    /// MUST run after healthySwap(). A pool sitting on its initial tick boundary shifts its
    /// stored tick on the first swap even when the price does not move, and that defeats the
    /// unchangedState check. The guard below fails loudly rather than letting the demo fall
    /// flat in front of judges.
    function dustSwap() external {
        (PoolKey memory key, GuardianHook hook) = _key();

        (uint160 sqrtPriceX96,,,) = IPoolManager(POOL_MANAGER).getSlot0(key.toId());
        require(
            sqrtPriceX96 != SQRT_PRICE_1_1,
            "run healthySwap() first: pool is still on its initial tick boundary"
        );

        vm.startBroadcast();
        _swap(key, -1);
        vm.stopBroadcast();
        _report("BEAT 2 - dust swap (expect NO_OP_ALERT)", key, hook);
    }

    /// Beat 3: the automated response. Sent from the callbackSender key, standing in for the
    /// Reactive Network callback proxy. Both auth checks in the hook are really enforced.
    function pause() external {
        (PoolKey memory key, GuardianHook hook) = _key();
        vm.startBroadcast();
        hook.reactivePause(TRUSTED_RVM_ID, PoolId.unwrap(key.toId()), "NO_OP_ALERT");
        vm.stopBroadcast();
        _report("BEAT 3 - reactive pause", key, hook);
    }

    /// Beat 4: the hook is not just observing. The real PoolManager can no longer route a
    /// swap through this pool.
    ///
    /// Run this one WITHOUT --broadcast. Against a live --rpc-url the script executes on real
    /// Sepolia state, so the revert is genuine -- it just costs no gas and needs no failed tx.
    function provePaused() external view {
        (PoolKey memory key, GuardianHook hook) = _key();
        bytes32 poolId = PoolId.unwrap(key.toId());

        (bool allowed, string memory reason) = hook.isSwapAllowed(poolId, -1e15);
        console2.log("isSwapAllowed ->", allowed, reason);

        (bool ok,) = POOL_SWAP_TEST.staticcall(
            abi.encodeCall(
                PoolSwapTest.swap,
                (
                    key,
                    SwapParams({
                        zeroForOne: true,
                        amountSpecified: -1e15,
                        sqrtPriceLimitX96: MIN_PRICE_LIMIT
                    }),
                    PoolSwapTest.TestSettings({ takeClaims: false, settleUsingBurn: false }),
                    ZERO_BYTES
                )
            )
        );
        require(!ok, "BEAT 4 FAILED: swap went through on a paused pool");
        console2.log("BEAT 4 - swap REVERTED: the hook is gating a real Uniswap v4 pool");
    }

    /// Admin reset so the demo can be run again.
    function unpause() external {
        (PoolKey memory key, GuardianHook hook) = _key();
        bytes32 poolId = PoolId.unwrap(key.toId());
        vm.startBroadcast();
        hook.unpausePool(poolId);
        hook.resetPoolAlert(poolId);
        vm.stopBroadcast();
        _report("RESET", key, hook);
    }

    function status() external view {
        (PoolKey memory key, GuardianHook hook) = _key();
        _report("STATUS", key, hook);
    }

    function _report(string memory label, PoolKey memory key, GuardianHook hook) internal view {
        bytes32 poolId = PoolId.unwrap(key.toId());
        (
            bool registered,
            bool paused,
            uint160 lastSqrtPriceX96,
            int24 lastTick,
            uint128 liquidity,
            ,
            ,
            string memory lastAlertReason,
            uint256 lastAlertAt
        ) = hook.getPoolState(poolId);

        console2.log("===", label, "===");
        console2.log("poolId:");
        console2.logBytes32(poolId);
        console2.log("registered:   ", registered);
        console2.log("paused:       ", paused);
        console2.log("sqrtPriceX96: ", uint256(lastSqrtPriceX96));
        console2.log("tick:         ", int256(lastTick));
        console2.log("liquidity:    ", uint256(liquidity));
        console2.log("alert reason: ", bytes(lastAlertReason).length == 0 ? "(none)" : lastAlertReason);
        console2.log("alert at:     ", lastAlertAt);
        console2.log("risk score:   ", hook.getHookRiskScore(poolId));
    }
}
