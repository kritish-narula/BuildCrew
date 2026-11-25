"""Demo seed (sample marketplace placed in Pune; prices come from domain/pricing.py, so any city works). Run: `python -m app.seed` (add `--reset` to wipe first).

Logins (dev OTP is always 123456):
  admin       9000000001
  customers   9100000001 (homeowner, Hindi) · 9100000002 (contractor, Marathi) · 9100000003 (homeowner, English)
  workers     9200000001 … 9200000024 (every trade has >= 2 workers; 21-24 are dedicated helpers/mazdoor)
  contractor  9100000002 (Anil Deshmukh, Deshmukh Constructions) has an active team site + an open team job
"""
import random
import sys
from datetime import date, datetime, timedelta, timezone

from sqlalchemy import select, text

from . import services
from .audit import audit
from .db import SessionLocal
from .domain import pricing
from .domain.fees import compute_fees
from .enums import (
    RatingDirection,
    AudioUploadState, BidStatus, CustomerType, DisputeStatus, DocStatus, EscrowState, JobStatus, Role,
    SupportChannel, Trade,
)
from .models import (
    Payout, Rating,
    Assignment, Attendance, Bid, ChatMessage, CustomerProfile, Dispute, Job, Payment, PriceHistory,
    SupportTicket, User, WorkerProfile, WorkItem, WorkItemPhoto,
)
from .services.infra import PUNE_LOCALITIES
from .services.language import SAMPLE_AUDIO

random.seed(42)
NOW = datetime.now(timezone.utc)
INR = 100  # paise


def photo(seed: str) -> str:  # neutral placeholder (KYC document sample only)
    return f"https://picsum.photos/seed/bc-{seed}/800/600"


def _u(pid: str) -> str:
    """Real work photos (Unsplash License, hot-linked from Unsplash's CDN)."""
    return f"https://images.unsplash.com/{pid}?w=800&q=65&auto=format&fit=crop"


TRADE_PHOTOS = {
    "plumber": [_u("photo-1697374981215-ce207e5ab8c0"), _u("photo-1749532125405-70950966b0e5"), _u("photo-1720889589894-497c4f4f569e")],
    "mason": [_u("photo-1704005445445-2747074be8ac"), _u("photo-1701850009190-2859ba2aeea6"), _u("photo-1673865641469-34498379d8af")],
    "electrician": [_u("photo-1751486289947-4f5f5961b3aa"), _u("photo-1621905251189-08b45d6a269e"), _u("photo-1635335874521-7987db781153")],
    "painter": [_u("photo-1717281234297-3def5ae3eee1"), _u("photo-1688372199140-cade7ae820fe"), _u("photo-1525909002-1b05e0c869d8")],
    "carpenter": [_u("photo-1779031242515-205111711b23"), _u("photo-1561297331-a9c00b9c2c44"), _u("photo-1544164560-adac3045edb2")],
    "helper": [_u("photo-1577199001468-44c049e7603f"), _u("photo-1632201147654-f6f54427e538"), _u("photo-1758210878793-a7bf2b089bc6")],
}


def trade_photo(trade: str, i: int) -> str:
    lst = TRADE_PHOTOS.get(trade, TRADE_PHOTOS["helper"])
    return lst[i % len(lst)]


