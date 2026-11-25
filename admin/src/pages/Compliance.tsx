import { api, DEMO, getToken, inr } from "../api";
import { Btn, Card, ErrorBox, Loading, PageHead, Pill, Stat, useData } from "../ui";

type Row = { card_id: string; name: string; trades: string; city: string; kyc_level: number; eshram_registered: boolean; aadhaar: string; pan: string; earned_inr: number; jobs: number };

export default function Compliance() {
  const d = useData(() => api<{ rows: Row[]; eshram_registered: number; total: number }>("/admin/compliance"));
  const exportCsv = async () => {
    const csv = DEMO ? await api<string>("/admin/compliance.csv")
      : await (await fetch(`${import.meta.env.VITE_API_BASE_URL}/admin/compliance.csv`, { headers: { Authorization: `Bearer ${getToken()}` } })).text();
    const a = document.createElement("a");
    a.href = URL.createObjectURL(new Blob([csv], { type: "text/csv" }));
    a.download = `buildcrew-compliance-${new Date().toISOString().slice(0, 10)}.csv`;
    a.click();
    try { await navigator.clipboard.writeText(csv); } catch { /* download is the main path */ }
  };
  return (
    <div>
      <PageHead title="Compliance" sub="eShram registration and KYC status per worker" right={<Btn onClick={exportCsv}>⬇ Export CSV (also copied)</Btn>} />
      <ErrorBox msg={d.error} />
      {!d.data ? <Loading /> : (
        <>
          <div className="grid grid-cols-3 gap-4 mb-4">
            <Stat label="Workers" value={d.data.total} />
            <Stat label="eShram registered" value={`${d.data.eshram_registered} / ${d.data.total}`} tone="text-emerald-700" />
            <Stat label="Fully verified (L2)" value={d.data.rows.filter((r) => r.kyc_level === 2).length} />
          </div>
          <Card>
            <table className="w-full text-sm">
              <thead><tr className="text-left text-stone-500 border-b"><th className="py-2">Card ID</th><th>Name</th><th>Trades</th><th>KYC</th><th>Aadhaar</th><th>PAN</th><th>eShram</th><th className="text-right">Jobs</th><th className="text-right">Earned</th></tr></thead>
              <tbody>{d.data.rows.map((r) => (
                <tr key={r.card_id} className="border-b border-stone-100">
                  <td className="py-2 font-mono text-xs">{r.card_id}</td><td className="font-semibold">{r.name}</td><td>{r.trades}</td><td>L{r.kyc_level}</td>
                  <td><Pill s={r.aadhaar} /></td><td><Pill s={r.pan} /></td><td>{r.eshram_registered ? <Pill s="approved">registered</Pill> : <Pill s="not_submitted">no</Pill>}</td>
                  <td className="text-right tabular-nums">{r.jobs}</td><td className="text-right tabular-nums">{inr(r.earned_inr)}</td>
                </tr>))}</tbody>
            </table>
          </Card>
        </>
      )}
    </div>
  );
}
