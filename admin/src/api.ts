// Admin token is kept in sessionStorage (cleared when the tab closes) — never localStorage.
const BASE = import.meta.env.VITE_API_BASE_URL ?? "http://localhost:8000";

export class ApiError extends Error {
  constructor(public code: string, message: string) { super(message); }
}

export function getToken() { return sessionStorage.getItem("bc_admin_token"); }
export function setToken(t: string | null) {
  if (t) sessionStorage.setItem("bc_admin_token", t); else sessionStorage.removeItem("bc_admin_token");
}

export async function api<T>(path: string, init: RequestInit = {}): Promise<T> {
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
  const body = await res.json().catch(() => ({}));
  if (!res.ok) {
    if (res.status === 401) setToken(null);
    throw new ApiError(body?.error?.code ?? "unknown", body?.error?.message ?? res.statusText);
  }
  return body as T;
}

export type Kpis = {
  active_jobs: number; workers_online: number; bids_today: number; gmv_inr: number;
  platform_revenue_inr: number; open_disputes: number; pending_bids: number;
};
