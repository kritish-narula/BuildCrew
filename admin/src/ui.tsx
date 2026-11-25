import { useEffect, useState, type ReactNode } from "react";
import { ApiError } from "./api";

export const TRADES = ["mason", "plumber", "electrician", "carpenter", "painter", "helper"];
const TRADE_ICON: Record<string, string> = { mason: "🧱", plumber: "🚰", electrician: "⚡", carpenter: "🪚", painter: "🎨", helper: "🧰" };
export const tradeLabel = (t: string) => `${TRADE_ICON[t] ?? "🔧"} ${t[0].toUpperCase()}${t.slice(1)}`;

const STATUS: Record<string, string> = {
  open: "bg-sky-100 text-sky-800", bidding: "bg-amber-100 text-amber-800", assigned: "bg-emerald-100 text-emerald-800",
  in_progress: "bg-blue-100 text-blue-800", completed: "bg-stone-200 text-stone-700", disputed: "bg-red-100 text-red-700",
  cancelled: "bg-stone-100 text-stone-500", pending: "bg-amber-100 text-amber-800", accepted: "bg-emerald-100 text-emerald-800",
  rejected: "bg-stone-100 text-stone-500", held: "bg-amber-100 text-amber-800", released: "bg-emerald-100 text-emerald-800",
  refunded: "bg-stone-200 text-stone-700", split: "bg-violet-100 text-violet-800", resolved: "bg-emerald-100 text-emerald-800",
  approved: "bg-emerald-100 text-emerald-800", not_submitted: "bg-stone-100 text-stone-500", processed: "bg-emerald-100 text-emerald-800",
};
export function Pill({ s, children }: { s: string; children?: ReactNode }) {
  return <span className={`inline-flex items-center rounded-full px-2.5 py-0.5 text-xs font-bold whitespace-nowrap ${STATUS[s] ?? "bg-stone-100 text-stone-600"}`}>{children ?? s.replace("_", " ")}</span>;
}

export function Card({ title, action, children, className = "" }: { title?: ReactNode; action?: ReactNode; children: ReactNode; className?: string }) {
  return (
    <section className={`rounded-2xl bg-white border border-stone-200 ${className}`}>
      {title && <header className="flex items-center justify-between px-5 pt-4 pb-2"><h2 className="font-extrabold text-stone-900">{title}</h2>{action}</header>}
      <div className={title ? "px-5 pb-5" : "p-5"}>{children}</div>
    </section>
  );
}

export function Stat({ label, value, tone = "text-stone-900", hint }: { label: string; value: ReactNode; tone?: string; hint?: string }) {
  return (
    <div className="rounded-2xl bg-white border border-stone-200 p-5">
      <div className="text-sm font-semibold text-stone-500">{label}</div>
      <div className={`mt-1.5 text-3xl font-extrabold tabular-nums ${tone}`}>{value}</div>
      {hint && <div className="text-xs text-stone-400 mt-1">{hint}</div>}
    </div>
  );
}

export function Btn({ children, onClick, kind = "primary", disabled, small }: { children: ReactNode; onClick?: () => void; kind?: "primary" | "ghost" | "danger" | "ok" | "dark"; disabled?: boolean; small?: boolean }) {
  const k = { primary: "bg-brand hover:bg-brand-dark text-white", ghost: "bg-white border border-stone-300 hover:bg-stone-50 text-stone-800",
    danger: "bg-red-600 hover:bg-red-700 text-white", ok: "bg-emerald-600 hover:bg-emerald-700 text-white", dark: "bg-stone-900 hover:bg-black text-white" }[kind];
  return <button disabled={disabled} onClick={onClick} className={`${k} ${small ? "px-3 py-1.5 text-xs" : "px-4 py-2.5 text-sm"} rounded-xl font-bold transition disabled:opacity-40 disabled:cursor-not-allowed`}>{children}</button>;
}

export function Stars({ v }: { v: number }) {
  return <span className="font-bold tabular-nums"><span className="text-amber-500">★</span> {v ? v.toFixed(1) : "—"}</span>;
}