WORKERS = [  # phone, name, lang, trades, locality, rating, count, kyc, badges, online
    ("9200000001", "Ramesh Pawar", "mr", ["mason"], "Kothrud", 4.6, 24, 2, ["trusted_mason"], True),
    ("9200000002", "Sunil Yadav", "hi", ["mason", "helper"], "Hadapsar", 4.1, 9, 1, [], True),
    ("9200000003", "Imran Shaikh", "hi", ["plumber"], "Wakad", 4.7, 31, 2, ["trusted_plumber"], True),
    ("9200000004", "Gopal Das", "bn", ["plumber", "helper"], "Kharadi", 3.9, 6, 1, [], False),
    ("9200000005", "Venkat Rao", "te", ["electrician"], "Baner", 4.8, 42, 2, ["trusted_electrician", "fast_responder"], True),
    ("9200000006", "Ajay Kumar", "hi", ["electrician"], "Viman Nagar", 4.2, 12, 1, [], False),
    ("9200000007", "Harpreet Singh", "pa", ["carpenter"], "Aundh", 4.5, 19, 1, [], True),
    ("9200000008", "Mohan Jadhav", "mr", ["carpenter", "helper"], "Shivajinagar", 0.0, 0, 0, [], True),  # new, KYC L0
    ("9200000009", "Selvam K", "ta", ["painter"], "Kothrud", 4.4, 15, 1, [], True),
    ("9200000010", "Deepak Gupta", "hi", ["painter", "helper"], "Hadapsar", 4.0, 8, 1, [], False),
    # More people from different states, so every trade has at least two workers and a real choice.
    ("9200000011", "Ramkumar Verma", "hi", ["mason"], "Kothrud", 4.3, 14, 1, [], True),               # Uttar Pradesh
    ("9200000012", "Basavaraj Hiremath", "kn", ["mason", "helper"], "Hadapsar", 4.0, 7, 1, [], True),  # Karnataka
    ("9200000013", "Murugan S", "ta", ["plumber"], "Aundh", 4.5, 22, 1, [], True),                      # Tamil Nadu
    ("9200000014", "Shamshad Alam", "hi", ["plumber"], "Baner", 4.2, 11, 1, [], True),                  # Bihar
    ("9200000015", "Jignesh Patel", "gu", ["electrician"], "Kothrud", 4.4, 17, 1, [], True),            # Gujarat
    ("9200000016", "Shaji Thomas", "ml", ["electrician", "helper"], "Wakad", 4.6, 26, 2, ["trusted_electrician"], True),  # Kerala
    ("9200000017", "Rajesh Suthar", "hi", ["carpenter"], "Hadapsar", 4.3, 16, 1, [], True),            # Rajasthan
    ("9200000018", "Bikash Nayak", "or", ["carpenter"], "Baner", 4.1, 10, 1, [], False),                # Odisha
    ("9200000019", "Dipak Das", "as", ["painter"], "Wakad", 4.2, 12, 1, [], True),                      # Assam
    ("9200000020", "Subhash Mondal", "bn", ["painter"], "Viman Nagar", 3.8, 6, 1, [], True),            # West Bengal
    ("9200000021", "Manoj Mahto", "hi", ["helper"], "Kothrud", 4.0, 9, 1, [], True),                    # Bihar
    ("9200000022", "Raju Munda", "hi", ["helper"], "Hadapsar", 4.2, 13, 1, [], True),                   # Jharkhand
    ("9200000023", "Santosh Kamble", "mr", ["helper"], "Aundh", 4.1, 8, 1, [], True),                   # Maharashtra
    ("9200000024", "Sunita Devi", "hi", ["helper"], "Kharadi", 4.4, 18, 1, [], True),                   # Madhya Pradesh
]
CUSTOMERS = [
    ("9100000001", "Priya Sharma", "hi", CustomerType.homeowner, None),
    ("9100000002", "Anil Deshmukh", "mr", CustomerType.contractor, "Deshmukh Constructions"),
    ("9100000003", "Neha Kulkarni", "en", CustomerType.homeowner, None),
]

