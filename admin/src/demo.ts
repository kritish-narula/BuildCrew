// In-browser demo backend for the admin panel — mirrors backend/app/seed.py and the admin API
// responses, so the panel is fully clickable without a server. Mutations live in memory.
/* eslint-disable @typescript-eslint/no-explicit-any */
type J = Record<string, any>;

// Self-contained placeholder "photos" (inline SVG) so the demo works offline and in sandboxes.
const ph = (s: string) => {
  let h = 0;
  for (const c of s) h = (h * 31 + c.charCodeAt(0)) >>> 0;
  const hue = h % 360, hue2 = (hue + 40) % 360;
  const svg = `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 800 600"><defs><linearGradient id="g" x1="0" y1="0" x2="1" y2="1"><stop offset="0" stop-color="hsl(${hue},35%,72%)"/><stop offset="1" stop-color="hsl(${hue2},30%,48%)"/></linearGradient></defs><rect width="800" height="600" fill="url(#g)"/><g fill="rgba(255,255,255,.35)">${[0, 1, 2, 3].map((r) => [0, 1, 2, 3].map((c) => `<rect x="${c * 200 + (r % 2) * 100 - 80}" y="${r * 120 + 90}" width="180" height="100" rx="8"/>`).join("")).join("")}</g></svg>`;
  return "data:image/svg+xml;utf8," + encodeURIComponent(svg);
};
const AUDIO = "./sample.ogg";
const now = Date.now();
const ago = (h: number) => new Date(now - h * 3600_000).toISOString();
const LL: Record<string, [number, number]> = {
  Kothrud: [18.5074, 73.8077], Baner: [18.559, 73.7868], Hadapsar: [18.5089, 73.926], Wakad: [18.5986, 73.7604],
  "Viman Nagar": [18.5679, 73.9143], Aundh: [18.558, 73.8075], Kharadi: [18.5515, 73.9348], Shivajinagar: [18.5308, 73.8475],
};

const W = (id: string, name: string, phone: string, trades: string[], rating: number, count: number, kyc: number, city: string, extra: J = {}) => ({
  id, name, phone, trades, rating, rating_count: count, completed_jobs: count, badges: extra.badges ?? [], kyc_level: kyc, city: "Pune", locality: city,
  suspended: false, strikes: 0, online: extra.online ?? true, aadhaar: kyc === 2 ? "approved" : (extra.aadhaar ?? "not_submitted"),
  pan: kyc === 2 ? "approved" : "not_submitted", eshram: kyc === 2, earned_inr: extra.earned ?? count * 2600, selfie: ph(`selfie${id}`), verified: kyc >= 1,
  doc_url: extra.doc ?? null, doc_type: extra.doc ? "aadhaar" : undefined,
});

const db: J = {
  workers: [
    W("w1", "Ramesh Pawar", "9200000001", ["mason"], 4.6, 24, 2, "Kothrud", { badges: ["trusted_mason"] }),
    W("w2", "Sunil Yadav", "9200000002", ["mason", "helper"], 4.1, 9, 1, "Hadapsar"),
    W("w3", "Imran Shaikh", "9200000003", ["plumber"], 4.7, 31, 2, "Wakad", { badges: ["trusted_plumber"] }),
    W("w4", "Gopal Das", "9200000004", ["plumber", "helper"], 3.9, 6, 1, "Kharadi", { online: false }),
    W("w5", "Venkat Rao", "9200000005", ["electrician"], 4.8, 42, 2, "Baner", { badges: ["trusted_electrician", "fast_responder"] }),
    W("w6", "Ajay Kumar", "9200000006", ["electrician"], 4.2, 12, 1, "Viman Nagar", { online: false }),
    W("w7", "Harpreet Singh", "9200000007", ["carpenter"], 4.5, 19, 1, "Aundh", { aadhaar: "pending", doc: ph("kyc-doc-7"), earned: 44000 }),
    W("w8", "Mohan Jadhav", "9200000008", ["carpenter", "helper"], 0, 0, 0, "Shivajinagar"),
    W("w9", "Selvam K", "9200000009", ["painter"], 4.4, 15, 1, "Kothrud"),
    W("w10", "Deepak Gupta", "9200000010", ["painter", "helper"], 4.0, 8, 1, "Hadapsar", { online: false }),
  ],
  customers: { c1: "Priya Sharma", c2: "Anil Deshmukh", c3: "Neha Kulkarni" },
  jobs: [] as J[],
  disputes: [] as J[],
  payments: [] as J[],
  payouts: [
    { id: "po1", worker: "Ramesh Pawar", amount_inr: 2400, upi: "ra****@okaxis", status: "processed", at: ago(290), ref: "payout_mock_01" },
    { id: "po2", worker: "Imran Shaikh", amount_inr: 3800, upi: "im****@okaxis", status: "processed", at: ago(200), ref: "payout_mock_03" },
  ],
};

