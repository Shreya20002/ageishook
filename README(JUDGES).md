# AegisHook 1.0

Technical and presentation guide for the AegisHook codebase.

## Executive Summary

AegisHook is a Uniswap v4-native security hook that monitors live pool behavior, flags suspicious swap outcomes, and enables automated emergency pausing through Reactive-triggered callbacks.

This repository is not a mock-only concept. It is wired against real `v4-core` interfaces, real `PoolManager` state reads, real hook permission constraints, a local end-to-end demo path, and a frontend that surfaces live hook state for a chosen `poolId`.

The core design goal is simple:

> Move DeFi security from passive alerting to active on-chain protection.

## Why This Repo Matters

Many hackathon projects show a UI, a contract, or an idea. AegisHook is stronger when judged as a system:

- A real Uniswap v4 hook lifecycle is implemented.
- Deployment respects v4 hook permission bits via CREATE2 mining.
- Pool state is read from the real `PoolManager` layout through `StateLibrary`.
- Suspicious behavior is detected in `afterSwap(...)`.
- A Reactive-style listener contract subscribes to hook alerts and emits pause callbacks.
- The frontend exposes pool-level security status for operators and judges.

This makes AegisHook a full-stack protocol security prototype, not just a proof-of-concept dashboard

### 1. Protocol Correctness

- The hook implements the upstream `IHooks` surface from Uniswap v4.
- The hook only accepts privileged lifecycle calls from the configured `PoolManager`.
- Pools are identified using canonical `PoolId` derivation.
- The contract snapshots and compares real pool state around swaps.

### 2. Deployment Realism

- Uniswap v4 hook addresses must contain specific low-bit permission flags.
- This repo solves that constraint using `HookMiner` plus `GuardianHookFactory`.
- The deployment flow is materially closer to production than a direct constructor deploy.

### 3. Security Design

- Swap execution is gated by registration and pause status.
- Sensitive actions are role-scoped.
- Reactive pause execution is authenticated by both callback sender and trusted Reactive RVM ID.
- Reentrancy protection is applied per pool during swap callbacks.

### 4. System Integration

- On-chain detection emits `EmergencyAlert`.
- The Reactive contract subscribes to that signal.
- A callback flow can trigger emergency pool pausing.
- The frontend reads and presents operational state from the deployed hook.

### 5. Presentation Quality

- The project has a clean terminal demo path.
- The frontend is compact and judge-friendly.
- The architecture is understandable without reading every contract.
- The state transitions are easy to narrate in a live demo.

## System Overview

### High-Level Flow

```text
Trader swap
   |
   v
Uniswap v4 PoolManager
   |
   v
GuardianHook.beforeSwap(...)
   |
   v
GuardianHook.afterSwap(...)
   |
   +--> healthy path: update tracked state
   |
   +--> suspicious path: emit EmergencyAlert(poolId, reason, detectedAt)
                               |
                               v
                      ReactiveContract subscription
                               |
                               v
                     emits Callback(destination, payload)
                               |
                               v
                     callback proxy / trusted sender
                               |
                               v
        GuardianHook.reactivePause(rvmId, poolId, reason)
                               |
                               v
                       pool marked paused
```

### Read Model and Operator Model

```text
GuardianHook on-chain state
   |
   +--> getPoolState(poolId)
   +--> getHookRiskScore(poolId)
   +--> isSwapAllowed(poolId, amountSpecified)
   |
   v
Next.js dashboard
   |
   v
Judge / operator visibility
```

## Architecture Breakdown

### 1. `GuardianHook`

Primary role: security enforcement inside the Uniswap v4 hook lifecycle.

Responsibilities:

- Implements the upstream `IHooks` interface.
- Restricts lifecycle callbacks to the configured `PoolManager`.
- Registers pools and tracks their latest known state.
- Validates swaps before execution.
- Snapshots pool state before swap.
- Reads the post-swap state after execution.
- Flags suspicious swap outcomes.
- Emits `EmergencyAlert`.
- Supports manual and Reactive-triggered pausing.

Key architectural choices:

- `PoolConfig` stores persistent security and operational state for each `poolId`.
- `SwapCheckpoint` stores pre-swap observations used for post-swap comparison.
- `nonReentrant(poolId)` prevents reentrant swap hook execution on the same pool.
- `isSwapAllowed(...)` centralizes the basic swap admission rules.