# Each job: (customer idx, locality, status, days_ago, [work items: (trade, text, lang, has_audio)])
JOBS = [
    (0, "Kothrud", JobStatus.open, 0, [
        (Trade.plumber, "बाथरूम का नल टपक रहा है, पाइप बदलना है।", "hi", True),
        (Trade.mason, "दीवार में सीलन, प्लास्टर ठीक करना है।", "hi", False)]),
    (2, "Baner", JobStatus.bidding, 1, [
        (Trade.electrician, "Rewire the kitchen, add 4 new 16A sockets and a chimney point.", "en", True),
        (Trade.painter, "Paint the kitchen after wiring — 1 coat primer, 2 coats emulsion.", "en", False),
        (Trade.helper, "Move appliances out and clean up debris.", "en", False)]),
    (0, "Aundh", JobStatus.assigned, 3, [
        (Trade.carpenter, "बेडरूम की अलमारी का दरवाज़ा टूट गया है, नया कब्ज़ा और हैंडल।", "hi", True),
        (Trade.carpenter, "मॉड्यूलर किचन की दो दराज़ें ठीक करनी हैं।", "hi", False)]),
    (1, "Hadapsar", JobStatus.in_progress, 6, [
        (Trade.mason, "Compound wall 40 ft, 5 ft height, 9-inch brick. Multi-day work.", "mr", True),
        (Trade.helper, "Material shifting for the wall, 3 days.", "mr", False)]),
    (2, "Kothrud", JobStatus.completed, 9, [
        (Trade.painter, "Repaint living room and hall (approx. 900 sq ft), Asian Paints Apcolite.", "en", False),
        (Trade.painter, "Touch-up the main door grill with enamel.", "en", True)]),
    (1, "Wakad", JobStatus.disputed, 12, [
        (Trade.plumber, "पूरे फ्लैट की पाइपलाइन बदलनी है, लीकेज टेस्ट के साथ।", "hi", True),
        (Trade.mason, "Bathroom floor tiling after plumbing, 60 sq ft.", "en", False),
        (Trade.helper, "Debris removal.", "hi", False)]),
    # Open jobs so the carpenter and helper feeds are never empty (plumber/mason: job 1; electrician/painter: job 2).
    (2, "Wakad", JobStatus.open, 2, [
        (Trade.carpenter, "Need a new sliding wardrobe door fitted in the bedroom and the two kitchen drawer channels replaced.", "en", False)]),
    (0, "Baner", JobStatus.open, 3, [
        (Trade.helper, "Two helpers needed for one day to shift furniture and clear old tiles and debris from the flat.", "en", False)]),
]
# job index -> (days from today, hour, minute, slot): the schedule shown on every job card
SCHEDULES = {0: (1, 9, 30, "exact"), 1: (2, 8, 0, "morning"), 2: (-1, 12, 0, "afternoon"), 6: (1, 12, 0, "afternoon"),
             7: (2, 16, 0, "evening")}


def reset(db):
    db.execute(text("TRUNCATE users, otp_codes, worker_profiles, customer_profiles, jobs, work_items, "
                    "work_item_photos, bids, assignments, attendance, ratings, payments, disputes, "
                    "chat_messages, support_tickets, price_history, audit_logs CASCADE"))
    db.commit()