const item = (id: string, idx: number, trade: string, text: string, audio = false, transcript?: string, secs = 24): J => ({
  id, index: idx, trade, photos: [ph(`${id}a`), ph(`${id}b`)], text, translated: false, original_language: "hi",
  transcript: audio ? transcript ?? text : null, audio: audio ? { url: AUDIO, duration_sec: secs, size_kb: 18, flagged: false, muted: false } : null,
});
const job = (id: string, cust: string, loc: string, status: string, h: number, items: J[], bids: J[] = [], extra: J = {}): J => ({
  id, customer_id: cust, customer: db.customers[cust], status, locality: loc, city: "Pune", address: `Flat 302, ${loc}, Pune`, start_date: ago(-48).slice(0, 10),
  created_at: ago(h), trades: items.map((i) => i.trade), thumbnail: items[0].photos[0], lat: LL[loc][0] + 0.002, lng: LL[loc][1] - 0.001,
  work_items: items, bids, bid_count: bids.length, assignment: null, audit: [{ action: "job.posted", at: ago(h), meta: {} }], ...extra,
});
const wsum = (wid: string) => { const w = db.workers.find((x: J) => x.id === wid)!; return { id: w.id, name: w.name, trades: w.trades, rating: w.rating, rating_count: w.rating_count, completed_jobs: w.completed_jobs, badges: w.badges, kyc_level: w.kyc_level, verified: w.verified }; };
const bid = (id: string, wid: string, price: number, status = "pending", h = 3) => ({ id, price_inr: price, status, created_at: ago(h), worker: wsum(wid) });
const pay = (id: string, price: number, state: string, released: string | null = null): J => ({ id, amount_inr: price + 30, platform_fee_inr: 30, worker_payout_inr: price, refund_inr: 0, escrow_state: state, released_at: released, ref: `order_mock_${id}` });