Security-relevant signals stored per pool:

- `registered`
- `paused`
- `lastSqrtPriceX96`
- `lastTick`
- `liquidity`
- `lastAction`
- `lastUpdatedAt`
- `lastAlertReason`
- `lastAlertAt`

### 2. `ReactiveContract`

Primary role: connect alert emission to automated mitigation.

Responsibilities:

- Subscribes to `EmergencyAlert(bytes32,string,uint256)` for one monitored pool.
- Verifies the event source and chain context when `react(...)` is called.
- Emits an internal `Callback` payload targeting `GuardianHook.reactivePause(...)`.
- Makes the alert-to-pause path explicit and inspectable.

Why this matters:

- It cleanly separates detection from automation.
- It models how a production reactive system would consume hook events and trigger a response.
- It provides a credible partner integration story rather than a hand-waved future feature.

### 3. `HookMiner`

Primary role: satisfy a real Uniswap v4 deployment constraint.

Uniswap v4 hooks are not callable unless the deployed hook address contains the correct low-bit permission flags for enabled hook callbacks.

`HookMiner`:

- computes deterministic CREATE2 addresses
- scans salts
- finds an address whose bitmask matches `BEFORE_SWAP | AFTER_SWAP`


- This is a real protocol constraint.
- Solving it shows depth beyond normal Solidity CRUD patterns.
- It is one of the clearest indicators that the team built against real v4 assumptions.

### 4. `GuardianHookFactory`

Primary role: deploy the hook at the mined CREATE2 address.

This keeps deployment logic simple and auditable:

- mine a valid salt
- deploy from a stable factory
- emit `GuardianHookDeployed`

### 5. Frontend Dashboard

Primary role: give judges and operators live visibility into hook state.

Built with:

- Next.js
- React
- Tailwind
- Ethers v6

The UI reads:

- `getPoolState(poolId)`
- `getHookRiskScore(poolId)`
- `admin()`
- `poolManager()`
- `callbackSender()`
- `trustedReactiveRvmId()`
- `isSwapAllowed(poolId, amountSpecified)`

Why the frontend matters:

- It makes the on-chain system legible during judging.
- It turns contract state into a narrative: registered, healthy, alerted, paused.
- It helps demonstrate that this is not only protocol logic but also operator tooling.

## Detailed Runtime Flow

### Phase 1. Pool Registration

The admin registers a pool using the canonical `PoolKey`.

During registration:

- the hook verifies the pool uses the current hook address
- currency ordering is validated
- the canonical `poolId` is derived
- initial state is synchronized from `PoolManager`

Outcome:

- the pool becomes known to the security system
- baseline state is available for future validation

### Phase 2. Healthy Swap

When a swap starts:

- `beforeSwap(...)` checks the pool is registered and not paused
- `isSwapAllowed(...)` rejects trivial invalid input like zero-sized swaps
- the hook snapshots current pool state into `SwapCheckpoint`

When the swap finishes:

- `afterSwap(...)` reads the new pool state from `PoolManager`
- it compares delta and post-state against the checkpoint
- it updates tracked state
- it emits `AfterSwapValidated`

Outcome:

- a valid swap proceeds normally
- the hook becomes an observability and control layer, not a blocker

### Phase 3. Suspicious Behavior Detection

The current suspicious heuristic is intentionally simple and explainable:

- zero delta on both token amounts
- unchanged state after swap
- liquidity drop paired with no-op delta

If suspicious:

- `lastAlertReason` becomes `NO_OP_ALERT`
- `lastAlertAt` is updated
- `EmergencyAlert` is emitted

Why this is a strong hackathon design:

- The heuristic is easy to demo and easy to reason about.
- The design leaves room for richer risk engines later.
- Judges can clearly see where policy lives and how it can evolve.

### Phase 4. Reactive Response

The Reactive path listens for `EmergencyAlert` on the monitored pool.

When the matching event is processed:

- `ReactiveContract.react(...)` verifies source chain, origin contract, event topic, and monitored `poolId`
- it emits a callback payload that targets `GuardianHook.reactivePause(...)`

Then the callback sender calls the hook.

The hook verifies:

- `msg.sender == callbackSender`
- `reactiveRvmId == trustedReactiveRvmId`

Outcome:

- the pool is paused only through an authenticated path
- the security action is explicit, scoped, and auditable

