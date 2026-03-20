# AegisHook

AegisHook is a Uniswap v4 hook prototype wired against the real `v4-core` interfaces and storage layout, with Reactive-triggered emergency pausing.

## Architecture

- `GuardianHook`: implements the upstream `IHooks` surface from `@uniswap/v4-core`, restricts hook callbacks to the configured `PoolManager`, reads live pool state through `StateLibrary`, emits `EmergencyAlert(bytes32,string,uint256)` on suspicious swap behavior, and pauses pools by canonical `poolId`.
- `ReactiveContract`: subscribes to `GuardianHook.EmergencyAlert` for a specific pool ID and emits a callback payload for `GuardianHook.reactivePause(...)`.
- `ReactivePrimitives`: minimal local Reactive interfaces and helpers for subscription and callback simulation.
- Foundry tests use upstream `PoolKey`, `PoolId`, `SwapParams`, and `BalanceDelta` types with a manager harness that serves the same storage slots `StateLibrary` reads from.
- Next.js + Tailwind + Ethers.js dashboard queries hook state and admissibility by `poolId`.

## Upstream Dependencies

The repo vendors:

- `lib/v4-core`
- `lib/v4-periphery`

`GuardianHook` imports directly from `@uniswap/v4-core/...`.

## Commands

```bash
npm install
npm test
npm run build:contracts
npm run demo
npm run dev
npm run build
```

## Frontend

Set `NEXT_PUBLIC_GUARDIAN_HOOK_ADDRESS` before starting the frontend.

The dashboard is read-only. It queries:

- contract metadata
- pool state by `bytes32 poolId`
- hook risk score
- `isSwapAllowed(poolId, amountSpecified)`

## Deploy With Foundry

Set these environment variables:

- `POOL_MANAGER`: deployed Uniswap v4 `PoolManager`
- `CALLBACK_SENDER`: callback proxy allowed to invoke `reactivePause`
- `HOOK_ADMIN`: admin address allowed to register pools, configure auditors, and manage resets
- `REACTIVE_SERVICE`: Reactive system/service contract address
- `TRUSTED_REACTIVE_RVM_ID`: trusted Reactive RVM identity injected into callbacks
- `DEFAULT_CURRENCY0`: pool currency0 address
- `DEFAULT_CURRENCY1`: pool currency1 address
- `DEFAULT_FEE`: pool fee tier
- `DEFAULT_TICK_SPACING`: pool tick spacing
- `ORIGIN_CHAIN_ID`: chain where `EmergencyAlert` is emitted
- `DESTINATION_CHAIN_ID`: chain where callbacks execute
- `REACTIVE_CALLBACK_GAS_LIMIT`: gas limit encoded into the Reactive callback event
- `HOOK_SALT_START`: starting salt nonce for CREATE2 mining
- `HOOK_SALT_SEARCH_LIMIT`: max salts to scan when mining a valid hook address

Then run:

```bash
forge script script/Deploy.s.sol:DeployScript --rpc-url <RPC_URL> --broadcast
```

## Important Hook Deployment Note

Uniswap v4 only calls hooks whose deployed address contains the required low-bit permission flags.

This repo now mines a CREATE2 salt and deploys `GuardianHook` through `GuardianHookFactory` so the deployed address has the exact `BEFORE_SWAP | AFTER_SWAP` permission bits.

For a live deployment you still need:

- a CREATE2-capable deployment transaction path
- stable `HOOK_SALT_START` / `HOOK_SALT_SEARCH_LIMIT` values large enough to find a valid address
- the final mined hook address wired into pool creation

## Runtime Flow

1. `GuardianHook.beforeSwap(...)` is called by `PoolManager` and snapshots `slot0` and liquidity via `StateLibrary`.
2. `GuardianHook.afterSwap(...)` is called by `PoolManager`, compares the post-swap state against the checkpoint, and emits `EmergencyAlert` on suspicious no-op behavior.
3. The RN deployment of `ReactiveContract` subscribes to that alert for one `poolId`.
4. The RVM deployment of `ReactiveContract` receives `react(LogRecord)` and emits a `Callback`.
5. The callback proxy invokes `GuardianHook.reactivePause(rvmId, poolId, reason)`.
6. `GuardianHook` verifies both `msg.sender == callbackSender` and `rvmId == trustedReactiveRvmId`, then pauses the pool.

## Local Demo

Run:

```bash
npm run demo
```

The demo script:

- deploys a real local `PoolManager`
- mines and deploys a permissioned `GuardianHook` via CREATE2
- initializes a real pool and adds liquidity
- performs a healthy swap through the upstream v4 swap router
- simulates a suspicious no-op hook callback to emit `EmergencyAlert`
- simulates the Reactive callback pause path
- prints pool state after each phase