db.jobs = [
  job("j1", "c1", "Kothrud", "open", 0.7, [item("j1w1", 1, "plumber", "बाथरूम का नल टपक रहा है, पाइप बदलना है।", true, "बाथरूम में नल से पानी टपक रहा है। पाइप बदलना पड़ेगा।"), item("j1w2", 2, "mason", "दीवार में सीलन, प्लास्टर ठीक करना है।")]),
  job("j2", "c3", "Baner", "bidding", 5, [item("j2w1", 1, "electrician", "Rewire the kitchen, add 4 new 16A sockets and a chimney point.", true, undefined, 37), item("j2w2", 2, "painter", "Paint the kitchen after wiring."), item("j2w3", 3, "helper", "Move appliances out and clean up.")],
    [bid("b1", "w5", 6800), bid("b2", "w6", 6200), bid("b3", "w9", 7400)]),
  job("j3", "c1", "Aundh", "assigned", 72, [item("j3w1", 1, "carpenter", "बेडरूम की अलमारी का दरवाज़ा टूट गया है।", true)], [bid("b4", "w7", 1800, "accepted", 70)]),
  job("j4", "c2", "Hadapsar", "in_progress", 144, [item("j4w1", 1, "mason", "Compound wall 40 ft, 5 ft high, 9-inch brick.", true, undefined, 52), item("j4w2", 2, "helper", "Material shifting, 3 days.")], [bid("b6", "w1", 14000, "accepted", 140)]),
  job("j5", "c3", "Kothrud", "completed", 216, [item("j5w1", 1, "painter", "Repaint living room and hall (~900 sq ft).")], [bid("b7", "w9", 9000, "accepted", 210)]),
  job("j6", "c2", "Wakad", "disputed", 288, [item("j6w1", 1, "plumber", "पूरे फ्लैट की पाइपलाइन बदलनी है, लीकेज टेस्ट के साथ।", true, "पूरे फ्लैट की पाइपलाइन बदलनी है और लीकेज टेस्ट करना है। मास्टर बाथरूम पर ध्यान दें।", 18), item("j6w2", 2, "mason", "Bathroom floor tiling, 60 sq ft."), item("j6w3", 3, "helper", "Debris removal.")],
    [bid("b8", "w3", 22000, "accepted", 280), bid("b9", "w4", 19800, "rejected", 279)]),
];
const assign = (j: J, wid: string, price: number, state: string, extra: J = {}) => {
  j.payment = pay(`p${j.id}`, price, state);
  j.assignment = { id: `a${j.id}`, worker: wsum(wid), price_inr: price, payment: j.payment, ratings: {}, attendance: [], started_at: extra.started ?? null, completed_at: extra.completed ?? null, ...extra };
  db.payments.push({ ...j.payment, job_id: j.id, locality: j.locality, worker: wsum(wid).name, customer: j.customer, job_status: j.status });
};
assign(db.jobs[2], "w7", 1800, "held");
assign(db.jobs[3], "w1", 14000, "held", { started: ago(48), attendance: [
  { in: ago(49), out: ago(41), offline: false, geofence_ok: true, selfie: ph("att1") },
  { in: ago(25), out: ago(17), offline: true, geofence_ok: true, selfie: ph("att2") }] });
assign(db.jobs[4], "w9", 9000, "held", { started: ago(190), completed: ago(24) });
assign(db.jobs[5], "w3", 22000, "held", { started: ago(240), completed: ago(96), attendance: [{ in: ago(240), out: ago(232), offline: false, geofence_ok: true, selfie: ph("att3") }, { in: ago(216), out: ago(214), offline: false, geofence_ok: false, selfie: ph("att4") }] });
for (const [i, w] of db.workers.filter((x: J) => x.rating_count > 0).entries()) {
  db.payments.push({ ...pay(`ph${i}`, 1800 + i * 450, "released", ago(400 + i * 30)), job_id: `hist${i}`, locality: "Kothrud", worker: w.name, customer: "Priya Sharma", job_status: "completed" });
}
db.disputes = [{
  id: "d1", status: "open", reason: "Leak returned in master bathroom 2 days after completion; worker not answering calls.", created_at: ago(48),
  raised_by: "Anil Deshmukh", job_id: "j6", locality: "Wakad", worker: "Imran Shaikh", customer: "Anil Deshmukh", amount_inr: 22030, resolution: null,
  chat: [
    { from: "customer", body: "Bathroom mein phir se leak ho raha hai.", at: ago(50) },
    { from: "worker", body: "Sir kal aata hoon check karne.", at: ago(49) },
    { from: "customer", body: "Aap aaye nahi. Main complaint kar raha hoon.", at: ago(26) },
  ],
}];

const kpis = () => {
  const active = db.jobs.filter((j: J) => ["open", "bidding", "assigned", "in_progress"].includes(j.status)).length;
  const by: Record<string, number> = {};
  db.jobs.forEach((j: J) => (by[j.status] = (by[j.status] ?? 0) + 1));
  const held = db.payments.filter((p: J) => p.escrow_state === "held");
  const rel = db.payments.filter((p: J) => ["released", "split"].includes(p.escrow_state));
  return {
    active_jobs: active, workers_online: db.workers.filter((w: J) => w.online && !w.suspended).length, workers_total: db.workers.length,
    bids_today: 4, gmv_inr: db.payments.reduce((s: number, p: J) => s + p.amount_inr, 0), in_escrow_inr: held.reduce((s: number, p: J) => s + p.amount_inr, 0),
    platform_revenue_inr: rel.reduce((s: number, p: J) => s + p.platform_fee_inr, 0), open_disputes: db.disputes.filter((d: J) => d.status !== "resolved").length,
    pending_bids: db.jobs.flatMap((j: J) => j.bids).filter((b: J) => b.status === "pending").length,
    kyc_pending: db.workers.filter((w: J) => w.aadhaar === "pending" || w.pan === "pending").length, jobs_by_status: by,
  };
};

