import { useEffect, useRef } from "react";
import L from "leaflet";
import "leaflet/dist/leaflet.css";
import { api, inr, type Kpis } from "../api";
import { Card, ErrorBox, Loading, PageHead, Pill, Stat, tradeLabel, useData } from "../ui";

type Pin = { id: string; lat: number; lng: number; status: string; locality: string; trades: string[] };
const COLORS: Record<string, string> = { open: "#0284c7", bidding: "#d97706", assigned: "#059669", in_progress: "#2563eb", disputed: "#dc2626" };
const INDIA_CENTER: L.LatLngExpression = [22.5, 79];
const INDIA_ZOOM = 4;

export default function Dashboard() {
  const k = useData(() => api<Kpis>("/admin/kpis"));
  const m = useData(() => api<{ pins: Pin[]; by_locality: { locality: string; count: number }[] }>("/admin/map"));
  return (
    <div>
      <PageHead title="Dashboard" sub="India · live operations" />
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
          <Stat label="Police checks" value={k.data.police_pending ?? 0} tone={k.data.police_pending ? "text-sky-700" : undefined} hint="verification requests" />
        </div>
      )}
      <div className="grid lg:grid-cols-3 gap-4 mt-4">
        <Card title="Live job map" className="lg:col-span-2" action={<div className="flex gap-3 text-xs font-semibold text-stone-500">{Object.entries(COLORS).map(([s, c]) => <span key={s} className="flex items-center gap-1"><i className="size-2.5 rounded-full" style={{ background: c }} />{s.replace("_", " ")}</span>)}</div>}>
          {m.data ? <LiveMap pins={m.data.pins} /> : <Loading />}
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

/** Real interactive map (Leaflet + OpenStreetMap). Pins are L.circleMarker (vector, no image icons), so they
 *  still render when tiles are blocked (sandbox / offline); the grey background stands in for missing tiles. */
function LiveMap({ pins }: { pins: Pin[] }) {
  const el = useRef<HTMLDivElement>(null);
  useEffect(() => {
    if (!el.current) return;
    const map = L.map(el.current, { scrollWheelZoom: false }).setView(INDIA_CENTER, INDIA_ZOOM);
    L.tileLayer("https://tile.openstreetmap.org/{z}/{x}/{y}.png", {
      maxZoom: 19, attribution: '&copy; <a href="https://www.openstreetmap.org/copyright">OpenStreetMap</a> contributors',
    }).addTo(map);
    const pts: L.LatLngExpression[] = [];
    for (const p of pins) {
      if (typeof p.lat !== "number" || typeof p.lng !== "number") continue;
      const color = COLORS[p.status] ?? "#78716c";
      const m = L.circleMarker([p.lat, p.lng], { radius: 9, color: "#ffffff", weight: 2.5, fillColor: color, fillOpacity: 0.95 }).addTo(map);
      const pop = document.createElement("div"); // textContent: no HTML injection from job data
      const b = document.createElement("b");
      b.textContent = p.locality;
      pop.append(b, document.createElement("br"), `${p.status.replace("_", " ")} · ${p.trades.map(tradeLabel).join(", ")}`);
      m.bindPopup(pop);
      m.bindTooltip(p.locality);
      pts.push([p.lat, p.lng]);
    }
    if (pts.length > 1) map.fitBounds(L.latLngBounds(pts), { padding: [40, 40], maxZoom: 12 });
    else if (pts.length === 1) map.setView(pts[0], 12);
    const fix = window.setTimeout(() => map.invalidateSize(), 200);
    return () => { window.clearTimeout(fix); map.remove(); };
  }, [pins]);
  return <div ref={el} className="h-[380px] w-full rounded-xl border border-stone-100 bg-stone-100 z-0" />;
}
