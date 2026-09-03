"use client";

import { useEffect, useMemo, useState } from "react";
import { BrowserProvider, Contract, isAddress } from "ethers";
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

  const [provider, setProvider] = useState(null);
  const [account, setAccount] = useState("");
  const [form, setForm] = useState(defaultForm);
  const [poolState, setPoolState] = useState(null);
  const [riskScore, setRiskScore] = useState(null);
  const [safeResult, setSafeResult] = useState("");
  const [contractMeta, setContractMeta] = useState(null);
  const [hookAddress, setHookAddress] = useState(configuredHookAddress);
  const [demoMeta, setDemoMeta] = useState(null);
  const [busyAction, setBusyAction] = useState("");
  const [status, setStatus] = useState("Connect a wallet on the demo chain.");

  const hasDemo = useMemo(() => isAddress(demoManagerAddress), [demoManagerAddress]);
  const canRunDemo = hasDemo && provider;

  useEffect(() => {
    if (!window.ethereum) {
      setStatus("No injected wallet found. Use MetaMask or another browser wallet on the demo chain.");
      return;
    }

    setProvider(new BrowserProvider(window.ethereum));
  }, []);

  useEffect(() => {
    if (!provider || !hasDemo) return;

    loadDemoMetadata(provider);
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [provider, hasDemo]);

  // Sepolia read-only mode: there is no demo contract to auto-detect the pool from, so pull
  // state once on load using the env-supplied hook address and poolId. Without this the
  // dashboard sits on "--" until someone clicks Refresh.
  useEffect(() => {
    if (!provider || hasDemo) return;
    if (!isAddress(hookAddress) || !form.poolId) return;

    refreshState();
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [provider, hasDemo, hookAddress]);

  async function connectWallet() {
    if (!provider) return;

    await provider.send("eth_requestAccounts", []);
    const signer = await provider.getSigner();
    const network = await provider.getNetwork();
    setAccount(await signer.getAddress());
    setStatus(`Wallet connected on chain ${network.chainId.toString()}.`);
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
      setStatus("Demo contract detected. Pool ID has been loaded.");
    } catch (error) {
      setStatus(`Could not read demo contract: ${error.shortMessage || error.message}`);
    }
  }

  async function withGuardianHook(useSigner = false) {
    if (!provider) throw new Error("Wallet provider unavailable");
    if (!hookAddress || !isAddress(hookAddress)) {
      throw new Error("Set NEXT_PUBLIC_GUARDIAN_HOOK_ADDRESS or NEXT_PUBLIC_DEMO_MANAGER_ADDRESS");
    }

    const runner = useSigner ? await provider.getSigner() : provider;
    return new Contract(hookAddress, guardianHookAbi, runner);
  }

  async function withDemo(useSigner = false) {
    if (!provider) throw new Error("Wallet provider unavailable");
    if (!hasDemo) throw new Error("NEXT_PUBLIC_DEMO_MANAGER_ADDRESS is not set");

    const runner = useSigner ? await provider.getSigner() : provider;
    return new Contract(demoManagerAddress, frontendDemoAbi, runner);
  }

  async function refreshState() {
    try {
      const contract = await withGuardianHook();
      const [state, score, admin, poolManager, callbackSender, trustedReactiveRvmId] = await Promise.all([
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
      setContractMeta({
        admin,
        poolManager,
        callbackSender,
        trustedReactiveRvmId
      });
      setStatus("Pool state refreshed from GuardianHook.");
    } catch (error) {
      setStatus(error.shortMessage || error.message);
    }
  }

  async function validateSafety() {
    try {
      const contract = await withGuardianHook();
      const result = await contract.isSwapAllowed(form.poolId, BigInt(form.amountSpecified));
      setSafeResult(`${result[0] ? "SAFE" : "BLOCKED"}: ${result[1]}`);
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

  const statusTone = poolState?.paused
    ? "border-red-200 bg-red-50 text-red-800"
    : poolState?.lastAlertReason
      ? "border-amber-200 bg-amber-50 text-amber-800"
      : "border-emerald-200 bg-emerald-50 text-emerald-800";

  return (
    <main className="mx-auto flex min-h-screen max-w-7xl flex-col gap-6 px-6 py-8">
      <section className="grid gap-6 lg:grid-cols-[1.15fr,0.85fr]">
        <div className="panel p-7">
          <p className="text-sm font-semibold uppercase tracking-[0.22em] text-orange-600">
            AegisHook Judge Console
          </p>
          <h1 className="mt-3 max-w-3xl text-4xl font-black leading-tight text-slate-950">
            Test the Uniswap v4 warning path from the frontend.
          </h1>
          <p className="mt-4 max-w-3xl text-base text-slate-600">
            The demo manager is the configured PoolManager and callback sender for this local setup. It lets judges run
            a healthy swap, trigger the suspicious no-op alert, and apply the Reactive pause while GuardianHook keeps its
            real caller checks.
          </p>
        </div>

        <div className="panel flex flex-col justify-between p-7">
          <div>
            <p className="text-sm font-semibold uppercase tracking-[0.18em] text-slate-500">Session</p>
            <p className="mt-4 break-all text-sm text-slate-700">{account || "No wallet connected"}</p>
            <p className="mt-2 text-sm text-slate-500">{status}</p>
          </div>
          <button className="button-primary mt-6" onClick={connectWallet}>
            Connect Wallet
          </button>
        </div>
      </section>

      <section className="grid gap-6 lg:grid-cols-[0.9fr,1.1fr]">
        <div className="panel p-7">
          <div className="flex flex-wrap items-center justify-between gap-3">
            <h2 className="text-2xl font-bold text-slate-950">Judge Test Flow</h2>
            <span className={`rounded-full border px-3 py-1 text-xs font-semibold ${statusTone}`}>
              {poolState?.paused ? "Paused" : poolState?.lastAlertReason ? "Warning raised" : "Healthy"}
            </span>
          </div>

          <div className="mt-6 grid gap-3">
            <button
              className="button-primary"
              disabled={!canRunDemo || busyAction}
              onClick={() => runDemoAction("Healthy swap", "simulateHealthySwap")}
            >
              1. Run healthy swap
            </button>
            <button
              className="button-warning"
              disabled={!canRunDemo || busyAction}
              onClick={() => runDemoAction("Warning trigger", "triggerWarning")}
            >
              2. Trigger warning
            </button>
            <button
              className="button-danger"
              disabled={!canRunDemo || busyAction}
              onClick={() => runDemoAction("Reactive pause", "triggerReactivePause", [form.reason])}
            >
              3. Apply Reactive pause
            </button>
            <button
              className="button-secondary"
              disabled={!canRunDemo || busyAction}
              onClick={() => runDemoAction("Demo reset", "resetDemo")}
            >
              Reset demo
            </button>
          </div>

          <div className="mt-6 grid gap-4">
            <input className="field" name="poolId" placeholder="Pool ID (bytes32)" value={form.poolId} onChange={updateField} />
            <input className="field" name="amountSpecified" placeholder="Amount specified" value={form.amountSpecified} onChange={updateField} />
            <input className="field" name="reason" placeholder="Pause reason" value={form.reason} onChange={updateField} />
          </div>

          <div className="mt-5 grid gap-3 md:grid-cols-2">
            <button className="button-secondary" onClick={refreshState}>Refresh State</button>
            <button className="button-secondary" onClick={validateSafety}>Run isSwapAllowed()</button>
          </div>

          <p className="mt-5 rounded-lg bg-slate-100 px-4 py-3 text-sm text-slate-700">
            {safeResult || "No validation run yet."}
          </p>
          <p className="mt-3 text-sm text-slate-500">
            {busyAction ? `${busyAction} is waiting for confirmation.` : "Run the steps in order for the clearest judge demo."}
          </p>
        </div>

        <div className="grid gap-6">
          <div className="panel p-7">
            <h2 className="text-2xl font-bold text-slate-950">Threat Dashboard</h2>
            <div className="mt-5 grid gap-4 md:grid-cols-[0.7fr,1.3fr]">
              <div className="rounded-lg bg-slate-950 p-5 text-white">
                <p className="text-sm uppercase tracking-[0.18em] text-orange-300">Risk Score</p>
                <p className="mt-4 text-5xl font-black">{riskScore ?? "--"}</p>
              </div>

              <div className="rounded-lg border border-slate-200 bg-slate-50 p-5 text-sm text-slate-700">
                <p className="font-semibold text-slate-950">Live Security Status</p>
                <div className="mt-4 grid gap-2">
                  <p>Registered: {poolState ? String(poolState.registered) : "--"}</p>
                  <p>Paused: {poolState ? String(poolState.paused) : "--"}</p>
                  <p>Latest alert: {poolState?.lastAlertReason || "--"}</p>
                  <p>Alert timestamp: {formatTimestamp(poolState?.lastAlertAt)}</p>
                  <p>Last action: {poolState?.lastAction || "--"}</p>
                  <p>Last updated: {formatTimestamp(poolState?.lastUpdatedAt)}</p>
                </div>
              </div>
            </div>

            <div className="mt-4 rounded-lg border border-slate-200 bg-white p-5 text-sm text-slate-700">
              <p className="font-semibold text-slate-950">Pool Snapshot</p>
              <div className="mt-4 grid gap-2">
                <p>sqrtPriceX96: {poolState?.lastSqrtPriceX96 || "--"}</p>
                <p>Tick: {poolState?.lastTick || "--"}</p>
                <p>Liquidity: {poolState?.liquidity || "--"}</p>
              </div>
            </div>
          </div>

          <div className="panel p-7">
            <h2 className="text-2xl font-bold text-slate-950">Protocol Wiring</h2>
            <div className="mt-5 grid gap-3 text-sm text-slate-700 md:grid-cols-2">
              <p>GuardianHook: {shortAddress(hookAddress)}</p>
              <p>Demo manager: {shortAddress(demoMeta?.demoManager)}</p>
              <p>Admin: {shortAddress(contractMeta?.admin)}</p>
              <p>Pool manager: {shortAddress(contractMeta?.poolManager)}</p>
              <p>Callback sender: {shortAddress(contractMeta?.callbackSender)}</p>
              <p>Trusted RVM ID: {shortAddress(contractMeta?.trustedReactiveRvmId)}</p>
              <p>Predicted hook: {shortAddress(demoMeta?.predictedHook)}</p>
              <p>Healthy swaps: {demoMeta?.healthySwapCount ?? "--"}</p>
            </div>
            <p className="mt-5 break-all rounded-lg bg-slate-100 px-4 py-3 text-xs text-slate-600">
              Pool ID: {form.poolId || "--"}
            </p>
          </div>
        </div>
      </section>
    </main>
  );
}
