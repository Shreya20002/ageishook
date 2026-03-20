"use client";

import { useEffect, useState } from "react";
import { BrowserProvider, Contract } from "ethers";
import { guardianHookAbi } from "../lib/guardianHookAbi";

const defaultForm = {
  poolId: "",
  amountSpecified: "10",
  reason: "NO_OP_ALERT"
};

const actionLabels = ["None", "Swap", "LiquidityAdded", "LiquidityRemoved", "Sync"];

export default function HomePage() {
  const [provider, setProvider] = useState(null);
  const [account, setAccount] = useState("");
  const [form, setForm] = useState(defaultForm);
  const [poolState, setPoolState] = useState(null);
  const [riskScore, setRiskScore] = useState(null);
  const [safeResult, setSafeResult] = useState("");
  const [contractMeta, setContractMeta] = useState(null);
  const [status, setStatus] = useState("Wallet not connected.");

  const contractAddress = process.env.NEXT_PUBLIC_GUARDIAN_HOOK_ADDRESS;

  useEffect(() => {
    if (!window.ethereum) {
      setStatus("No injected wallet found.");
      return;
    }

    setProvider(new BrowserProvider(window.ethereum));
  }, []);

  async function connectWallet() {
    if (!provider) {
      return;
    }

    const signer = await provider.getSigner();
    setAccount(await signer.getAddress());
    setStatus("Wallet connected.");
  }

  function updateField(event) {
    setForm((current) => ({
      ...current,
      [event.target.name]: event.target.value
    }));
  }

  async function withContract(useSigner = false) {
    if (!provider) {
      throw new Error("Wallet provider unavailable");
    }
    if (!contractAddress) {
      throw new Error("NEXT_PUBLIC_GUARDIAN_HOOK_ADDRESS is not set");
    }

    const runner = useSigner ? await provider.getSigner() : provider;
    return new Contract(contractAddress, guardianHookAbi, runner);
  }

  async function refreshState() {
    try {
      const contract = await withContract();
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
      setStatus("Pool state refreshed.");
    } catch (error) {
      setStatus(error.message);
    }
  }

  async function validateSafety() {
    try {
      const contract = await withContract();
      const result = await contract.isSwapAllowed(form.poolId, BigInt(form.amountSpecified));
      setSafeResult(`${result[0] ? "SAFE" : "BLOCKED"}: ${result[1]}`);
      setStatus("Swap validation complete.");
    } catch (error) {
      setStatus(error.message);
    }
  }

  return (
    <main className="mx-auto flex min-h-screen max-w-7xl flex-col gap-8 px-6 py-10">
      <section className="grid gap-6 lg:grid-cols-[1.2fr,0.8fr]">
        <div className="panel p-8">
          <p className="text-sm font-semibold uppercase tracking-[0.25em] text-orange-600">
            Uniswap V4 Guardian Hook
          </p>
          <h1 className="mt-4 max-w-2xl text-5xl font-black leading-tight text-slate-950">
            A real v4-core hook surface that reads pool state from PoolManager storage and escalates suspicious swaps through Reactive callbacks.
          </h1>
          <p className="mt-4 max-w-2xl text-lg text-slate-600">
            The dashboard is diagnostic. Swap gating happens inside the official v4 hook callback path, and emergency
            pauses are accepted only from the configured callback proxy plus trusted Reactive RVM ID.
          </p>
        </div>

        <div className="panel flex flex-col justify-between p-8">
          <div>
            <p className="text-sm font-semibold uppercase tracking-[0.2em] text-slate-500">Session</p>
            <p className="mt-4 break-all text-sm text-slate-700">
              {account || "No wallet connected"}
            </p>
            <p className="mt-2 text-sm text-slate-500">{status}</p>
          </div>
          <button className="button-primary mt-6" onClick={connectWallet}>
            Connect Wallet
          </button>
        </div>
      </section>

      <section className="grid gap-6 lg:grid-cols-2">
        <div className="panel p-8">
          <h2 className="text-2xl font-bold text-slate-950">Pool Controls</h2>
          <div className="mt-6 grid gap-4">
            <input className="field" name="poolId" placeholder="Pool ID (bytes32)" value={form.poolId} onChange={updateField} />
            <input className="field" name="amountSpecified" placeholder="Amount specified" value={form.amountSpecified} onChange={updateField} />
            <input className="field" name="reason" placeholder="Pause reason" value={form.reason} onChange={updateField} />
          </div>

          <div className="mt-6 grid gap-3 md:grid-cols-2">
            <button className="button-primary" onClick={refreshState}>Refresh State</button>
            <button className="button-secondary" onClick={validateSafety}>Run isSwapAllowed()</button>
          </div>

          <p className="mt-6 rounded-2xl bg-slate-100 px-4 py-3 text-sm text-slate-700">
            {safeResult || "No validation run yet."}
          </p>
          <p className="mt-4 rounded-2xl border border-slate-200 bg-slate-50 px-4 py-3 text-sm text-slate-600">
            This UI reads canonical pool IDs and hook metadata only. Real callback execution still depends on
            a permissioned hook deployment address and the v4 PoolManager.
          </p>
        </div>

        <div className="panel p-8">
          <h2 className="text-2xl font-bold text-slate-950">Threat Dashboard</h2>
          <div className="mt-6 grid gap-4">
            <div className="rounded-3xl bg-slate-950 p-6 text-white">
              <p className="text-sm uppercase tracking-[0.2em] text-orange-300">Hook Risk Score</p>
              <p className="mt-4 text-6xl font-black">{riskScore ?? "--"}</p>
            </div>

            <div className="rounded-3xl border border-slate-200 bg-slate-50 p-6 text-sm text-slate-700">
              <p className="font-semibold text-slate-950">Live Security Status</p>
              <div className="mt-4 grid gap-2">
                <p>Registered: {poolState ? String(poolState.registered) : "--"}</p>
                <p>Paused: {poolState ? String(poolState.paused) : "--"}</p>
                <p>Last sqrtPriceX96: {poolState?.lastSqrtPriceX96 || "--"}</p>
                <p>Last tick: {poolState?.lastTick || "--"}</p>
                <p>Liquidity: {poolState?.liquidity || "--"}</p>
                <p>Last action: {poolState?.lastAction || "--"}</p>
                <p>Last updated: {poolState?.lastUpdatedAt || "--"}</p>
                <p>Latest alert: {poolState?.lastAlertReason || "--"}</p>
                <p>Alert timestamp: {poolState?.lastAlertAt || "--"}</p>
              </div>
            </div>

            <div className="rounded-3xl border border-slate-200 bg-white p-6 text-sm text-slate-700">
              <p className="font-semibold text-slate-950">Protocol Wiring</p>
              <div className="mt-4 grid gap-2">
                <p>Admin: {contractMeta?.admin || "--"}</p>
                <p>Pool manager: {contractMeta?.poolManager || "--"}</p>
                <p>Callback sender: {contractMeta?.callbackSender || "--"}</p>
                <p>Trusted RVM ID: {contractMeta?.trustedReactiveRvmId || "--"}</p>
                <p>GuardianHook: {contractAddress || "--"}</p>
              </div>
            </div>
          </div>
        </div>
      </section>
    </main>
  );
}