export function Drawer({ open, onClose, title, children }: { open: boolean; onClose: () => void; title: ReactNode; children: ReactNode }) {
  useEffect(() => {
    const h = (e: KeyboardEvent) => e.key === "Escape" && onClose();
    window.addEventListener("keydown", h);
    return () => window.removeEventListener("keydown", h);
  }, [onClose]);
  if (!open) return null;
  return (
    <div className="fixed inset-0 z-40 flex justify-end">
      <div className="absolute inset-0 bg-black/30" onClick={onClose} />
      <aside className="relative w-full max-w-3xl h-full overflow-y-auto bg-stone-50 shadow-2xl">
        <header className="sticky top-0 z-10 flex items-center justify-between bg-white border-b border-stone-200 px-6 h-16">
          <h2 className="font-extrabold text-lg">{title}</h2>
          <button onClick={onClose} className="size-9 rounded-lg hover:bg-stone-100 text-xl">×</button>
        </header>
        <div className="p-6 space-y-5">{children}</div>
      </aside>
    </div>
  );
}

/** Data hook with loading / error / reload — keeps pages tiny. */
export function useData<T>(load: () => Promise<T>, deps: unknown[] = []) {
  const [data, setData] = useState<T | null>(null);
  const [error, setError] = useState("");
  const [n, setN] = useState(0);
  useEffect(() => {
    let alive = true;
    load().then((d) => alive && (setData(d), setError(""))).catch((e) => alive && setError(e instanceof ApiError ? e.message : String(e)));
    return () => { alive = false; };
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [...deps, n]);
  return { data, error, reload: () => setN((x) => x + 1) };
}

export function Loading() {
  return <div className="h-40 grid place-items-center"><div className="size-8 rounded-full border-4 border-stone-200 border-t-brand animate-spin" /></div>;
}
export function ErrorBox({ msg }: { msg: string }) {
  return msg ? <div className="rounded-xl bg-red-50 text-red-700 px-4 py-3 text-sm font-medium">{msg}</div> : null;
}

export function PageHead({ title, sub, right }: { title: string; sub?: string; right?: ReactNode }) {
  return (
    <div className="flex items-end justify-between gap-4 mb-6">
      <div>
        <h1 className="text-2xl font-extrabold">{title}</h1>
        {sub && <p className="text-stone-500 text-sm mt-0.5">{sub}</p>}
      </div>
      {right}
    </div>
  );
}

export function Toast({ msg, onDone }: { msg: string; onDone: () => void }) {
  useEffect(() => { if (msg) { const t = setTimeout(onDone, 2600); return () => clearTimeout(t); } }, [msg, onDone]);
  return msg ? <div className="fixed bottom-6 left-1/2 -translate-x-1/2 z-50 rounded-xl bg-stone-900 text-white px-5 py-3 text-sm font-semibold shadow-lg">{msg}</div> : null;
}

/** In-page confirm / prompt (browser dialogs are blocked in many embedded contexts). */
type Ask = { message: string; input?: string; resolve: (v: string | null) => void };
let pushAsk: ((a: Ask) => void) | null = null;
export function ask(message: string, input?: string): Promise<string | null> {
  return new Promise((resolve) => pushAsk ? pushAsk({ message, input, resolve }) : resolve(input ?? ""));
}
export function AskHost() {
  const [a, setA] = useState<Ask | null>(null);
  const [v, setV] = useState("");
  useEffect(() => { pushAsk = (x) => { setV(x.input ?? ""); setA(x); }; return () => { pushAsk = null; }; }, []);
  if (!a) return null;
  const done = (val: string | null) => { a.resolve(val); setA(null); };
  return (
    <div className="fixed inset-0 z-50 grid place-items-center bg-black/40 p-4">
      <div className="w-full max-w-md rounded-2xl bg-white p-6 shadow-xl">
        <p className="font-semibold text-stone-900">{a.message}</p>
        {a.input !== undefined && <input autoFocus value={v} onChange={(e) => setV(e.target.value)} className="mt-3 w-full rounded-xl border border-stone-300 px-3 py-2.5" />}
        <div className="mt-5 flex justify-end gap-2">
          <Btn kind="ghost" onClick={() => done(null)}>Cancel</Btn>
          <Btn onClick={() => done(a.input !== undefined ? v : "ok")}>Confirm</Btn>
        </div>
      </div>
    </div>
  );
}
