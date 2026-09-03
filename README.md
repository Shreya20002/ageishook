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

See [Sepolia Testnet Deployment](#sepolia-testnet-deployment) for the public-testnet path.

## Frontend

Set `NEXT_PUBLIC_GUARDIAN_HOOK_ADDRESS` before starting the frontend.

The dashboard queries:

- contract metadata
- pool state by `bytes32 poolId`
- hook risk score
- `isSwapAllowed(poolId, amountSpecified)`

When `NEXT_PUBLIC_DEMO_MANAGER_ADDRESS` is also set, the dashboard enables local judge actions for healthy swaps,
warning simulation, Reactive pause, and reset.

## Frontend Judge Demo

For a browser-driven local demo, run Anvil in one terminal:

```bash
anvil
```

Deploy the frontend demo manager in another terminal:

```bash
npm run deploy:frontend-demo
```

Copy the printed values into `.env.local`:

```bash
NEXT_PUBLIC_DEMO_MANAGER_ADDRESS=<printed demo manager address>
NEXT_PUBLIC_GUARDIAN_HOOK_ADDRESS=<printed guardian hook address>
```

Then start the UI:

```bash
npm run dev
```

The judge console can now run the full visible flow:

1. `Run healthy swap` updates hook-tracked pool state with no alert.
2. `Trigger warning` simulates the suspicious no-op swap pattern through the permitted demo PoolManager and stores `NO_OP_ALERT`.
3. `Apply Reactive pause` calls the hook through the configured callback sender and makes `isSwapAllowed(...)` return `POOL_PAUSED`.
4. `Reset demo` clears the alert, unpauses the pool, and restores the initial pool snapshot.

This demo manager is for local judging only. The production hook path still depends on a real v4 `PoolManager`, a permissioned hook address, and the configured Reactive callback sender.

## Sepolia Testnet Deployment

Deploys AegisHook against the **canonical Uniswap v4 `PoolManager`** on Ethereum Sepolia
(`0xE03A1074c86CFeDd5C142C4F04F1a1536e203543`) with real ERC20s, real liquidity and real
swaps. Every step of the demo is a verifiable Etherscan transaction.

### One-time setup

Import the deployer key into Foundry's encrypted keystore. Do not put a private key in
`.env` -- `.env*` is gitignored, but the keystore is safer regardless.

```bash
cast wallet import aegis-sepolia --interactive
```

Copy `.env.example` to `.env` and set `SEPOLIA_RPC_URL` and `ETHERSCAN_API_KEY`. The `.env`
file must exist before running any `forge script` command: the `[etherscan]` block in
`foundry.toml` requires `ETHERSCAN_API_KEY` to be *defined*, even if you leave it blank.

Fund the deployer with about **0.02 Sepolia ETH**. A dry run of the deploy came in at
6.9M gas / ~0.0152 ETH at 2.2 gwei; most of that is the CREATE2 salt search.

### Deploy

Simulate first (no `--broadcast`), then execute:

```bash
forge script script/DeploySepolia.s.sol:DeploySepoliaScript --rpc-url sepolia --account aegis-sepolia --sender <YOUR_ADDRESS>
```

```bash
forge script script/DeploySepolia.s.sol:DeploySepoliaScript --rpc-url sepolia --account aegis-sepolia --sender <YOUR_ADDRESS> --broadcast --verify
```

The script deploys two test tokens, mines a CREATE2 salt for a valid hook address, deploys
the hook through `GuardianHookFactory`, initializes the pool on the real `PoolManager`,
registers it with the hook, seeds liquidity, and pre-approves the swap router. It prints
ready-to-paste `.env` and `.env.local` blocks at the end.

Deploy from an account with no other pending transactions. The mined salt is only valid for
the factory address, which derives from the deployer's nonce.

### Run the judge demo

Fill `GUARDIAN_HOOK`, `TOKEN0` and `TOKEN1` in `.env` from the deploy output, then run the
beats in order. Each is one transaction.

```bash
forge script script/SepoliaDemo.s.sol:SepoliaDemoScript --sig "healthySwap()" --rpc-url sepolia --account aegis-sepolia --sender <YOUR_ADDRESS> --broadcast
```

```bash
forge script script/SepoliaDemo.s.sol:SepoliaDemoScript --sig "dustSwap()" --rpc-url sepolia --account aegis-sepolia --sender <YOUR_ADDRESS> --broadcast
```

```bash
forge script script/SepoliaDemo.s.sol:SepoliaDemoScript --sig "pause()" --rpc-url sepolia --account aegis-sepolia --sender <YOUR_ADDRESS> --broadcast
```

```bash
forge script script/SepoliaDemo.s.sol:SepoliaDemoScript --sig "provePaused()" --rpc-url sepolia
```

| Beat | What happens | Hook state after |
| --- | --- | --- |
| `healthySwap()` | A real 1e15 swap through the canonical `PoolSwapTest` router. Price moves. | no alert |
| `dustSwap()` | A 1-wei swap, entirely consumed as fee. Price, tick and liquidity are unchanged across the checkpoint, so `afterSwap` flags a no-op. | `EmergencyAlert` / `NO_OP_ALERT` |
| `pause()` | `reactivePause` from the callback sender, carrying the trusted RVM id. | `paused = true`, risk 95 |
| `provePaused()` | Attempts another swap. The real `PoolManager` cannot route it. | reverts `PoolPaused()` |

`status()` is read-only and safe at any point. `unpause()` resets for a second run.

**`dustSwap()` must run after `healthySwap()`.** A pool sitting on its initial tick boundary
shifts its stored tick on the very first swap even when the price does not move, which
defeats the `unchangedState` check. The script guards this and fails with a clear message
rather than silently not alerting. This ordering is covered by
`testDustSwapAfterHealthySwapRaisesOrganicAlert` in `test/GuardianHook.integration.t.sol`.

### Point the dashboard at Sepolia

Set these in `.env.local`, leave `NEXT_PUBLIC_DEMO_MANAGER_ADDRESS` unset, and switch
MetaMask to Sepolia:

```
NEXT_PUBLIC_GUARDIAN_HOOK_ADDRESS=0x...
NEXT_PUBLIC_POOL_ID=0x...
```

On Sepolia the dashboard is read-only: it loads pool state on connect and re-reads on
Refresh. The four demo buttons belong to the local anvil demo and stay disabled, because
state transitions are driven from the terminal so each one has a transaction hash.

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
