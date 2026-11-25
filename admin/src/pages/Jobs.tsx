import { useState } from "react";
import { api, fmtDate, fmtTime, inr, post, type JobRow, type Payment, type WorkItem } from "../api";
import { ask, Btn, Card, Drawer, ErrorBox, Loading, PageHead, Pill, Stars, Toast, tradeLabel, useData } from "../ui";
import { WorkItemEvidence } from "./Disputes";

const STATUSES = ["", "open", "bidding", "assigned", "in_progress", "completed", "disputed", "cancelled"];
type JobDetail = JobRow & {
  work_items: WorkItem[]; bids: { id: string; price_inr: number; status: string; created_at: string; worker: { name: string; rating: number; completed_jobs: number } }[];
  assignment: { worker: { name: string }; price_inr: number; payment: Payment | null; attendance: { in: string; out: string | null; offline: boolean; geofence_ok: boolean }[] } | null;
  audit: { action: string; at: string }[];
};

export default function Jobs() {
  const [status, setStatus] = useState("");
  const [open, setOpen] = useState<string | null>(null);
  const [toast, setToast] = useState("");
  const list = useData(() => api<JobRow[]>(`/admin/jobs${status ? "?status=" + status : ""}`), [status]);
  const detail = useData(() => (open ? api<JobDetail>(`/admin/jobs/${open}`) : Promise.resolve(null)), [open]);
  const stuck = (j: JobRow) => ["open", "bidding"].includes(j.status) && Date.now() - new Date(j.created_at).getTime() > 3 * 86400_000;

  return (
    <div>
      <PageHead title="Jobs & bids" sub="Every job, its bids and history. Intervene on stuck jobs." />
      <div className="flex flex-wrap gap-2 mb-4">
        {STATUSES.map((s) => (
          <button key={s} onClick={() => setStatus(s)} className={`rounded-xl px-3.5 py-2 text-sm font-bold ${status === s ? "bg-stone-900 text-white" : "bg-white border border-stone-200"}`}>
            {s ? s.replace("_", " ") : "All"}
          </button>
        ))}
      </div>
      <Card>
        <ErrorBox msg={list.error} />
        {!list.data ? <Loading /> : (
          <table className="w-full text-sm">
            <thead><tr className="text-left text-stone-500 border-b"><th className="py-2">Job</th><th>Customer</th><th>Locality</th><th>Posted</th><th>Bids</th><th>Status</th></tr></thead>
            <tbody>{list.data.map((j) => (
              <tr key={j.id} onClick={() => setOpen(j.id)} className="border-b border-stone-100 hover:bg-stone-50 cursor-pointer">
                <td className="py-2.5"><div className="flex items-center gap-3">
                  <img src={j.thumbnail ?? ""} className="size-10 rounded-lg object-cover bg-stone-100" alt="" />
                  <span className="font-semibold">{[...new Set(j.trades)].map(tradeLabel).join(", ")}</span></div></td>
                <td>{j.customer}</td><td>{j.locality}</td><td>{fmtDate(j.created_at)}</td><td className="tabular-nums">{j.bid_count}</td>
                <td><Pill s={j.status} />{stuck(j) && <span className="ml-2 text-xs font-bold text-red-600">stuck</span>}</td>
              </tr>
            ))}</tbody>
          </table>
        )}
      </Card>
      <Drawer open={!!open} onClose={() => setOpen(null)} title={detail.data ? `${detail.data.locality} · ${detail.data.customer}` : "Job"}>
        {!detail.data ? <Loading /> : (
          <>
            <div className="flex items-center gap-3"><Pill s={detail.data.status} /><span className="text-sm text-stone-500">{detail.data.address} · starts {detail.data.start_date}</span></div>
            {detail.data.assignment && (
              <Card title="Assignment">
                <div className="flex justify-between"><span>{detail.data.assignment.worker.name}</span><b>{inr(detail.data.assignment.price_inr)}</b></div>
                {detail.data.assignment.payment && <div className="mt-2 flex gap-2 items-center text-sm"><Pill s={detail.data.assignment.payment.escrow_state} /> {inr(detail.data.assignment.payment.amount_inr)} charged · fee {inr(detail.data.assignment.payment.platform_fee_inr)}</div>}
                {detail.data.assignment.attendance.map((a, i) => <div key={i} className="text-sm text-stone-600 mt-1">Day {i + 1}: {fmtTime(a.in)} → {a.out ? fmtTime(a.out) : "…"} {a.offline && "· synced later"} {!a.geofence_ok && <b className="text-amber-700">· away from site</b>}</div>)}
              </Card>
            )}
            <Card title={`Bids (${detail.data.bids.length})`}>
              {detail.data.bids.length === 0 ? <p className="text-stone-500 text-sm">No bids yet.</p> : detail.data.bids.map((b) => (
                <div key={b.id} className="flex items-center justify-between py-2 border-b last:border-0 border-stone-100">
                  <div><b>{b.worker.name}</b> <Stars v={b.worker.rating} /> <span className="text-xs text-stone-500">{b.worker.completed_jobs} jobs</span></div>
                  <div className="flex items-center gap-3"><b className="tabular-nums">{inr(b.price_inr)}</b><Pill s={b.status} /></div>
                </div>
              ))}
            </Card>
            {detail.data.work_items.map((wi) => <WorkItemEvidence key={wi.id} wi={wi} onChanged={detail.reload} />)}
            <Card title="Audit trail">
              {detail.data.audit.map((a, i) => <div key={i} className="text-sm flex justify-between py-1"><code>{a.action}</code><span className="text-stone-500">{fmtTime(a.at)}</span></div>)}
            </Card>
            {!["completed", "cancelled"].includes(detail.data.status) && (
              <Btn kind="danger" onClick={async () => {
                if (!(await ask("Cancel this job? Any escrow is refunded to the customer in full."))) return;
                await post(`/admin/jobs/${open}/cancel`); setToast("Job cancelled, escrow refunded"); detail.reload(); list.reload();
              }}>Cancel job & refund</Btn>
            )}
          </>
        )}
      </Drawer>
      <Toast msg={toast} onDone={() => setToast("")} />
    </div>
  );
}
