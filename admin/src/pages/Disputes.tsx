import { useState } from "react";
import { api, fmtTime, inr, post, type Payment, type WorkItem } from "../api";
import { ask, Btn, Card, Drawer, ErrorBox, Loading, PageHead, Pill, Stars, Toast, tradeLabel, useData } from "../ui";

type DisputeRow = { id: string; status: string; reason: string; created_at: string; raised_by: string; job_id: string; locality: string; worker: string; customer: string; amount_inr: number; resolution: string | null };
type Evidence = DisputeRow & {
  job: { work_items: WorkItem[]; address: string; trades: string[] };
  assignment: { price_inr: number; payment: Payment; attendance: { in: string; out: string | null; offline: boolean; geofence_ok: boolean; selfie?: string | null }[]; started_at: string | null; completed_at: string | null };
  customer: { name: string; phone: string; rating: number | null; ratings: { overall: number; comment: string | null }[] };
  worker: { name: string; phone: string; rating: number; rating_count: number; strikes: number; breakdown: Record<string, number> };
  chat: { from: string; body: string; at: string }[];
};

/** Photos + text + the customer's AUDIO with an inline player, transcript side by side,
 *  and moderation (flag / mute from worker feed — the file is retained for the audit log). */
export function WorkItemEvidence({ wi, onChanged }: { wi: WorkItem; onChanged?: () => void }) {
  const moderate = async (body: { flagged?: boolean; muted?: boolean }) => { await post(`/admin/work-items/${wi.id}/audio`, body); onChanged?.(); };
  return (
    <Card title={<span>Work {wi.index} · {tradeLabel(wi.trade)}</span>}>
      {wi.photos.length > 0 && (
        <div className="flex gap-2 overflow-x-auto mb-3">
          {wi.photos.map((p) => <a key={p} href={p} target="_blank" rel="noreferrer"><img src={p} className="h-28 w-40 object-cover rounded-xl bg-stone-100 border" alt="" /></a>)}
        </div>
      )}
      {wi.text && <p className="text-[15px] leading-relaxed">{wi.text}</p>}
      {wi.audio && (
        <div className="mt-3 grid md:grid-cols-2 gap-3">
          <div className="rounded-xl bg-orange-50 border border-orange-100 p-3">
            <div className="text-xs font-bold text-orange-800 mb-2">🔊 Customer voice note · {wi.audio.duration_sec}s · {wi.audio.size_kb} KB
              {wi.audio.flagged && <span className="ml-2 text-red-600">FLAGGED</span>}{wi.audio.muted && <span className="ml-2 text-stone-600">MUTED IN FEED</span>}</div>
            <audio controls preload="none" src={wi.audio.url} className="w-full" />
            <div className="mt-2 flex gap-2">
              <Btn small kind="ghost" onClick={() => moderate({ flagged: !wi.audio!.flagged })}>{wi.audio.flagged ? "Unflag" : "Flag"}</Btn>
              <Btn small kind="ghost" onClick={() => moderate({ muted: !wi.audio!.muted })}>{wi.audio.muted ? "Unmute in feed" : "Mute from worker feed"}</Btn>
            </div>
          </div>
          <div className="rounded-xl bg-stone-50 border border-stone-200 p-3">
            <div className="text-xs font-bold text-stone-500 mb-1">Auto-transcript (customer-reviewed)</div>
            <p className="text-[15px] leading-relaxed">{wi.transcript ?? "—"}</p>
          </div>
        </div>
      )}
    </Card>
  );
}

