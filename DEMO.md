# Demo Guide

Run the local end-to-end demo with:

```bash
npm run demo
```

## What It Does

The demo script in [script/LocalDemo.s.sol](/C:/Users/Shreya/Dropbox/PC/Documents/AegisHook/script/LocalDemo.s.sol#L1) runs on a local in-memory EVM and performs the full AegisHook flow:

1. Deploys a real Uniswap v4 `PoolManager`
2. Deploys two local ERC20 test tokens
3. Mines a CREATE2 salt for a hook address with the required `BEFORE_SWAP | AFTER_SWAP` permission bits
4. Deploys `GuardianHook` through `GuardianHookFactory`
5. Builds a real `PoolKey`, initializes the pool, and registers it in `GuardianHook`
6. Adds liquidity through the upstream `PoolModifyLiquidityTest` router
7. Executes a healthy swap through the upstream `PoolSwapTest` router
8. Simulates a suspicious no-op hook callback that emits `EmergencyAlert`
9. Simulates the Reactive callback pause path by calling `reactivePause(...)`

## Expected Output

The script prints:

- `PoolManager` address
- `GuardianHookFactory` address
- predicted CREATE2 hook address
- deployed hook address
- canonical `poolId`
- pool state after each phase

The key phases are:

- `Initial state`
  The pool is registered and unpaused. `GuardianHook` has synced initial pool state.

- `After healthy swap`
  A real `PoolManager.swap(...)` has executed. `GuardianHook.afterSwap(...)` has updated its tracked state.

- `After simulated suspicious callback`
  The script manually simulates a suspicious no-op pattern through the hook callback path. `lastAlertReason` becomes `NO_OP_ALERT`.

- `After Reactive pause`
  The simulated Reactive callback path pauses the pool. `paused` becomes `true`.

## How To Read The Printed State

- `registered`
  Whether `GuardianHook.registerPool(...)` has been called for the `poolId`

- `paused`
  Whether swaps should be blocked by the hook

- `hook sqrtPriceX96` / `manager sqrtPriceX96`
  `GuardianHook`’s recorded price state compared to the real `PoolManager` state

- `hook tick` / `manager tick`
  `GuardianHook`’s recorded tick compared to the real `PoolManager` tick

- `hook liquidity` / `manager liquidity`
  `GuardianHook`’s recorded liquidity compared to the real `PoolManager` liquidity

- `last action`
  Internal enum value from `GuardianHook`
  `0 = None`
  `1 = Swap`
  `2 = LiquidityAdded`
  `3 = LiquidityRemoved`
  `4 = Sync`

- `last alert reason`
  Most recent alert reason stored by the hook

- `last alert at`
  Timestamp of the latest alert

## Notes

- The demo intentionally simulates the suspicious hook path after the healthy swap. That is done to show the alert and Reactive pause flow deterministically in one run.
- The demo uses a real `PoolManager` and real upstream test routers, so the healthy swap path is not mocked.
- The Reactive side is still locally simulated through `ReactiveContract.react(...)` and the callback sender prank. That is expected for a local demo.

## Related Files

- [script/LocalDemo.s.sol](/C:/Users/Shreya/Dropbox/PC/Documents/AegisHook/script/LocalDemo.s.sol#L1)
- [src/GuardianHook.sol](/C:/Users/Shreya/Dropbox/PC/Documents/AegisHook/src/GuardianHook.sol#L1)
- [src/GuardianHookFactory.sol](/C:/Users/Shreya/Dropbox/PC/Documents/AegisHook/src/GuardianHookFactory.sol#L1)
- [src/HookMiner.sol](/C:/Users/Shreya/Dropbox/PC/Documents/AegisHook/src/HookMiner.sol#L1)
- [src/ReactiveContract.sol](/C:/Users/Shreya/Dropbox/PC/Documents/AegisHook/src/ReactiveContract.sol#L1)