const err = (code: string, message: string) => { const e = new Error(message) as Error & { code: string }; e.code = code; throw e; };

export async function demoHandle(path: string, init: RequestInit): Promise<unknown> {
  await new Promise((r) => setTimeout(r, 180));
  const method = init.method ?? "GET";
  const body = init.body ? JSON.parse(init.body as string) : {};
  const [p, qs] = path.split("?");
  const q = new URLSearchParams(qs ?? "");
  let m: RegExpMatchArray | null;

  if (p === "/auth/otp/request") return { resend_after_seconds: 30 };
  if (p === "/auth/otp/verify") {
    if (body.code !== "123456") err("err.otp_invalid", "Wrong code. Please check the SMS and try again.");
    return { token: "demo-admin", user: { role: body.phone === "9000000001" ? "admin" : "customer" } };
  }
  if (p === "/admin/kpis") return kpis();
  if (p === "/admin/map") {
    const act = db.jobs.filter((j: J) => j.status !== "completed" && j.status !== "cancelled");
    const by: Record<string, number> = {};
    act.forEach((j: J) => (by[j.locality] = (by[j.locality] ?? 0) + 1));
    return { pins: act.map((j: J) => ({ id: j.id, lat: j.lat, lng: j.lng, status: j.status, locality: j.locality, trades: j.trades })),
      by_locality: Object.entries(by).map(([locality, count]) => ({ locality, count })).sort((a, b) => b.count - a.count) };
  }
  if (p === "/admin/workers") {
    return db.workers.filter((w: J) => (!q.get("trade") || w.trades.includes(q.get("trade"))) && (!q.get("kyc") || String(w.kyc_level) === q.get("kyc"))
      && (!q.get("min_rating") || w.rating >= Number(q.get("min_rating"))) && (!q.get("q") || (w.name + w.phone).toLowerCase().includes(q.get("q")!.toLowerCase()))
      && (q.get("suspended") === null || String(w.suspended) === q.get("suspended")));
  }
  if (p === "/admin/kyc-queue") return db.workers.filter((w: J) => w.aadhaar === "pending" || w.pan === "pending");
  if ((m = p.match(/^\/admin\/workers\/(\w+)\/kyc$/))) {
    const w = db.workers.find((x: J) => x.id === m![1]);
    w.aadhaar = body.approve ? "approved" : "rejected";
    if (body.approve) w.kyc_level = 2;
    return { kyc_level: w.kyc_level };
  }
  if ((m = p.match(/^\/admin\/workers\/(\w+)\/suspend$/))) {
    const w = db.workers.find((x: J) => x.id === m![1]);
    w.suspended = body.suspend;
    if (!body.suspend) w.strikes = 0;
    return { suspended: w.suspended };
  }
  if (p === "/admin/jobs") return db.jobs.filter((j: J) => !q.get("status") || j.status === q.get("status"));
  if ((m = p.match(/^\/admin\/jobs\/(\w+)$/))) return db.jobs.find((j: J) => j.id === m![1]);
  if ((m = p.match(/^\/admin\/jobs\/(\w+)\/cancel$/))) {
    const j = db.jobs.find((x: J) => x.id === m![1]);
    j.status = "cancelled";
    if (j.payment?.escrow_state === "held") { j.payment.escrow_state = "refunded"; j.payment.refund_inr = j.payment.amount_inr; syncPay(j); }
    j.audit.push({ action: "job.cancelled", at: new Date().toISOString(), meta: { reason: "admin_intervention" } });
    return { status: "cancelled" };
  }
  if (p === "/admin/disputes") return db.disputes;
  if ((m = p.match(/^\/admin\/disputes\/(\w+)$/))) {
    const d = db.disputes.find((x: J) => x.id === m![1]);
    const j = db.jobs.find((x: J) => x.id === d.job_id);
    const w = db.workers.find((x: J) => x.name === d.worker);
    return { ...d, job: j, assignment: j.assignment,
      customer: { name: d.customer, phone: "9100000002", rating: 4.6, ratings: [{ overall: 5, comment: "Clear instructions, paid on time" }] },
      worker: { ...wsum(w.id), phone: w.phone, strikes: w.strikes, breakdown: { quality: 4.6, timeliness: 4.4, behaviour: 4.8, value_for_money: 4.5, overall: w.rating, count: w.rating_count } } };
  }
  if ((m = p.match(/^\/admin\/disputes\/(\w+)\/resolve$/))) {
    const d = db.disputes.find((x: J) => x.id === m![1]);
    const j = db.jobs.find((x: J) => x.id === d.job_id);
    const pct = body.worker_share_pct as number;
    const pmt = j.payment;
    if (pct >= 100) pmt.escrow_state = "released";
    else {
      const wp = Math.floor((pmt.worker_payout_inr * pct) / 100);
      pmt.refund_inr = pmt.amount_inr - wp - (pct ? pmt.platform_fee_inr : 0);
      pmt.worker_payout_inr = wp;
      pmt.escrow_state = pct ? "split" : "refunded";
    }
    pmt.released_at = new Date().toISOString();
    syncPay(j);
    if (body.penalise) { const w = db.workers.find((x: J) => x.name === d.worker); w.strikes += 1; if (w.strikes >= 3) w.suspended = true; }
    j.status = pct > 0 ? "completed" : "cancelled";
    d.status = "resolved";
    d.resolution = `worker_share=${pct}%; penalise=${body.penalise}; ${body.note ?? ""}`;
    return { status: "resolved", resolution: d.resolution };
  }
  if ((m = p.match(/^\/admin\/work-items\/(\w+)\/audio$/))) {
    for (const j of db.jobs) for (const wi of j.work_items) if (wi.id === m[1] && wi.audio) {
      if (body.flagged !== undefined) wi.audio.flagged = body.flagged;
      if (body.muted !== undefined) wi.audio.muted = body.muted;
      j.audit.push({ action: "audio.moderated", at: new Date().toISOString(), meta: { flagged: wi.audio.flagged, muted: wi.audio.muted } });
      return { flagged: wi.audio.flagged, muted: wi.audio.muted };
    }
    err("err.not_found", "Not found");
  }
  if (p === "/admin/payments") return db.payments;
  if (p === "/admin/payouts") {
    return { queue: db.workers.filter((w: J) => w.kyc_level >= 1 && w.rating_count > 0).slice(0, 4).map((w: J, i: number) => ({ worker: w.name, worker_id: w.id, available_inr: 1500 + i * 700, kyc_level: w.kyc_level })),
      history: db.payouts };
  }
  if (p === "/admin/compliance") {
    const rows = db.workers.map((w: J) => ({ card_id: `BC-${w.id.toUpperCase().padStart(8, "0")}`, name: w.name, trades: w.trades.join(","), city: "Pune", kyc_level: w.kyc_level,
      eshram_registered: w.eshram, aadhaar: w.aadhaar, pan: w.pan, earned_inr: w.earned_inr, jobs: w.completed_jobs }));
    return { rows, eshram_registered: rows.filter((r: J) => r.eshram_registered).length, total: rows.length };
  }
  if (p === "/admin/compliance.csv") {
    const { rows } = (await demoHandle("/admin/compliance", {})) as { rows: J[] };
    return [Object.keys(rows[0]).join(","), ...rows.map((r) => Object.values(r).join(","))].join("\n");
  }
  if (method) err("err.not_found", `Demo: no handler for ${method} ${p}`);
}

function syncPay(j: J) {
  const row = db.payments.find((x: J) => x.job_id === j.id);
  if (row) Object.assign(row, j.payment, { job_status: j.status });
  if (j.assignment) j.assignment.payment = j.payment;
}