export default function Disputes() {
  const [open, setOpen] = useState<string | null>(null);
  const [share, setShare] = useState(50);
  const [penalise, setPenalise] = useState(false);
  const [note, setNote] = useState("");
  const [toast, setToast] = useState("");
  const list = useData(() => api<DisputeRow[]>("/admin/disputes"));
  const ev = useData(() => (open ? api<Evidence>(`/admin/disputes/${open}`) : Promise.resolve(null)), [open]);

  const resolve = async (pct: number) => {
    const what = pct >= 100 ? "release the full payment to the worker" : pct === 0 ? "refund the customer in full" : `split: ${pct}% of the worker payout to the worker, rest refunded`;
    if (!(await ask(`Confirm: ${what}${penalise ? " and add a strike to the worker" : ""}?`))) return;
    await post(`/admin/disputes/${open}/resolve`, { worker_share_pct: pct, penalise, note });
    setToast("Dispute resolved"); ev.reload(); list.reload();
  };

  const e = ev.data;
  return (
    <div>
      <PageHead title="Disputes" sub="Review all evidence, then release, refund or split the escrow" />
      <Card>
        <ErrorBox msg={list.error} />
        {!list.data ? <Loading /> : list.data.length === 0 ? <p className="text-stone-500">No disputes.</p> : (
          <table className="w-full text-sm">
            <thead><tr className="text-left text-stone-500 border-b"><th className="py-2">Raised</th><th>Reason</th><th>Customer → Worker</th><th>Escrow</th><th>Status</th></tr></thead>
            <tbody>{list.data.map((d) => (
              <tr key={d.id} onClick={() => setOpen(d.id)} className="border-b border-stone-100 hover:bg-stone-50 cursor-pointer">
                <td className="py-3 whitespace-nowrap">{fmtTime(d.created_at)}</td>
                <td className="max-w-md truncate">{d.reason}</td>
                <td>{d.customer} → {d.worker}</td>
                <td className="tabular-nums font-bold">{inr(d.amount_inr)}</td>
                <td><Pill s={d.status} /></td>
              </tr>
            ))}</tbody>
          </table>
        )}
      </Card>

      <Drawer open={!!open} onClose={() => setOpen(null)} title={e ? `Dispute · ${e.locality}` : "Dispute"}>
        {!e ? <Loading /> : (
          <>
            <Card>
              <div className="flex items-start justify-between gap-4">
                <div><div className="text-xs font-bold text-stone-500">Raised by {e.raised_by} · {fmtTime(e.created_at)}</div><p className="mt-1 text-[15px]">{e.reason}</p></div>
                <Pill s={e.status} />
              </div>
              {e.resolution && <p className="mt-3 text-sm rounded-lg bg-emerald-50 text-emerald-800 px-3 py-2">Resolution: {e.resolution}</p>}
            </Card>
            <div className="grid grid-cols-2 gap-4">
              <Card title="Customer">
                <div className="font-bold">{e.customer.name}</div><div className="text-sm text-stone-500">{e.customer.phone}</div>
                <div className="mt-1 text-sm">As rated by workers: <Stars v={e.customer.rating ?? 0} /></div>
                {e.customer.ratings.map((r, i) => <div key={i} className="text-xs text-stone-500 mt-1">★{r.overall} {r.comment && `“${r.comment}”`}</div>)}
              </Card>
              <Card title="Worker">
                <div className="font-bold">{e.worker.name} <Stars v={e.worker.rating} /></div><div className="text-sm text-stone-500">{e.worker.phone} · strikes: {e.worker.strikes}</div>
                <div className="mt-2 grid grid-cols-2 gap-x-3 text-xs">
                  {Object.entries(e.worker.breakdown).filter(([k]) => !["overall", "count"].includes(k)).map(([k, v]) => <div key={k} className="flex justify-between"><span className="text-stone-500">{k.replaceAll("_", " ")}</span><b>{Number(v).toFixed(1)}</b></div>)}
                </div>
              </Card>
            </div>
            <Card title="Escrow">
              <div className="grid grid-cols-4 gap-3 text-sm">
                <div><div className="text-stone-500">Charged</div><b>{inr(e.assignment.payment.amount_inr)}</b></div>
                <div><div className="text-stone-500">Worker payout</div><b>{inr(e.assignment.payment.worker_payout_inr)}</b></div>
                <div><div className="text-stone-500">Platform fee</div><b>{inr(e.assignment.payment.platform_fee_inr)}</b></div>
                <div><div className="text-stone-500">State</div><Pill s={e.assignment.payment.escrow_state} /></div>
              </div>
            </Card>
            {e.job.work_items.map((wi) => <WorkItemEvidence key={wi.id} wi={wi} onChanged={ev.reload} />)}
            <div className="grid grid-cols-2 gap-4">
              <Card title={`Chat log (${e.chat.length})`}>
                <div className="space-y-2">{e.chat.map((m, i) => (
                  <div key={i} className={`flex ${m.from === "customer" ? "justify-start" : "justify-end"}`}>
                    <div className={`max-w-[85%] rounded-2xl px-3 py-2 text-sm ${m.from === "customer" ? "bg-stone-100" : "bg-orange-100"}`}>
                      <div className="text-[10px] font-bold uppercase text-stone-500">{m.from} · {fmtTime(m.at)}</div>{m.body}
                    </div>
                  </div>))}</div>
              </Card>
              <Card title="Attendance">
                {e.assignment.attendance.length === 0 ? <p className="text-sm text-stone-500">No check-ins recorded.</p> : e.assignment.attendance.map((a, i) => (
                  <div key={i} className="flex items-center gap-3 py-1.5 text-sm">
                    {a.selfie && <img src={a.selfie} className="size-9 rounded-full object-cover" alt="" />}
                    <div>{fmtTime(a.in)} → {a.out ? fmtTime(a.out) : "…"}<div className="text-xs text-stone-500">{a.offline && "synced later · "}{a.geofence_ok ? "at site ✓" : <b className="text-amber-700">away from site</b>}</div></div>
                  </div>))}
                <div className="text-xs text-stone-500 mt-2">Started {fmtTime(e.assignment.started_at)} · completed {fmtTime(e.assignment.completed_at)}</div>
              </Card>
            </div>
            {e.status !== "resolved" && (
              <Card title="Resolve">
                <label className="text-sm font-semibold">Worker gets {share}% of their payout ({inr((e.assignment.payment.worker_payout_inr * share) / 100)})</label>
                <input type="range" min={0} max={100} step={5} value={share} onChange={(x) => setShare(Number(x.target.value))} className="w-full accent-orange-600 mt-2" />
                <div className="flex items-center gap-2 mt-3"><input id="pen" type="checkbox" checked={penalise} onChange={(x) => setPenalise(x.target.checked)} /><label htmlFor="pen" className="text-sm">Penalise worker (adds a strike · 3 strikes = auto-suspend)</label></div>
                <textarea value={note} onChange={(x) => setNote(x.target.value)} placeholder="Internal note (kept in audit log)" className="mt-3 w-full rounded-xl border border-stone-300 p-3 text-sm" rows={2} />
                <div className="mt-3 flex flex-wrap gap-2">
                  <Btn kind="ok" onClick={() => resolve(100)}>Release to worker</Btn>
                  <Btn kind="primary" onClick={() => resolve(share)}>Split {share}%</Btn>
                  <Btn kind="danger" onClick={() => resolve(0)}>Refund customer</Btn>
                </div>
              </Card>
            )}
          </>
        )}
      </Drawer>
      <Toast msg={toast} onDone={() => setToast("")} />
    </div>
  );
}
