import { demoHandle } from "./demo";

// Admin token lives in sessionStorage (cleared when the tab closes) — never localStorage.
const BASE: string = import.meta.env.VITE_API_BASE_URL ?? "";
export const DEMO = !BASE || BASE === "demo";

export class ApiError extends Error {
  constructor(public code: string, message: string) { super(message); }
}

export function getToken() { return sessionStorage.getItem("bc_admin_token"); }
export function setToken(t: string | null) {
  if (t) sessionStorage.setItem("bc_admin_token", t); else sessionStorage.removeItem("bc_admin_token");
}

export async function api<T>(path: string, init: RequestInit = {}): Promise<T> {
  if (DEMO) {
    try {
      return (await demoHandle(path, init)) as T;
    } catch (e) {
      const x = e as Error & { code?: string };
      throw new ApiError(x.code ?? "unknown", x.message);
    }
  }
  const token = getToken();
  let res: Response;
  try {
    res = await fetch(BASE + path, {
      ...init,
      headers: { "Content-Type": "application/json", "Accept-Language": "en",
        ...(token ? { Authorization: `Bearer ${token}` } : {}), ...init.headers },
    });
  } catch {
    throw new ApiError("network", `Cannot reach the API at ${BASE}`);
  }
  if (res.headers.get("content-type")?.includes("text/csv")) return (await res.text()) as T;
  const body = await res.json().catch(() => ({}));
  if (!res.ok) {
    if (res.status === 401) setToken(null);
    throw new ApiError(body?.error?.code ?? "unknown", body?.error?.message ?? res.statusText);
  }
  return body as T;
}

export const post = <T,>(path: string, body?: unknown) => api<T>(path, { method: "POST", body: body ? JSON.stringify(body) : undefined });

export const inr = (n: number | null | undefined) => "₹" + (n ?? 0).toLocaleString("en-IN", { maximumFractionDigits: 0 });
export const fmtDate = (s?: string | null) => (s ? new Date(s).toLocaleDateString("en-IN", { day: "numeric", month: "short" }) : "—");
export const fmtTime = (s?: string | null) => (s ? new Date(s).toLocaleString("en-IN", { day: "numeric", month: "short", hour: "2-digit", minute: "2-digit" }) : "—");

// ---- shapes (subset of the API responses used by the UI)
export type Kpis = {
  active_jobs: number; workers_online: number; workers_total: number; bids_today: number; gmv_inr: number; in_escrow_inr: number;
  platform_revenue_inr: number; open_disputes: number; pending_bids: number; kyc_pending: number; jobs_by_status: Record<string, number>;
};
export type WorkerRow = {
  id: string; name: string; phone: string; trades: string[]; rating: number; rating_count: number; completed_jobs: number; badges: string[];
  kyc_level: number; city: string; suspended: boolean; strikes: number; online: boolean; aadhaar: string; pan: string; eshram: boolean; earned_inr: number;
  selfie?: string | null; doc_url?: string | null; doc_type?: string;
};
export type Audio = { url: string; duration_sec: number; size_kb: number; flagged: boolean; muted: boolean } | null;
export type WorkItem = { id: string; index: number; trade: string; photos: string[]; text: string | null; transcript: string | null; translated: boolean; original_language: string; audio: Audio };
export type Payment = { id: string; amount_inr: number; platform_fee_inr: number; worker_payout_inr: number; refund_inr: number; escrow_state: string; released_at: string | null; ref: string | null };
export type JobRow = { id: string; status: string; locality: string; address: string; start_date: string; created_at: string; trades: string[]; thumbnail: string | null; bid_count: number; customer: string; lat: number; lng: number };