## Trust and Security Model

### Roles

- `admin`
  Registers pools, configures auditors, sets trusted Reactive RVM ID, unpauses pools.

- `auditors`
  Can manually pause pools.

- `poolManager`
  The only caller allowed to invoke hook lifecycle methods.

- `callbackSender`
  The only caller allowed to invoke `reactivePause(...)`.

- `trustedReactiveRvmId`
  The expected Reactive identity carried in the pause path.

### Invariants

- Only registered pools can be actively guarded.
- Paused pools cannot pass swap validation.
- Only the real `PoolManager` can enter hook callbacks.
- Only the trusted callback path can invoke automated pausing.
- The hook address must have valid Uniswap v4 permission flags.

### Current Security Strengths

- clear role boundaries
- canonical pool identity usage
- per-pool reentrancy guard
- restricted callback source
- real `PoolManager` state reads instead of shadow-only accounting

### Current Prototype Limitations

This project is a serious prototype, but judges should understand what is intentionally simplified:

- suspicious behavior detection is heuristic-based and narrow
- the Reactive callback sender is a stand-in EOA. `ReactiveContract` is written against the
  Reactive Network interfaces but is not deployed, so the alert-to-pause step is triggered
  manually. The hook's authentication on that path (`onlyCallbackSender` plus the
  `trustedReactiveRvmId` check) is real and enforced on-chain.
- the local anvil demo drives the hook through `FrontendDemoPoolManager`, a stub that fakes
  v4 storage slots so the browser can step through states without tokens or liquidity. The
  hook it deploys is byte-identical to the production one, but no swap actually occurs. The
  Sepolia deployment uses the canonical Uniswap v4 `PoolManager` instead.
- production deployment would need finalized infra around callback delivery and policy management

These are acceptable hackathon tradeoffs because the hardest integration points are already implemented.

## Why The Design Is Readable

The codebase is intentionally split by responsibility:

- `src/GuardianHook.sol`
  core hook logic and state machine

- `src/ReactiveContract.sol`
  alert subscription and callback emission

- `src/HookMiner.sol`
  CREATE2 permission-bit mining

- `src/GuardianHookFactory.sol`
  deployment primitive

- `script/Deploy.s.sol`
  parameterized deployment path

- `script/LocalDemo.s.sol`
  local end-to-end demonstration

- `test/GuardianHook.integration.t.sol`
  real manager integration checks

- `app/page.js`
  operator dashboard


## Demo Design For Judges

The project is especially judge-friendly when demoed in four beats:

### Beat 1. Real deployment realism


- mined hook address
- factory deployment
- canonical `poolId`

This demonstrates protocol depth.

### Beat 2. Healthy operation


- a real local pool
- liquidity added
- healthy swap succeeds
- `paused = false`

This demonstrates the hook does not break normal protocol behavior.

### Beat 3. Detection and automated protection


- suspicious callback path
- `EmergencyAlert`
- `NO_OP_ALERT`
- Reactive pause path
- `paused = true`

This demonstrates the core innovation.

### Beat 4. Frontend visibility


- the same `poolId`
- refreshed state
- risk score
- blocked swap result from `isSwapAllowed(...)`

This demonstrates presentation quality and operational usability.

## Codebase Walkthrough

### Contracts

#### `GuardianHook.sol`

What to inspect:

- `getHookPermissions()`
- `registerPool(...)`
- `isSwapAllowed(...)`
- `beforeSwap(...)`
- `afterSwap(...)`
- `reactivePause(...)`
- `_syncPoolState(...)`
- `_getPoolSnapshot(...)`


This file contains the core security state machine and protocol integration logic.

#### `ReactiveContract.sol`

What to inspect:

- constructor subscription call
- `react(...)`
- callback payload encoding


#### `HookMiner.sol`

What to inspect:

- `REQUIRED_FLAGS`
- `computeAddress(...)`
- `find(...)`


### Scripts

#### `Deploy.s.sol`

Why it matters:

- parameterizes deployment with real environment variables
- sets trusted Reactive configuration
- creates the Reactive subscription contract


#### `LocalDemo.s.sol`

Why it matters:

- uses a local `PoolManager`
- adds real liquidity
- performs a healthy swap
- simulates a suspicious alert
- simulates the Reactive pause path
- prints state after each phase

