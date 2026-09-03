"use client";

import { useEffect, useMemo, useState } from "react";
import { BrowserProvider, Contract, JsonRpcProvider, isAddress } from "ethers";
import { frontendDemoAbi, guardianHookAbi } from "../lib/guardianHookAbi";

// On Sepolia there is no demo manager to auto-detect the pool from, so the deployed
// poolId is supplied directly and prefills the field. Falls back to empty for the local
// anvil demo, where loadDemoMetadata() fills it in instead.
const defaultForm = {
  poolId: process.env.NEXT_PUBLIC_POOL_ID || "",
  amountSpecified: "10",
  reason: "NO_OP_ALERT"
};

const actionLabels = ["None", "Swap", "LiquidityAdded", "LiquidityRemoved", "Sync"];

// The narrative the demo walks through. `key` matches the derived phase below.
const PHASES = [
  { key: "healthy", title: "Healthy", note: "Swaps pass. The hook stays out of the way." },
  { key: "alerted", title: "Alert raised", note: "A no-op swap was detected in afterSwap." },
  { key: "paused", title: "Paused", note: "Swaps now revert at the PoolManager." }
];

function shortAddress(value) {
  if (!value) return "--";
  return `${value.slice(0, 6)}...${value.slice(-4)}`;
}

function formatTimestamp(value) {
  if (!value || value === "0") return "--";
  return new Date(Number(value) * 1000).toLocaleString();
}

