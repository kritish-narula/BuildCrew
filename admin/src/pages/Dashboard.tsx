import { api, inr, type Kpis } from "../api";
import { Card, ErrorBox, Loading, PageHead, Pill, Stat, tradeLabel, useData } from "../ui";

type Pin = { id: string; lat: number; lng: number; status: string; locality: string; trades: string[] };
const COLORS: Record<string, string> = { open: "#0284c7", bidding: "#d97706", assigned: "#059669", in_progress: "#2563eb", disputed: "#dc2626" };
const AREAS: Record<string, [number, number]> = {
  Kothrud: [18.5074, 73.8077], Baner: [18.559, 73.7868], Hadapsar: [18.5089, 73.926], Wakad: [18.5986, 73.7604],
  "Viman Nagar": [18.5679, 73.9143], Aundh: [18.558, 73.8075], Kharadi: [18.5515, 73.9348], Shivajinagar: [18.5308, 73.8475],
};

export default function Dashboard() {
  const k = useData(() => api<Kpis>("/admin/kpis"));
  const m = useData(() => api<{ pins: Pin[]; by_locality: { locality: string; count: number }[] }>("/admin/map"));
  return (
    <div>
      <PageHead title="Dashboard" sub="Pune · live operations" />
      <ErrorBox msg={k.error || m.error} />
      {!k.data ? <Loading /> : (
        <div className="grid grid-cols-2 xl:grid-cols-4 gap-4">
          <Stat label="Active jobs" value={k.data.active_jobs} />
          <Stat label="Workers online" value={`${k.data.workers_online} / ${k.data.workers_total}`} tone="text-emerald-700" />
          <Stat label="Bids today" value={k.data.bids_today} hint={`${k.data.pending_bids} waiting for customers`} />
          <Stat label="Open disputes" value={k.data.open_disputes} tone={k.data.open_disputes ? "text-red-600" : undefined} />
          <Stat label="GMV" value={inr(k.data.gmv_inr)} hint="escrowed + paid" />
          <Stat label="In escrow now" value={inr(k.data.in_escrow_inr)} tone="text-amber-700" />
          <Stat label="Platform revenue" value={inr(k.data.platform_revenue_inr)} tone="text-brand-dark" hint="fees on released payments" />
          <Stat label="KYC to review" value={k.data.kyc_pending} tone={k.data.kyc_pending ? "text-sky-700" : undefined} />
        </div>
      )}
      <div className="grid lg:grid-cols-3 gap-4 mt-4">
        <Card title="Live job map" className="lg:col-span-2" action={<div className="flex gap-3 text-xs font-semibold text-stone-500">{Object.entries(COLORS).map(([s, c]) => <span key={s} className="flex items-center gap-1"><i className="size-2.5 rounded-full" style={{ background: c }} />{s.replace("_", " ")}</span>)}</div>}>
          {m.data ? <PuneMap pins={m.data.pins} /> : <Loading />}
        </Card>
        <Card title="Jobs by locality">
          {m.data?.by_locality.map((r) => (
            <div key={r.locality} className="flex items-center gap-3 py-1.5">
              <span className="w-28 text-sm font-semibold">{r.locality}</span>
              <div className="flex-1 h-2.5 rounded-full bg-stone-100"><div className="h-full rounded-full bg-brand" style={{ width: `${(r.count / Math.max(...m.data!.by_locality.map((x) => x.count))) * 100}%` }} /></div>
              <span className="w-6 text-right font-bold tabular-nums">{r.count}</span>
            </div>
          ))}
          {k.data && (
            <div className="mt-5 pt-4 border-t border-stone-100">
              <div className="text-sm font-bold mb-2">All jobs by status</div>
              <div className="flex flex-wrap gap-2">{Object.entries(k.data.jobs_by_status).map(([s, n]) => <Pill key={s} s={s}>{s.replace("_", " ")} · {n}</Pill>)}</div>
            </div>
          )}
        </Card>
      </div>
    </div>
  );
}

/** Schematic map (no API key needed): localities placed by real lat/lng, job pins on top.
 *  Swap for Google Maps JS when GOOGLE_MAPS_API_KEY is configured. */
function PuneMap({ pins }: { pins: Pin[] }) {
  const lats = Object.values(AREAS).map((a) => a[0]), lngs = Object.values(AREAS).map((a) => a[1]);
  const [la0, la1, lo0, lo1] = [Math.min(...lats) - 0.02, Math.max(...lats) + 0.02, Math.min(...lngs) - 0.03, Math.max(...lngs) + 0.03];
  const x = (lng: number) => ((lng - lo0) / (lo1 - lo0)) * 640;
  const y = (lat: number) => 340 - ((lat - la0) / (la1 - la0)) * 340;
  return (
    <svg viewBox="0 0 640 340" className="w-full rounded-xl bg-stone-50 border border-stone-100">
      <path d={`M0 ${y(18.535)} C 200 ${y(18.545)}, 380 ${y(18.52)}, 640 ${y(18.545)}`} stroke="#bae6fd" strokeWidth="10" fill="none" />
      {Object.entries(AREAS).map(([n, [la, lo]]) => (
        <g key={n}>
          <circle cx={x(lo)} cy={y(la)} r="34" fill="#f5f5f4" stroke="#e7e5e4" />
          <text x={x(lo)} y={y(la) + 48} textAnchor="middle" className="fill-stone-500" fontSize="12" fontWeight="600">{n}</text>
        </g>
      ))}
      {pins.map((p, i) => (
        <g key={p.id} transform={`translate(${x(p.lng) + ((i % 3) - 1) * 9}, ${y(p.lat) + ((i % 2) - 0.5) * 9})`}>
          <title>{`${p.locality} · ${p.status} · ${p.trades.map(tradeLabel).join(", ")}`}</title>
          <circle r="9" fill={COLORS[p.status] ?? "#78716c"} stroke="white" strokeWidth="2.5" />
        </g>
      ))}
    </svg>
  );
}