This script is the clearest end-to-end proof that the system works as a cohesive product.

### Tests

The integration test checks:

- real swap invocation through the `PoolManager`
- state updates after healthy swaps
- paused pools block swaps
- factory deployment preserves required hook permission bits


## Frontend Presentation Notes

Against Sepolia the frontend is a read-only dashboard: it reads hook state and renders the
security status, while the state transitions are driven from the terminal so every beat has an
Etherscan transaction behind it.

Against the local anvil demo the same page additionally exposes four buttons that send
transactions to `FrontendDemoPoolManager` to step through the narrative.

That split is the right choice for judging because it:

- keeps attention on live security state
- makes every Sepolia state change independently verifiable on a block explorer
- supports a simple judge workflow: open the dashboard, refresh, inspect status

Important UX signals in the dashboard:

- wallet/session status
- pool registration status
- paused/unpaused status
- latest alert reason
- risk score
- protocol wiring metadata
- `isSwapAllowed(...)` result

This makes the frontend effective as a presentation layer even though the real enforcement happens on-chain.

## Repository Commands

```bash
npm install
npm test
npm run build:contracts
npm run demo
npm run dev
npm run build
```

## Suggested Judge Path

If a judge only has a few minutes, the best order is:

1. Read this document.
2. Open the live Sepolia dashboard and the Etherscan links below. The hook is deployed
   against the canonical Uniswap v4 `PoolManager` at
   `0xE03A1074c86CFeDd5C142C4F04F1a1536e203543`, with real tokens, real liquidity and real
   swaps.
3. Inspect `src/GuardianHook.sol`, `src/HookMiner.sol`, and `src/ReactiveContract.sol`.
4. Run `forge test` to see the hook exercised against a real in-process `PoolManager`,
   including the organic detection case.

### The four beats, live on Sepolia

Each beat is one transaction. Full commands are in `README.md` under
[Sepolia Testnet Deployment](README.md#sepolia-testnet-deployment).

| Beat | What happens | Hook state after |
| --- | --- | --- |
| 1. Healthy | A real swap through the canonical `PoolSwapTest` router. Price moves. | no alert |
| 2. Detection | A 1-wei swap, consumed entirely as fee. Price, tick and liquidity are unchanged across the checkpoint, so `afterSwap` flags a no-op. | `EmergencyAlert` / `NO_OP_ALERT` |
| 3. Response | `reactivePause` from the callback sender, carrying the trusted RVM id. | `paused = true`, risk 95 |
| 4. Enforcement | Another swap is attempted. | reverts `PoolPaused()` |

Beat 4 is the one worth pausing on: it is the moment the hook stops being an observer. A
real Uniswap v4 `PoolManager` will no longer route a swap through this pool.

Nothing in this sequence is simulated. Beat 2 in particular is not a hand-crafted callback --
it is a genuine `PoolManager.swap` whose economics happen to produce a no-op, which is
exactly the pattern the heuristic is written to catch. The behaviour is pinned by
`testDustSwapAfterHealthySwapRaisesOrganicAlert` in `test/GuardianHook.integration.t.sol`.

### Local alternative

`npm run demo` runs the same narrative entirely in-process through `script/LocalDemo.s.sol`,
against a real `PoolManager` deployed in Foundry's EVM. It broadcasts nothing and deploys
nothing to any chain, so its printed `poolId` is not usable in the dashboard. Use it to read
the flow, not to drive the UI.

The separate anvil-based browser demo is described in `README.md` under
[Frontend Judge Demo](README.md#frontend-judge-demo). It drives the hook through
`FrontendDemoPoolManager`, a stub that fakes v4 storage slots so the four dashboard buttons
can step through states without tokens or liquidity. The hook it deploys is byte-identical to
the production one, but no swap actually occurs -- prefer the Sepolia path when showing that
the system works.

## Why AegisHook Is Different

The strongest differentiator is that AegisHook closes the loop:

- detect suspicious behavior
- emit an on-chain alert
- trigger an automated response
- expose the resulting state through a judge-friendly UI

Many projects stop at one of those layers.

AegisHook combines all four.

## Future Extensions

Natural next steps include:

- richer anomaly scoring beyond no-op detection
- configurable pool-specific security policies
- broader support for liquidity-related anomaly detection
- production-grade Reactive callback infrastructure
- admin tooling for policy management and post-incident workflow

