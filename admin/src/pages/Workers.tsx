import { useState } from "react";
import { api, fmtTime, inr, post, type PoliceRow, type WorkerRow } from "../api";
import { ask, Btn, Card, ErrorBox, Loading, PageHead, Pill, Stars, Toast, TRADES, tradeLabel, useData } from "../ui";

export default function Workers() {
  const [tab, setTab] = useState<"kyc" | "police" | "all">("kyc");
  const [f, setF] = useState({ trade: "", kyc: "", min_rating: "", q: "", suspended: "" });
  const [toast, setToast] = useState("");
  const queue = useData(() => api<WorkerRow[]>("/admin/kyc-queue"));
  const police = useData(() => api<PoliceRow[]>("/admin/police-queue?status=all"));
  const qs = new URLSearchParams(Object.entries(f).filter(([, v]) => v) as [string, string][]).toString();
  const list = useData(() => api<WorkerRow[]>(`/admin/workers${qs ? "?" + qs : ""}`), [qs]);

  const decide = async (w: WorkerRow, approve: boolean) => {
    const note = approve ? undefined : await ask("Reason for rejecting (shown to the worker):", "Photo not clear");
    if (!approve && note === null) return;
    await post(`/admin/workers/${w.id}/kyc`, { approve, note });
    setToast(`${w.name}: KYC ${approve ? "approved" : "rejected"}`);
    queue.reload(); list.reload();
  };
  const decidePolice = async (w: PoliceRow, approve: boolean) => {
    const note = approve ? undefined : await ask("Reason for rejecting (shown to the worker):", "Address could not be matched");
    if (!approve && note === null) return;
    await post(`/admin/workers/${w.id}/police`, { approve, note });
    setToast(`${w.name}: police check ${approve ? "verified" : "rejected"}`);
    police.reload();
  };
  const suspend = async (w: WorkerRow) => {
    const reason = w.suspended ? "" : (await ask(`Suspend ${w.name}? Reason (no-show, fraud…):`, "")) ?? "";
    if (!w.suspended && !reason) return;
    await post(`/admin/workers/${w.id}/suspend`, { suspend: !w.suspended, reason });
    setToast(`${w.name} ${w.suspended ? "reinstated" : "suspended"}`);
    list.reload();
  };

  return (
    <div>
      <PageHead title="Workers & KYC" sub="Approve documents, find workers, suspend for no-shows or fraud" />
      <div className="flex gap-2 mb-4">
        {(["kyc", "police", "all"] as const).map((t) => (
          <button key={t} onClick={() => setTab(t)} className={`rounded-xl px-4 py-2 text-sm font-bold ${tab === t ? "bg-stone-900 text-white" : "bg-white border border-stone-200"}`}>
            {t === "kyc" ? `KYC queue${queue.data ? ` (${queue.data.length})` : ""}` : t === "police" ? `Police check${police.data ? ` (${police.data.filter((w) => w.police_status === "pending").length})` : ""}` : "Directory"}
          </button>
        ))}
      </div>
      {tab === "kyc" ? (
        <div className="space-y-4">
          <ErrorBox msg={queue.error} />
          {!queue.data ? <Loading /> : queue.data.length === 0 ? <Card><p className="text-stone-500">Nothing to review. 🎉</p></Card> : queue.data.map((w) => (
            <Card key={w.id}>
              <div className="flex gap-5">
                <img src={w.doc_url ?? ""} className="w-72 h-44 object-cover rounded-xl bg-stone-100 border" alt="ID document" />
                <div className="flex-1">
                  <div className="flex items-center gap-3">
                    <img src={w.selfie ?? ""} className="size-12 rounded-full object-cover bg-stone-100" alt="" />
                    <div>
                      <div className="font-extrabold text-lg">{w.name}</div>
                      <div className="text-sm text-stone-500">{w.phone} · {w.trades.map(tradeLabel).join(", ")}</div>
                    </div>
                  </div>
                  <div className="mt-3 grid grid-cols-3 gap-3 text-sm">
                    <div><div className="text-stone-500">Document</div><div className="font-bold uppercase">{w.doc_type ?? "aadhaar"}</div></div>
                    <div><div className="text-stone-500">Earned so far</div><div className="font-bold">{inr(w.earned_inr)}</div></div>
                    <div><div className="text-stone-500">Rating</div><Stars v={w.rating} /></div>
                  </div>
                  <p className="mt-3 text-xs text-stone-500">Only the verification result is stored — never the Aadhaar/PAN number.</p>
                  <div className="mt-4 flex gap-2"><Btn kind="ok" onClick={() => decide(w, true)}>Approve</Btn><Btn kind="ghost" onClick={() => decide(w, false)}>Reject</Btn></div>
                </div>
              </div>
            </Card>
          ))}
        </div>
      ) : tab === "police" ? (
        <Card title="Police verification requests">
          <ErrorBox msg={police.error} />
          {!police.data ? <Loading /> : police.data.length === 0 ? <p className="text-stone-500">No requests yet.</p> : (
            <table className="w-full text-sm">
              <thead><tr className="text-left text-stone-500"><th className="py-2">Worker</th><th>Trades</th><th>Requested</th><th>Status</th><th /></tr></thead>
              <tbody>
                {police.data.map((w) => (
                  <tr key={w.id} className="border-t border-stone-100">
                    <td className="py-2"><div className="font-bold">{w.name}</div><div className="text-xs text-stone-500">{w.phone} · {w.city} · KYC L{w.kyc_level}</div></td>
                    <td>{w.trades.map(tradeLabel).join(", ")}</td>
                    <td>{fmtTime(w.requested_at)}</td>
                    <td><Pill s={w.police_status === "verified" ? "approved" : w.police_status === "rejected" ? "rejected" : "assigned"}>{w.police_status}</Pill>{w.note ? <div className="text-xs text-stone-500">{w.note}</div> : null}</td>
                    <td className="text-right">{w.police_status === "pending" ? <div className="flex gap-2 justify-end"><Btn kind="ok" onClick={() => decidePolice(w, true)}>Verify</Btn><Btn kind="ghost" onClick={() => decidePolice(w, false)}>Reject</Btn></div> : null}</td>
                  </tr>
                ))}
              </tbody>
            </table>
          )}
        </Card>
      ) : (
        <Card>
          <div className="flex flex-wrap gap-2 mb-4">
            <input placeholder="Search name / phone" value={f.q} onChange={(e) => setF({ ...f, q: e.target.value })} className="rounded-xl border border-stone-300 px-3 py-2 text-sm w-56" />
            <select value={f.trade} onChange={(e) => setF({ ...f, trade: e.target.value })} className="rounded-xl border border-stone-300 px-3 py-2 text-sm">
              <option value="">All trades</option>{TRADES.map((t) => <option key={t} value={t}>{tradeLabel(t)}</option>)}
            </select>
            <select value={f.kyc} onChange={(e) => setF({ ...f, kyc: e.target.value })} className="rounded-xl border border-stone-300 px-3 py-2 text-sm">
              <option value="">Any KYC</option><option value="0">L0 · phone</option><option value="1">L1 · UPI</option><option value="2">L2 · ID</option>
            </select>
            <select value={f.min_rating} onChange={(e) => setF({ ...f, min_rating: e.target.value })} className="rounded-xl border border-stone-300 px-3 py-2 text-sm">
              <option value="">Any rating</option><option value="4">4★+</option><option value="4.5">4.5★+</option>
            </select>
            <select value={f.suspended} onChange={(e) => setF({ ...f, suspended: e.target.value })} className="rounded-xl border border-stone-300 px-3 py-2 text-sm">
              <option value="">Active + suspended</option><option value="false">Active</option><option value="true">Suspended</option>
            </select>
          </div>
          <ErrorBox msg={list.error} />
          {!list.data ? <Loading /> : (
            <table className="w-full text-sm">
              <thead><tr className="text-left text-stone-500 border-b">
                <th className="py-2">Worker</th><th>Trades</th><th>Rating</th><th>Jobs</th><th>KYC</th><th>eShram</th><th>Earned</th><th>Status</th><th />
              </tr></thead>
              <tbody>{list.data.map((w) => (
                <tr key={w.id} className="border-b border-stone-100 hover:bg-stone-50">
                  <td className="py-2.5"><div className="font-bold">{w.name}</div><div className="text-xs text-stone-500">{w.phone}</div></td>
                  <td>{w.trades.map(tradeLabel).join(", ")}</td>
                  <td><Stars v={w.rating} /> <span className="text-stone-400">({w.rating_count})</span></td>
                  <td className="tabular-nums">{w.completed_jobs}</td>
                  <td><Pill s={w.kyc_level === 2 ? "approved" : w.kyc_level === 1 ? "assigned" : "not_submitted"}>L{w.kyc_level}</Pill></td>
                  <td>{w.eshram ? "✓" : "—"}</td>
                  <td className="tabular-nums">{inr(w.earned_inr)}</td>
                  <td>{w.suspended ? <Pill s="disputed">suspended</Pill> : w.online ? <Pill s="accepted">online</Pill> : <Pill s="cancelled">offline</Pill>}
                    {w.strikes > 0 && <span className="ml-1 text-xs text-red-600 font-bold">{w.strikes}⚠</span>}</td>
                  <td className="text-right"><Btn small kind={w.suspended ? "ok" : "ghost"} onClick={() => suspend(w)}>{w.suspended ? "Reinstate" : "Suspend"}</Btn></td>
                </tr>
              ))}</tbody>
            </table>
          )}
        </Card>
      )}
      <Toast msg={toast} onDone={() => setToast("")} />
    </div>
  );
}
