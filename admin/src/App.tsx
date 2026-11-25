import { useState, type FormEvent, type ReactNode } from "react";
import { Navigate, NavLink, Route, Routes, useNavigate } from "react-router-dom";
import { api, ApiError, DEMO, getToken, setToken } from "./api";
import Compliance from "./pages/Compliance";
import Dashboard from "./pages/Dashboard";
import Disputes from "./pages/Disputes";
import Jobs from "./pages/Jobs";
import Payments from "./pages/Payments";
import Workers from "./pages/Workers";
import { AskHost } from "./ui";

const NAV = [
  { to: "/", label: "Dashboard", icon: "▦" },
  { to: "/workers", label: "Workers & KYC", icon: "👷" },
  { to: "/jobs", label: "Jobs & Bids", icon: "🔨" },
  { to: "/disputes", label: "Disputes", icon: "⚖️" },
  { to: "/payments", label: "Payments & Payouts", icon: "₹" },
  { to: "/compliance", label: "Compliance", icon: "📋" },
];

export default function App() {
  const [authed, setAuthed] = useState(!!getToken());
  if (!authed) return <Login onDone={() => setAuthed(true)} />;
  return (
    <Shell onLogout={() => { setToken(null); setAuthed(false); }}>
      <Routes>
        <Route path="/" element={<Dashboard />} />
        <Route path="/workers" element={<Workers />} />
        <Route path="/jobs" element={<Jobs />} />
        <Route path="/disputes" element={<Disputes />} />
        <Route path="/payments" element={<Payments />} />
        <Route path="/compliance" element={<Compliance />} />
        <Route path="*" element={<Navigate to="/" />} />
      </Routes>
    </Shell>
  );
}

function Login({ onDone }: { onDone: () => void }) {
  const [phone, setPhone] = useState("");
  const [code, setCode] = useState("");
  const [step, setStep] = useState<"phone" | "otp">("phone");
  const [err, setErr] = useState("");
  const [busy, setBusy] = useState(false);
  const nav = useNavigate();

  async function submit(e: FormEvent) {
    e.preventDefault();
    setErr(""); setBusy(true);
    try {
      if (step === "phone") {
        await api("/auth/otp/request", { method: "POST", body: JSON.stringify({ phone, language_code: "en" }) });
        setStep("otp");
      } else {
        const r = await api<{ token: string; user: { role: string } }>("/auth/otp/verify", {
          method: "POST", body: JSON.stringify({ phone, code, language_code: "en" }),
        });
        // Role routing: only admins get into the panel. Server is the source of truth.
        if (r.user.role !== "admin") { setErr("This number is not an admin account."); setStep("phone"); return; }
        setToken(r.token); nav("/"); onDone();
      }
    } catch (e) {
      setErr(e instanceof ApiError ? e.message : "Something went wrong");
    } finally { setBusy(false); }
  }

  return (
    <div className="min-h-screen grid place-items-center p-6">
      <form onSubmit={submit} className="w-full max-w-sm bg-white rounded-3xl border border-stone-200 p-8 shadow-sm">
        <div className="flex items-center gap-3 mb-8">
          <div className="size-11 rounded-xl bg-brand grid place-items-center text-white font-black">BC</div>
          <div>
            <div className="font-extrabold text-lg leading-tight">BuildCrew Admin</div>
            <div className="text-sm text-stone-500">Operations console</div>
          </div>
        </div>
        {step === "phone" ? (
          <label className="block">
            <span className="text-sm font-semibold text-stone-600">Admin mobile number</span>
            <div className="mt-2 flex items-center rounded-xl border-2 border-stone-200 focus-within:border-brand px-3">
              <span className="text-stone-500 font-semibold">+91</span>
              <input autoFocus inputMode="numeric" maxLength={10} value={phone}
                onChange={(e) => setPhone(e.target.value.replace(/\D/g, ""))}
                className="flex-1 px-3 py-3 text-xl tracking-wider tabular-nums outline-none" placeholder="9000000001" />
            </div>
          </label>
        ) : (
          <label className="block">
            <span className="text-sm font-semibold text-stone-600">6-digit code sent to +91 {phone}</span>
            <input autoFocus inputMode="numeric" maxLength={6} value={code} autoComplete="one-time-code"
              onChange={(e) => setCode(e.target.value.replace(/\D/g, ""))}
              className="mt-2 w-full rounded-xl border-2 border-stone-200 focus:border-brand px-4 py-3 text-2xl tracking-[0.5em] tabular-nums outline-none" />
            <span className="mt-2 block text-xs text-stone-400">Dev / demo: code is always 123456</span>
          </label>
        )}
        {err && <p className="mt-4 text-sm text-red-600 font-medium">{err}</p>}
        <button disabled={busy || (step === "phone" ? phone.length !== 10 : code.length !== 6)}
          className="mt-6 w-full rounded-xl bg-brand hover:bg-brand-dark disabled:bg-stone-200 disabled:text-stone-400 text-white font-bold py-3.5 transition">
          {busy ? "…" : step === "phone" ? "Send code" : "Sign in"}
        </button>
      </form>
    </div>
  );
}

function Shell({ children, onLogout }: { children: ReactNode; onLogout: () => void }) {
  return (
    <div className="min-h-screen flex">
      <aside className="w-64 shrink-0 bg-stone-900 text-stone-300 flex flex-col sticky top-0 h-screen">
        <div className="flex items-center gap-3 px-5 h-16 border-b border-stone-800">
          <div className="size-8 rounded-lg bg-brand grid place-items-center text-white text-sm font-black">BC</div>
          <span className="font-extrabold text-white">BuildCrew</span>
          <span className="ml-auto text-[10px] font-bold uppercase tracking-wider text-stone-500">Admin</span>
        </div>
        <nav className="p-3 flex-1 space-y-1">
          {NAV.map((n) => (
            <NavLink key={n.to} to={n.to} end
              className={({ isActive }) => `flex items-center gap-3 rounded-lg px-3 py-2.5 text-sm font-semibold transition ${
                isActive ? "bg-stone-800 text-white" : "hover:bg-stone-800/60"}`}>
              <span className="w-5 text-center">{n.icon}</span>{n.label}
            </NavLink>
          ))}
        </nav>
        <button onClick={onLogout} className="m-3 rounded-lg px-3 py-2.5 text-left text-sm font-semibold hover:bg-stone-800">⎋ Log out</button>
      </aside>
      <main className="flex-1 p-8 overflow-auto">
        {DEMO && <div className="mb-4 rounded-xl bg-sky-50 text-sky-800 px-4 py-2 text-sm font-semibold">Demo mode — sample Pune data in your browser. Set VITE_API_BASE_URL to connect the real API.</div>}
        {children}
      </main>
      <AskHost />
    </div>
  );
}