def run(do_reset: bool = False):
    db = SessionLocal()
    if do_reset:
        reset(db)
    if db.scalar(select(User).where(User.phone == "9000000001")):
        print("Seed already present (use --reset to recreate).")
        return

    store = services.storage()
    audio_bytes = SAMPLE_AUDIO.read_bytes()

    admin = User(phone="9000000001", role=Role.admin, name="Ops Admin", language_code="en", kyc_level=2)
    db.add(admin)

    customers = []
    for phone, name, lang, ctype, org in CUSTOMERS:
        u = User(phone=phone, role=Role.customer, name=name, language_code=lang, kyc_level=1)
        db.add(u)
        db.flush()
        db.add(CustomerProfile(user_id=u.id, type=ctype, org_name=org,
                               overall_rating=round(random.uniform(4.2, 4.9), 1), rating_count=random.randint(2, 9)))
        customers.append(u)

    workers = []
    for i, (phone, name, lang, trades, loc, rating, count, kyc, badges, online) in enumerate(WORKERS, 1):
        u = User(phone=phone, role=Role.worker, name=name, language_code=lang, kyc_level=kyc)
        db.add(u)
        db.flush()
        lat, lng = PUNE_LOCALITIES[loc]
        db.add(WorkerProfile(
            user_id=u.id, trades=trades, selfie_url=None,
            upi_id=f"{name.split()[0].lower()}{i}@okaxis" if kyc >= 1 else None,
            aadhaar_status=DocStatus.approved if kyc == 2 else (DocStatus.pending if i == 7 else DocStatus.not_submitted),
            pan_status=DocStatus.approved if kyc == 2 else DocStatus.not_submitted,
            eshram_id=f"UAN{100000000000 + i}" if kyc == 2 else None,
            badges=badges, overall_rating=rating, rating_count=count, completed_jobs=count,
            home_lat=lat + random.uniform(-0.01, 0.01), home_lng=lng + random.uniform(-0.01, 0.01),
            city="Pune", is_online=online,
            lifetime_earnings_paise=count * random.randint(1500, 4000) * INR))
        workers.append(u)
    db.flush()
    by_trade = {tr: [w for w, spec in zip(workers, WORKERS) if tr.value in spec[3]] for tr in Trade}

    jobs = []
    for j, (ci, loc, status, days, items) in enumerate(JOBS, 1):
        lat, lng = PUNE_LOCALITIES[loc]
        job = Job(customer_id=customers[ci].id, location_lat=lat, location_lng=lng,
                  address_text=f"Flat {random.randint(101, 904)}, {loc}, Pune", city="Pune", locality=loc,
                  start_date=date.today() + timedelta(days=2 - days), status=status,
                  created_at=NOW - timedelta(days=days, hours=random.randint(1, 8)))
        db.add(job)
        db.flush()
        for k, (trade, txt, lang, has_audio) in enumerate(items):
            wi = WorkItem(job_id=job.id, sort_order=k, trade=trade, text_description=txt, description_language=lang)
            if has_audio:
                key = store.put(audio_bytes, prefix="audio", ext="ogg", content_type="audio/ogg")
                wi.audio_url, wi.audio_duration_sec, wi.audio_size_bytes = key, random.choice([18, 24, 37, 52]), len(audio_bytes)
                wi.audio_upload_state = AudioUploadState.uploaded
                wi.transcript = services.speech().transcribe(audio_bytes, lang)
            db.add(wi)
            db.flush()
            for p in range(random.randint(1, 3)):
                db.add(WorkItemPhoto(work_item_id=wi.id, photo_url=trade_photo(trade.value, p + k), sort_order=p))
        if j - 1 in SCHEDULES:
            d_off, hh, mm, slot = SCHEDULES[j - 1]
            at = datetime.combine(date.today() + timedelta(days=d_off), datetime.min.time()).replace(hour=hh, minute=mm)
            job.scheduled_for = at.replace(tzinfo=timezone(timedelta(hours=5, minutes=30)))
            job.time_slot = slot
        audit(db, actor_id=job.customer_id, action="job.posted", entity="job", entity_id=job.id, seed=True)
        jobs.append(job)
    db.flush()

    def bids_for(job, trade, n, factors=None):
        """Realistic quotes: each worker prices the work items in their own trades (domain/pricing.py
        model for the job's city) within +/-12%; `factors` pins deliberate under/over-quotes."""
        out = []
        for i, w in enumerate(by_trade[trade][:n]):
            med = pricing.fair_range(job, w.worker_profile.trades)["median"]
            f = factors[i] if factors else random.uniform(0.88, 1.12)
            b = Bid(job_id=job.id, worker_id=w.id, quoted_price_paise=int(round(med * f / 50.0)) * 50 * INR,
                    status=BidStatus.pending, created_at=job.created_at + timedelta(hours=random.randint(1, 20)))
            db.add(b)
            out.append(b)
        db.flush()
        return out

    def assign(job, bid, escrow: EscrowState, started=None, completed=None):
        for other in db.scalars(select(Bid).where(Bid.job_id == job.id, Bid.id != bid.id)):
            other.status = BidStatus.rejected
        bid.status = BidStatus.accepted
        a = Assignment(job_id=job.id, worker_id=bid.worker_id, accepted_bid_id=bid.id, escrow_status=escrow,
                       started_at=started, completed_at=completed)
        db.add(a)
        db.flush()
        fees = compute_fees(bid.quoted_price_paise)
        db.add(Payment(assignment_id=a.id, amount_paise=fees.customer_pays_paise, platform_fee_paise=fees.platform_fee_paise,
                       worker_payout_paise=fees.worker_payout_paise, escrow_state=escrow,
                       razorpay_ref=f"order_mock_seed{str(a.id)[:8]}", method="upi",
                       paid_at=bid.created_at + timedelta(hours=1) if escrow != EscrowState.created else None))
        if started:  # worker travelled and is on site
            a.journey_started_at = started - timedelta(minutes=25)
            a.worker_lat, a.worker_lng, a.worker_loc_at = job.location_lat, job.location_lng, started
        audit(db, actor_id=job.customer_id, action="bid.accepted", entity="bid", entity_id=bid.id, seed=True)
        return a

    j1, j2, j3, j4, j5, j6, j7, j8 = jobs
    bids_for(j2, Trade.electrician, 2, [0.95, 0.35])  # 2nd quote is deliberately below minimum wage (Fair Wage Shield demo)
    bids_for(j2, Trade.painter, 1, [1.05])                       # → "3 workers have quoted"
    assign(j3, bids_for(j3, Trade.carpenter, 2)[0], EscrowState.held)
    a4 = assign(j4, bids_for(j4, Trade.mason, 2)[0], EscrowState.held, started=NOW - timedelta(days=2))
    assign(j5, bids_for(j5, Trade.painter, 2)[0], EscrowState.held,     # completed, rating PENDING
                started=NOW - timedelta(days=8), completed=NOW - timedelta(days=1))
    a6 = assign(j6, bids_for(j6, Trade.plumber, 2)[0], EscrowState.held,
                started=NOW - timedelta(days=10), completed=NOW - timedelta(days=4))

    # Attendance for the multi-day contractor job; day 2 was captured offline and synced later.
    lat, lng = PUNE_LOCALITIES["Hadapsar"]
    for d, offline in ((2, False), (1, True)):
        day = (NOW - timedelta(days=d)).replace(hour=3, minute=40)  # 09:10 IST
        db.add(Attendance(assignment_id=a4.id, checkin_at=day, checkin_lat=lat + 0.0002, checkin_lng=lng - 0.0001,
                          checkin_selfie_url=None, checkout_at=day + timedelta(hours=8, minutes=20),
                          offline_synced=offline))

    # Dispute with the customer's audio note as evidence.
    plumb_item = next(wi for wi in j6.work_items if wi.trade == Trade.plumber)
    db.add(Dispute(assignment_id=a6.id, raised_by=j6.customer_id,
                   reason="Leak returned in master bathroom 2 days after completion; worker not answering calls.",
                   evidence_refs=[plumb_item.audio_url, TRADE_PHOTOS["plumber"][0], TRADE_PHOTOS["plumber"][2]],
                   status=DisputeStatus.open, created_at=NOW - timedelta(days=2)))
    for who, body, h in ((j6.customer_id, "Bathroom mein phir se leak ho raha hai.", 50),
                         (a6.worker_id, "Sir kal aata hoon check karne.", 49),
                         (j6.customer_id, "Aap aaye nahi. Main complaint kar raha hoon.", 26)):
        db.add(ChatMessage(job_id=j6.id, sender_id=who,
                           recipient_id=a6.worker_id if who == j6.customer_id else j6.customer_id,
                           body=body, created_at=NOW - timedelta(hours=h)))
    db.add(SupportTicket(user_id=workers[1].id, channel=SupportChannel.voice, subject="Payment kab aayega?",
                         transcript="mera paisa kab aayega?"))

    # ---- Contractor team sites (Anil Deshmukh, 9100000002) ----
    anil = customers[1]
    by_phone = {w.phone: w for w in workers}
    IST = timezone(timedelta(hours=5, minutes=30))

    def team_job(loc, status, days_ago, lines, sched_off):
        lat, lng = PUNE_LOCALITIES[loc]
        tj = Job(customer_id=anil.id, location_lat=lat, location_lng=lng, address_text=f"Plot 14, {loc}, Pune", city="Pune",
                 locality=loc, start_date=date.today() + timedelta(days=sched_off), status=status, kind="team",
                 scheduled_for=datetime.combine(date.today() + timedelta(days=sched_off), datetime.min.time()).replace(hour=8, tzinfo=IST),
                 time_slot="morning", created_at=NOW - timedelta(days=days_ago, hours=3))
        db.add(tj)
        db.flush()
        items = []
        for k, (trade, headcount, days, wage, txt) in enumerate(lines):
            wi = WorkItem(job_id=tj.id, sort_order=k, trade=trade, text_description=txt, description_language="en",
                          headcount=headcount, days=days, daily_wage_paise=wage * INR)
            db.add(wi)
            db.flush()
            for p in range(2):
                db.add(WorkItemPhoto(work_item_id=wi.id, photo_url=trade_photo(trade.value, p + k), sort_order=p))
            items.append(wi)
        audit(db, actor_id=anil.id, action="job.posted", entity="job", entity_id=tj.id, seed=True, kind="team")
        return tj, items

    def team_bid(tj, wi, w, wage, accepted=False):
        b = Bid(job_id=tj.id, worker_id=w.id, work_item_id=wi.id, quoted_price_paise=wage * INR,
                status=BidStatus.accepted if accepted else BidStatus.pending, created_at=tj.created_at + timedelta(hours=2))
        db.add(b)
        db.flush()
        if not accepted:
            return b
        a = Assignment(job_id=tj.id, work_item_id=wi.id, days_planned=wi.days, worker_id=w.id, accepted_bid_id=b.id,
                       escrow_status=EscrowState.held, started_at=NOW - timedelta(days=2))
        db.add(a)
        db.flush()
        fees = compute_fees(wage * INR * wi.days)
        db.add(Payment(assignment_id=a.id, amount_paise=fees.customer_pays_paise, platform_fee_paise=fees.platform_fee_paise,
                       worker_payout_paise=fees.worker_payout_paise, escrow_state=EscrowState.held,
                       razorpay_ref=f"order_mock_team{str(a.id)[:8]}", method="upi", paid_at=NOW - timedelta(days=3)))
        a.journey_started_at = NOW - timedelta(days=2, minutes=25)
        return a

    # Site 1: in progress. 3 masons + 3 helpers wanted, 2 masons + 1 helper hired and on site, others applied.
    t1, (t1m, t1h) = team_job("Hadapsar", JobStatus.in_progress, 4, [
        (Trade.mason, 3, 5, 950, "Boundary wall and plaster for a new plot, 3 masons for 5 days. Bring your own tools; lunch provided."),
        (Trade.helper, 3, 5, 800, "Three helpers to carry bricks, mix cement and clean the site for 5 days at the same plot."),
    ], -2)
    hired = [team_bid(t1, t1m, by_phone["9200000001"], 950, True), team_bid(t1, t1m, by_phone["9200000011"], 950, True),
             team_bid(t1, t1h, by_phone["9200000021"], 800, True)]
    team_bid(t1, t1m, by_phone["9200000002"], 1000)
    team_bid(t1, t1h, by_phone["9200000022"], 800)
    lat, lng = PUNE_LOCALITIES["Hadapsar"]
    for ai, a in enumerate(hired):
        for d in (2, 1, 0) if ai != 2 else (2, 1):
            day = (NOW - timedelta(days=d)).astimezone(IST).replace(hour=9, minute=5 + ai * 6, second=0, microsecond=0)
            db.add(Attendance(assignment_id=a.id, checkin_at=day, checkin_lat=lat + 0.0002, checkin_lng=lng - 0.0001,
                              checkout_at=None if d == 0 else day + timedelta(hours=8, minutes=15), offline_synced=(ai == 1 and d == 1)))
    # Site 2: open for applications (painters + carpenters), nobody hired yet.
    t2, (t2p, t2c) = team_job("Baner", JobStatus.bidding, 1, [
        (Trade.painter, 2, 4, 900, "Two painters for putty, primer and two coats on a 3 BHK flat, 4 days. Material is on site."),
        (Trade.carpenter, 2, 3, 1300, "Two carpenters for modular wardrobes and door frames in a new flat, 3 days."),
    ], 2)
    team_bid(t2, t2p, by_phone["9200000009"], 900)
    team_bid(t2, t2p, by_phone["9200000019"], 950)
    team_bid(t2, t2c, by_phone["9200000007"], 1300)
    db.flush()

    # Past work for every experienced worker: completed, rated, paid. Feeds profile history,
    # parameter-wise ratings, earnings history and the badge logic.
    comments = ["Very neat work", "Came on time, finished fast", "Good behaviour, fair price",
                 "Bahut accha kaam", "Clean finish, will hire again", None]
    for w, spec in zip(workers, WORKERS):
        n = min(spec[6], 4)
        for h in range(n):
            trade = Trade(spec[3][0])
            cust = customers[h % 3]
            loc = random.choice(list(PUNE_LOCALITIES))
            lat, lng = PUNE_LOCALITIES[loc]
            done = NOW - timedelta(days=15 + h * 9)
            hj = Job(customer_id=cust.id, location_lat=lat, location_lng=lng, address_text=f"{loc}, Pune", city="Pune",
                     locality=loc, start_date=(done - timedelta(days=2)).date(), status=JobStatus.completed,
                     created_at=done - timedelta(days=4))
            db.add(hj)
            db.flush()
            sample = random.choice(pricing.SAMPLE_JOBS[trade.value])
            hwi = WorkItem(job_id=hj.id, sort_order=0, trade=trade, text_description=sample, description_language="en")
            db.add(hwi)
            db.flush()
            db.add(WorkItemPhoto(work_item_id=hwi.id, photo_url=trade_photo(trade.value, h), sort_order=0))
            price = int(round(pricing.estimate_item(trade.value, sample, "Pune")["median_inr"] * random.uniform(0.88, 1.12) / 50.0)) * 50 * INR
            hb = Bid(job_id=hj.id, worker_id=w.id, quoted_price_paise=price, status=BidStatus.accepted,
                     created_at=hj.created_at + timedelta(hours=2))
            db.add(hb)
            db.flush()
            ha = Assignment(job_id=hj.id, worker_id=w.id, accepted_bid_id=hb.id, escrow_status=EscrowState.released,
                            started_at=done - timedelta(days=2), completed_at=done)
            db.add(ha)
            db.flush()
            fees = compute_fees(price)
            db.add(Payment(assignment_id=ha.id, amount_paise=fees.customer_pays_paise, platform_fee_paise=fees.platform_fee_paise,
                           worker_payout_paise=fees.worker_payout_paise, escrow_state=EscrowState.released,
                           razorpay_ref=f"order_mock_hist{h}{w.phone[-2:]}", released_at=done + timedelta(hours=3)))
            base = spec[5]
            q, t_, b, v = (max(1, min(5, round(base + random.uniform(-0.6, 0.5)))) for _ in range(4))
            db.add(Rating(assignment_id=ha.id, direction=RatingDirection.customer_to_worker, rater_id=cust.id, ratee_id=w.id,
                          quality=q, timeliness=t_, behaviour=b, value_for_money=v, overall=round((q + t_ + b + v) / 4, 2),
                          comment=random.choice(comments), created_at=done + timedelta(hours=3)))
        if n >= 2:  # some already withdrawn to UPI
            db.add(Payout(worker_id=w.id, amount_paise=random.randint(10, 25) * 100 * INR,
                          upi_masked=f"{spec[1][:2].lower()}****@okaxis", provider_ref=f"payout_mock_seed{w.phone[-2:]}",
                          created_at=NOW - timedelta(days=12)))
    # One worker waiting for Level-2 KYC review (admin KYC queue).
    hp = db.get(WorkerProfile, workers[6].id)
    hp.kyc_doc_type, hp.kyc_doc_key = "aadhaar", photo("kyc-doc-7")
    hp.lifetime_earnings_paise = 44_000 * INR  # near the ₹50k cap → app nudges for Level 2

    # Historical prices for the Fair Price Estimate (C2 step 4): the pricing model +/- noise, for the sample
    # Pune marketplace and a few other cities so tier-2 / other-metro estimates have local history too.
    city_localities = {"Pune": list(PUNE_LOCALITIES), "Delhi": ["Dwarka", "Rohini"], "Bengaluru": ["Whitefield", "Indiranagar"],
                       "Jalandhar": ["Model Town", "Adarsh Nagar"], "Jaipur": ["Malviya Nagar", "Vaishali Nagar"],
                       "Chandigarh": ["Sector 22", "Sector 35"]}
    for city, locs in city_localities.items():
        for tr in Trade:
            for loc in locs:
                for _ in range(random.randint(6, 10)):
                    sample = random.choice(pricing.SAMPLE_JOBS[tr.value])
                    med = pricing.estimate_item(tr.value, sample, city)["median_inr"]
                    db.add(PriceHistory(trade=tr, city=city, locality=loc, work_summary=sample[:200],
                                        price_paise=int(round(med * random.uniform(0.8, 1.2) / 50.0)) * 50 * INR,
                                        completed_on=date.today() - timedelta(days=random.randint(5, 180))))
    db.commit()
    print(f"Seeded: 1 admin, {len(customers)} customers, {len(workers)} workers, {len(jobs)} jobs.")


if __name__ == "__main__":
    run(do_reset="--reset" in sys.argv)