export default function HomePage() {
  const configuredHookAddress = process.env.NEXT_PUBLIC_GUARDIAN_HOOK_ADDRESS || "";
  const demoManagerAddress = process.env.NEXT_PUBLIC_DEMO_MANAGER_ADDRESS || "";
  const rpcUrl = process.env.NEXT_PUBLIC_RPC_URL || "https://ethereum-sepolia-rpc.publicnode.com";
  const explorerBase = process.env.NEXT_PUBLIC_EXPLORER_URL || "https://sepolia.etherscan.io";

  const [provider, setProvider] = useState(null);
  const [hasWallet, setHasWallet] = useState(false);
  const [account, setAccount] = useState("");
  const [form, setForm] = useState(defaultForm);
  const [poolState, setPoolState] = useState(null);
  const [riskScore, setRiskScore] = useState(null);
  const [safeResult, setSafeResult] = useState("");
  const [contractMeta, setContractMeta] = useState(null);
  const [hookAddress, setHookAddress] = useState(configuredHookAddress);
  const [demoMeta, setDemoMeta] = useState(null);
  const [busyAction, setBusyAction] = useState("");
  const [status, setStatus] = useState("Loading pool state...");

  const hasDemo = useMemo(() => isAddress(demoManagerAddress), [demoManagerAddress]);
  const canRunDemo = hasDemo && provider && hasWallet;

  // A wallet is only needed to SEND transactions. Reads work over a plain RPC, so fall back to
  // one when no wallet is injected -- otherwise anyone opening the deployed URL without
  // MetaMask (a phone, say) sees an empty dashboard.
  useEffect(() => {
    if (typeof window !== "undefined" && window.ethereum) {
      setHasWallet(true);
      setProvider(new BrowserProvider(window.ethereum));
      setStatus("Wallet detected.");
      return;
    }

    setProvider(new JsonRpcProvider(rpcUrl));
    setStatus("Read-only. Live data straight from the chain, no wallet needed.");
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, []);

  useEffect(() => {
    if (!provider || !hasDemo) return;

    loadDemoMetadata(provider);
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [provider, hasDemo]);

  // Read-only mode: no demo contract to auto-detect the pool from, so pull state once on load
  // using the env-supplied hook address and poolId.
  useEffect(() => {
    if (!provider || hasDemo) return;
    if (!isAddress(hookAddress) || !form.poolId) return;

    refreshState();
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [provider, hasDemo, hookAddress]);

  async function connectWallet() {
    if (!provider || !hasWallet) return;

    try {
      await provider.send("eth_requestAccounts", []);
      const signer = await provider.getSigner();
      const network = await provider.getNetwork();
      setAccount(await signer.getAddress());
      setStatus(`Connected on chain ${network.chainId.toString()}.`);
    } catch (error) {
      setStatus(error.shortMessage || error.message);
    }
  }

  function updateField(event) {
    setForm((current) => ({
      ...current,
      [event.target.name]: event.target.value
    }));
  }

  async function loadDemoMetadata(activeProvider = provider) {
    if (!activeProvider || !hasDemo) return;

    try {
      const demo = new Contract(demoManagerAddress, frontendDemoAbi, activeProvider);
      const [guardianHook, detectedPoolId, predictedHook, hookSalt, demoRvmId, healthySwapCount] =
        await Promise.all([
          demo.guardianHook(),
          demo.poolId(),
          demo.predictedHook(),
          demo.hookSalt(),
          demo.DEMO_RVM_ID(),
          demo.healthySwapCount()
        ]);

      setHookAddress(guardianHook);
      setForm((current) => ({ ...current, poolId: current.poolId || detectedPoolId }));
      setDemoMeta({
        demoManager: demoManagerAddress,
        guardianHook,
        predictedHook,
        hookSalt,
        demoRvmId,
        healthySwapCount: healthySwapCount.toString()
      });
      setStatus("Demo contract detected. Pool ID loaded.");
    } catch (error) {
      setStatus(`Could not read demo contract: ${error.shortMessage || error.message}`);
    }
  }

  async function withGuardianHook(useSigner = false) {
    if (!provider) throw new Error("No provider available");
    if (!hookAddress || !isAddress(hookAddress)) {
      throw new Error("Set NEXT_PUBLIC_GUARDIAN_HOOK_ADDRESS or NEXT_PUBLIC_DEMO_MANAGER_ADDRESS");
    }
    if (useSigner && !hasWallet) throw new Error("Connect a wallet to send transactions");

    const runner = useSigner ? await provider.getSigner() : provider;
    return new Contract(hookAddress, guardianHookAbi, runner);
  }

  async function withDemo(useSigner = false) {
    if (!provider) throw new Error("No provider available");
    if (!hasDemo) throw new Error("NEXT_PUBLIC_DEMO_MANAGER_ADDRESS is not set");
    if (useSigner && !hasWallet) throw new Error("Connect a wallet to send transactions");

    const runner = useSigner ? await provider.getSigner() : provider;
    return new Contract(demoManagerAddress, frontendDemoAbi, runner);
  }

  async function refreshState() {
    try {
      const contract = await withGuardianHook();
      const [state, score, admin, poolManager, callbackSender, trustedReactiveRvmId] =
        await Promise.all([
          contract.getPoolState(form.poolId),
          contract.getHookRiskScore(form.poolId),
          contract.admin(),
          contract.poolManager(),
          contract.callbackSender(),
          contract.trustedReactiveRvmId()
        ]);

      setPoolState({
        registered: state.registered,
        paused: state.paused,
        lastSqrtPriceX96: state.lastSqrtPriceX96.toString(),
        lastTick: state.lastTick.toString(),
        liquidity: state.liquidity.toString(),
        lastAction: actionLabels[Number(state.lastAction)] ?? "Unknown",
        lastUpdatedAt: state.lastUpdatedAt.toString(),
        lastAlertReason: state.lastAlertReason,
        lastAlertAt: state.lastAlertAt.toString()
      });
      setRiskScore(score.toString());
      setContractMeta({ admin, poolManager, callbackSender, trustedReactiveRvmId });
      setStatus("Pool state refreshed.");
    } catch (error) {
      setStatus(error.shortMessage || error.message);
    }
  }

  async function validateSafety() {
    try {
      const contract = await withGuardianHook();
      const result = await contract.isSwapAllowed(form.poolId, BigInt(form.amountSpecified));
      setSafeResult(`${result[0] ? "SAFE" : "BLOCKED"} — ${result[1]}`);
      setStatus("Swap validation complete.");
    } catch (error) {
      setStatus(error.shortMessage || error.message);
    }
  }

  async function runDemoAction(label, method, args = []) {
    try {
      setBusyAction(label);
      const demo = await withDemo(true);
      const tx = await demo[method](...args);
      setStatus(`${label} submitted: ${tx.hash}`);
      await tx.wait();
      await loadDemoMetadata();
      await refreshState();
      await validateSafety();
      setStatus(`${label} confirmed.`);
    } catch (error) {
      setStatus(error.shortMessage || error.message);
    } finally {
      setBusyAction("");
    }
  }

  // ---- derived presentation state ----

  const phase = !poolState
    ? "unknown"
    : !poolState.registered
      ? "unregistered"
      : poolState.paused
        ? "paused"
        : poolState.lastAlertReason
          ? "alerted"
          : "healthy";

  // Every class here is a literal string: Tailwind's JIT only emits classes it can find in the
  // source, so these can never be assembled at runtime.
  const tone = {
    healthy: { text: "text-ok", bg: "bg-ok-bg", border: "border-ok", dot: "bg-ok", label: "Healthy" },
    alerted: { text: "text-warn", bg: "bg-warn-bg", border: "border-warn", dot: "bg-warn", label: "Alert raised" },
    paused: { text: "text-stop", bg: "bg-stop-bg", border: "border-stop", dot: "bg-stop", label: "Paused" },
    unregistered: { text: "text-muted", bg: "bg-raised", border: "border-rule", dot: "bg-muted", label: "Not registered" },
    unknown: { text: "text-muted", bg: "bg-raised", border: "border-rule", dot: "bg-muted", label: "No data" }
  }[phase];

  const activeIndex = PHASES.findIndex((p) => p.key === phase);

  // Explorer links only make sense against a public chain, not the local anvil demo.
  const explorerLink = (addr) =>
    !hasDemo && addr && isAddress(addr) ? `${explorerBase}/address/${addr}` : null;

  function AddressRow({ label, value }) {
    const href = explorerLink(value);
    return (
      <div className="row">
        <span className="row-k">{label}</span>
        {href ? (
          <a
            className="row-v text-accent underline decoration-accent-soft underline-offset-2 hover:decoration-accent"
            href={href}
            target="_blank"
            rel="noreferrer"
          >
            {shortAddress(value)}
          </a>
        ) : (
          <span className="row-v">{shortAddress(value)}</span>
        )}
      </div>
    );
  }

  return (
    <main className="mx-auto flex min-h-screen w-full max-w-5xl flex-col gap-5 px-5 py-8 sm:px-6">
      {/* masthead */}
      <header className="flex flex-wrap items-end justify-between gap-4 border-b-2 border-ink pb-5">
        <div>
          <p className="label">Uniswap v4 security hook</p>
          <h1 className="mt-2 font-sans text-3xl font-bold tracking-tight text-ink sm:text-4xl">
            AegisHook
          </h1>
          <p className="mt-2 max-w-xl text-[15px] text-ink-soft">
            Live security state for a guarded pool, read directly from the hook contract.
          </p>
        </div>
        <div className="flex flex-col items-start gap-2 sm:items-end">
          <span
            className={`rounded-full border px-3 py-1 font-sans text-[11px] font-bold uppercase tracking-label ${tone.border} ${tone.bg} ${tone.text}`}
          >
            {tone.label}
          </span>
          {hasWallet ? (
            <button className="btn" onClick={connectWallet}>
              {account ? shortAddress(account) : "Connect wallet"}
            </button>
          ) : (
            <span className="font-mono text-[11px] text-muted">read-only</span>
          )}
        </div>
      </header>

      {/* the story: risk score + where the pool sits in the state machine */}
      <section className="grid gap-5 md:grid-cols-[minmax(0,0.8fr)_minmax(0,1.2fr)]">
        <div className={`panel flex flex-col justify-between p-6 ${tone.bg}`}>
          <p className="label">Risk score</p>
          <p
            className={`mt-3 font-mono text-6xl font-bold leading-none ${tone.text}`}
            style={{ fontVariantNumeric: "tabular-nums" }}
          >
            {riskScore ?? "--"}
          </p>
          <p className="mt-3 text-[13px] text-ink-soft">
            {poolState?.lastAlertReason ? (
              <>
                Latest alert <span className="font-mono text-ink">{poolState.lastAlertReason}</span>
              </>
            ) : (
              "No alert on record for this pool."
            )}
          </p>
        </div>

        <div className="panel p-6">
          <p className="label">Detection to response</p>
          <ol className="mt-4 flex flex-col gap-0">
            {PHASES.map((p, i) => {
              const reached = activeIndex >= i && activeIndex !== -1;
              const current = activeIndex === i;
              return (
                <li
                  key={p.key}
                  className="grid grid-cols-[18px_1fr] gap-3 border-b border-rule-soft py-3 last:border-b-0"
                >
                  <span
                    aria-hidden="true"
                    className={`mt-1.5 h-2.5 w-2.5 rounded-full ${
                      current ? tone.dot : reached ? "bg-accent-soft" : "bg-rule"
                    }`}
                  />
                  <div>
                    <p
                      className={`font-sans text-sm font-semibold ${current ? tone.text : reached ? "text-ink" : "text-muted"}`}
                    >
                      {p.title}
                      {current && <span className="ml-2 font-normal text-muted">— now</span>}
                    </p>
                    <p className="text-[13px] text-muted">{p.note}</p>
                  </div>
                </li>
              );
            })}
          </ol>
        </div>
      </section>

      {/* pool + wiring */}
      <section className="grid gap-5 md:grid-cols-2">
        <div className="panel p-6">
          <p className="label">Pool state</p>
          <div className="mt-3">
            <div className="row">
              <span className="row-k">Registered</span>
              <span className="row-v">{poolState ? String(poolState.registered) : "--"}</span>
            </div>
            <div className="row">
              <span className="row-k">Paused</span>
              <span className={`row-v ${poolState?.paused ? "text-stop" : ""}`}>
                {poolState ? String(poolState.paused) : "--"}
              </span>
            </div>
            <div className="row">
              <span className="row-k">sqrtPriceX96</span>
              <span className="row-v">{poolState?.lastSqrtPriceX96 ?? "--"}</span>
            </div>
            <div className="row">
              <span className="row-k">Tick</span>
              <span className="row-v">{poolState?.lastTick ?? "--"}</span>
            </div>
            <div className="row">
              <span className="row-k">Liquidity</span>
              <span className="row-v">{poolState?.liquidity ?? "--"}</span>
            </div>
            <div className="row">
              <span className="row-k">Last action</span>
              <span className="row-v">{poolState?.lastAction ?? "--"}</span>
            </div>
            <div className="row">
              <span className="row-k">Alert at</span>
              <span className="row-v">{formatTimestamp(poolState?.lastAlertAt)}</span>
            </div>
            <div className="row">
              <span className="row-k">Updated</span>
              <span className="row-v">{formatTimestamp(poolState?.lastUpdatedAt)}</span>
            </div>
          </div>
        </div>

        <div className="panel p-6">
          <p className="label">Protocol wiring</p>
          <div className="mt-3">
            <AddressRow label="GuardianHook" value={hookAddress} />
            <AddressRow label="PoolManager" value={contractMeta?.poolManager} />
            <AddressRow label="Admin" value={contractMeta?.admin} />
            <AddressRow label="Callback sender" value={contractMeta?.callbackSender} />
            <AddressRow label="Trusted RVM ID" value={contractMeta?.trustedReactiveRvmId} />
            {hasDemo && <AddressRow label="Demo manager" value={demoMeta?.demoManager} />}
          </div>
          <p className="label mt-5">Pool ID</p>
          <p className="mt-2 overflow-x-auto whitespace-nowrap rounded bg-raised px-3 py-2 font-mono text-[12px] text-ink-soft">
            {form.poolId || "--"}
          </p>
          {!hasDemo && isAddress(hookAddress) && (
            <p className="mt-3 text-[13px] text-muted">
              Hook address ends in{" "}
              <span className="font-mono text-ink">{hookAddress.slice(-4)}</span> — the low bits
              encode its v4 permissions. A wrong address is rejected by the PoolManager.
            </p>
          )}
        </div>
      </section>

      {/* interactive: demo controls only exist against the local demo manager */}
      <section className="grid gap-5 md:grid-cols-2">
        {hasDemo && (
          <div className="panel p-6">
            <p className="label">Demo controls</p>
            <p className="mt-2 text-[13px] text-muted">Run in order.</p>
            <div className="mt-4 grid gap-2">
              <button
                className="btn"
                disabled={!canRunDemo || busyAction}
                onClick={() => runDemoAction("Healthy swap", "simulateHealthySwap")}
              >
                1 · Healthy swap
              </button>
              <button
                className="btn"
                disabled={!canRunDemo || busyAction}
                onClick={() => runDemoAction("Warning trigger", "triggerWarning")}
              >
                2 · Trigger alert
              </button>
              <button
                className="btn"
                disabled={!canRunDemo || busyAction}
                onClick={() => runDemoAction("Reactive pause", "triggerReactivePause", [form.reason])}
              >
                3 · Apply pause
              </button>
              <button
                className="btn"
                disabled={!canRunDemo || busyAction}
                onClick={() => runDemoAction("Demo reset", "resetDemo")}
              >
                Reset
              </button>
            </div>
          </div>
        )}

        <div className="panel p-6">
          <p className="label">Check a swap</p>
          <p className="mt-2 text-[13px] text-muted">
            Asks the hook whether it would admit a swap of this size right now.
          </p>
          <div className="mt-4 grid gap-2">
            <input
              className="field"
              name="poolId"
              placeholder="Pool ID (bytes32)"
              value={form.poolId}
              onChange={updateField}
            />
            <input
              className="field"
              name="amountSpecified"
              placeholder="Amount specified"
              value={form.amountSpecified}
              onChange={updateField}
            />
          </div>
          <div className="mt-3 grid gap-2 sm:grid-cols-2">
            <button className="btn-primary" onClick={validateSafety}>
              Run isSwapAllowed()
            </button>
            <button className="btn" onClick={refreshState}>
              Refresh state
            </button>
          </div>
          {safeResult && (
            <p
              className={`mt-3 rounded border px-3 py-2.5 font-mono text-[13px] ${
                safeResult.startsWith("SAFE")
                  ? "border-ok bg-ok-bg text-ok"
                  : "border-stop bg-stop-bg text-stop"
              }`}
            >
              {safeResult}
            </p>
          )}
        </div>
      </section>

      <footer className="mt-auto border-t border-rule pt-4">
        <p className="font-mono text-[12px] text-muted">
          {busyAction ? `${busyAction} — waiting for confirmation…` : status}
        </p>
      </footer>
    </main>
  );
}
