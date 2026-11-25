import { useState } from "react";
import { api, fmtDate, fmtTime, inr } from "../api";
import { Card, ErrorBox, Loading, PageHead, Pill, Stat, useData } from "../ui";

type Row = { id: string; amount_inr: number; platform_fee_inr: number; worker_payout_inr: number; refund_inr: number; escrow_state: string; released_at: string | null; ref: string | null; locality: string; worker: string; customer: string; job_status: string };
type Payouts = { queue: { worker: string; available_inr: number; kyc_level: number }[]; history: { id: string; worker: string; amount_inr: number; upi: string; status: string; at: string; ref: string }[] };

export default function Payments() {
  const [tab, setTab] = useState<"ledger" | "payouts">("ledger");
  const ledger = useData(() => api<Row[]>("/admin/payments"));
  const payouts = useData(() => api<Payouts>("/admin/payouts"));
  const rows = ledger.data ?? [];
  const sum = (f: (r: Row) => boolean, k: keyof Row) => rows.filter(f).reduce((s, r) => s + (r[k] as number), 0);
  return (
    <div>
      <PageHead title="Payments & payouts" sub="Escrow ledger (Razorpay Route), worker payouts and revenue" />
      <ErrorBox msg={ledger.error || payouts.error} />
      <div className="grid grid-cols-2 xl:grid-cols-4 gap-4 mb-4">
        <Stat label="Held in escrow" value={inr(sum((r) => r.escrow_state === "held", "amount_inr"))} tone="text-amber-700" hint={`${rows.filter((r) => r.escrow_state === "held").length} jobs waiting for rating / review`} />
        <Stat label="Released to workers" value={inr(sum((r) => ["released", "split"].includes(r.escrow_state), "worker_payout_inr"))} tone="text-emerald-700" />
        <Stat label="Refunded" value={inr(sum(() => true, "refund_inr"))} />
        <Stat label="Platform revenue" value={inr(sum((r) => ["released", "split"].includes(r.escrow_state), "platform_fee_inr"))} tone="text-brand-dark" />
      </div>
      <div className="flex gap-2 mb-4">
        {(["ledger", "payouts"] as const).map((t) => <button key={t} onClick={() => setTab(t)} className={`rounded-xl px-4 py-2 text-sm font-bold ${tab === t ? "bg-stone-900 text-white" : "bg-white border border-stone-200"}`}>{t === "ledger" ? "Escrow ledger" : "Payout queue"}</button>)}
      </div>
      {tab === "ledger" ? (
        <Card>{!ledger.data ? <Loading /> : (
          <table className="w-full text-sm">
            <thead><tr className="text-left text-stone-500 border-b"><th className="py-2">Job</th><th>Customer → Worker</th><th className="text-right">Charged</th><th className="text-right">Payout</th><th className="text-right">Fee</th><th className="text-right">Refund</th><th>Escrow</th><th>Released</th></tr></thead>
            <tbody>{rows.map((r) => (
              <tr key={r.id} className="border-b border-stone-100">
                <td className="py-2.5">{r.locality}<div className="text-xs text-stone-400 font-mono">{r.ref}</div></td>
                <td>{r.customer} → {r.worker}</td>
                <td className="text-right tabular-nums">{inr(r.amount_inr)}</td><td className="text-right tabular-nums">{inr(r.worker_payout_inr)}</td>
                <td className="text-right tabular-nums">{inr(r.platform_fee_inr)}</td><td className="text-right tabular-nums">{r.refund_inr ? inr(r.refund_inr) : "—"}</td>
                <td><Pill s={r.escrow_state} /></td><td>{fmtDate(r.released_at)}</td>
              </tr>))}</tbody>
          </table>)}
        </Card>
      ) : (
        <div className="grid lg:grid-cols-2 gap-4">
          <Card title="Waiting to be withdrawn">
            {payouts.data?.queue.length === 0 && <p className="text-sm text-stone-500">Nothing waiting.</p>}
            {payouts.data?.queue.map((q) => <div key={q.worker} className="flex justify-between py-2 border-b last:border-0 border-stone-100 text-sm"><span>{q.worker} <span className="text-xs text-stone-400">KYC L{q.kyc_level}</span></span><b className="tabular-nums">{inr(q.available_inr)}</b></div>)}
            <p className="text-xs text-stone-500 mt-3">Workers withdraw from the app to their UPI ID. UPI IDs are encrypted at rest and shown masked.</p>
          </Card>
          <Card title="Payout history">
            {payouts.data?.history.map((p) => <div key={p.id} className="flex justify-between py-2 border-b last:border-0 border-stone-100 text-sm"><span>{p.worker}<div className="text-xs text-stone-400">{p.upi} · {fmtTime(p.at)}</div></span><span className="text-right"><b className="tabular-nums">{inr(p.amount_inr)}</b><div><Pill s={p.status} /></div></span></div>)}
          </Card>
        </div>
      )}
    </div>
  );
}
