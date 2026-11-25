# BuildCrew

Hyperlocal daily-wage construction labour marketplace for India. Customers post work with photos, text and voice notes; verified workers quote a price; escrowed payment is released only after the customer rates the worker.

| Part | Stack | Folder |
|---|---|---|
| Worker + Customer app | Flutter (Android-first), 12 languages | `mobile/` |
| API | FastAPI · PostgreSQL · SQLAlchemy · Alembic | `backend/` |
| Admin panel | React · Vite · TypeScript · Tailwind | `admin/` |

**Status:** all six phases are built: foundation, worker app, customer app, ratings + escrow, admin panel, and polish. English and Hindi are complete. The other 10 languages have onboarding and trade names translated, and the remaining strings fall back to English (run `python3 mobile/tool/check_l10n.py` to see what's left).

### What's in the app
| Worker (S1–S9) | Customer (C1–C6) | Admin (A1–A6) |
|---|---|---|
| Language select with 🔊 · phone OTP | Home: Post a Job / Browse workers / your jobs | KPIs + live job map |
| Jobs feed: photos, 🔊 badge with KB size, distance; audio never auto-plays | Posting flow: trades → work cards (1–5 photos + text + voice note with timer, level meter, pause, 2-min cap and a consent line) → review/edit the transcript → place & date → fair-price estimate | KYC queue (approve/reject) · worker directory with filters · suspend/reinstate |
| Job detail: Work 1/2/3 with gallery, translated text, big audio player (one plays at a time), "Show text" toggle | Bid comparison (sort by price/rating), worker profiles, chat | Jobs by status, bids, audit trail, cancel + refund stuck jobs |
| Price entry with large numerals **and voice** ("बोलिए, कितना पैसा चाहिए?") | Accept → escrow (quote + ₹30) → tracker: Assigned → In progress → Completed → Rated → Paid | Dispute evidence viewer: photos, text, **inline audio player + transcript side by side**, chat, attendance, ratings → release / refund / split / penalise; flag or mute audio |
| My Bids: amber waiting · green won · grey not selected | **Mandatory rating** (4 parameters, overall = average) releases payment | Escrow ledger, payout queue, revenue |
| Earnings: one big ₹ figure, withdraw to UPI, rows read aloud | Payments/receipts with escrow status | eShram/KYC compliance + CSV export |
| Profile: rating breakdown, badges, history, **My Labour Card** (shareable) | Report a problem (dispute) | |
| Attendance: selfie + GPS check-in/out, **works offline**, geofence flag | | |
| Offline queue: "Saved. Will send when network returns." + pending chip | | |
| Progressive KYC: L0 can bid → L1 (name, selfie, UPI) to get paid → L2 (Aadhaar/PAN photo) near ₹50k | | |
| Voice help ("mera paisa kab aayega?"), call + WhatsApp support, two-way ratings | | |

---

## 1. Install the Android app

1. On your phone, open **[Releases → latest](../../releases/latest)** and download **`BuildCrew.apk`** (use `BuildCrew-armv7.apk` on very old or low-end phones).
2. Open it and allow your browser to install apps when Android asks.

**Updates install inside the app.** When a new version is published, the app shows a **"New update ready"** banner and a notification. Tap **Update now** and the app downloads and checks the new version, then Android replaces it in place. Your login and data are kept, and there's nothing to uninstall.

Until the backend is deployed, the APK runs in **demo mode** (blue "Demo" chip). Every flow works on built-in sample data that is saved on the phone. The demo also plays the other side of the marketplace: workers quote about 15 seconds after you post a job, and a customer accepts a worker's quote about 30 seconds after it's sent. Log in with any seeded number below; the OTP is `123456`.

## 2. Run everything locally

```bash
cp .env.example .env
docker compose up --build
```

- API + interactive docs: http://localhost:8000/docs
- Admin panel: http://localhost:5173 (without `VITE_API_BASE_URL` it runs in **demo mode** on sample data in the browser)
- Dev SMS outbox (see the OTP texts in each language): http://localhost:8000/dev/sms-outbox

The database is migrated and seeded automatically on first start. Reset with `docker compose exec api python -m app.seed --reset`.

**Mobile against your local API:**
```bash
cd mobile
python3 tool/prepare_android.py          # generates + hardens android/
flutter run --dart-define=API_BASE_URL=http://10.0.2.2:8000   # Android emulator
```

### Demo logins (OTP is always `123456` in dev)

| Role | Phone | Notes |
|---|---|---|
| Admin | 9000000001 | web panel only |
| Customer | 9100000001 | Priya, homeowner, Hindi |
| Customer | 9100000002 | Anil, contractor, Marathi |
| Customer | 9100000003 | Neha, homeowner, English |
| Worker | 9200000001–9200000010 | mason, plumber, electrician, carpenter, painter (+helpers), mixed languages; 9200000008 is a brand-new KYC-L0 worker |

Seed: 6 jobs in Pune (open, bidding with 3 quotes, assigned, in-progress with offline-synced attendance, completed awaiting the mandatory rating, disputed with the customer's voice note as evidence) and price history for the Fair Price Estimate.

## 3. Config knobs (`.env`)

| Variable | Default | Meaning |
|---|---|---|
| `PLATFORM_FEE_FLAT_INR` | 30 | Flat fee per job, paid by the customer on top of the quote |
| `PLATFORM_TAKE_RATE_PCT` | 0 | Optional % taken from the worker's quote |
| `KYC_L2_EARNINGS_CAP_INR` | 50000 | Aadhaar/PAN is requested only as lifetime earnings approach this amount (nudges start at 80%) |
| `AUDIO_MAX_SECONDS` | 120 | Voice-note limit per work item (soft prompt at 60 s) |
| `SIGNED_URL_TTL_SECONDS` | 600 | Lifetime of media links |
| `OTP_REQUESTS_PER_HOUR` | 5 | Per-phone OTP limit |

## 4. Swapping in real providers

Every integration sits behind an interface in `backend/app/services/`. Switch one provider at a time:

| Service | Env switch | Keys |
|---|---|---|
| Payments: Razorpay Route escrow | `PAYMENT_PROVIDER=razorpay` | `RAZORPAY_KEY_ID`, `RAZORPAY_KEY_SECRET`, `RAZORPAY_WEBHOOK_SECRET` |
| Translation / STT / TTS: Bhashini | `TRANSLATION_PROVIDER=bhashini`, `SPEECH_PROVIDER=bhashini` | `BHASHINI_USER_ID`, `BHASHINI_API_KEY`, `BHASHINI_PIPELINE_ID` |
| Translation / STT / TTS: Google | `…=google` | `GOOGLE_API_KEY` |
| Maps | `MAPS_PROVIDER=google` | `GOOGLE_MAPS_API_KEY` |
| SMS (DLT-registered template) | `SMS_PROVIDER=msg91` | `MSG91_AUTH_KEY` |
| Storage (private bucket) | `STORAGE_PROVIDER=s3` | `S3_ENDPOINT`, `S3_BUCKET`, `S3_ACCESS_KEY`, `S3_SECRET_KEY` |

**Before going live with payments:** each worker needs a Razorpay Route linked account (or use RazorpayX payouts to their UPI ID). Test the whole flow in Razorpay test mode first.

**Realtime: Supabase Realtime over Firebase.** Our data already lives in Postgres. Supabase streams bid and chat changes straight from it, applies the same row-level access rules, and can be hosted in Mumbai for data residency. Locally, a mock sits behind the same `RealtimeService` interface.

## 5. Security baseline

**Payments**
- Amounts are always computed on the server from the accepted bid (`domain/fees.py`); the client never sends an amount.
- Razorpay checkout signatures and webhooks are HMAC-verified using constant-time comparison.
- Escrow follows a strict state machine (`domain/state.py`). Every transition writes an audit-log row in the same database transaction.
- Release is gated on the mandatory rating at the API level (Phase 4).
- Payment keys exist only in server environment variables, never in the app.

**Personal data**
- UPI IDs and eShram IDs are encrypted at rest (Fernet field encryption), so a database dump shows ciphertext.
- Aadhaar and PAN *numbers* are never stored, only their verification status.
- Phone numbers and UPI IDs are masked when shown to other users.
- Voice notes, photos and selfies sit under unguessable keys behind signed links that expire in 10 minutes. They're shown only to the job's customer, eligible workers and admins, and are never indexed.

**Login**
- OTPs are hashed, single-use and expire in 5 minutes. Each code allows 5 attempts, with rate limits per phone and per IP.
- Sessions use JWTs; the server decides each user's role.
- Admin accounts can't be created from the app.

**Server**
- Errors never leak stack traces or SQL.
- Security headers are set on every response.
- API docs are turned off outside dev.
- The server refuses to start in production with dev secrets.

**App**
- The session token is kept in Android Keystore-backed storage.
- Cloud backup is disabled.
- The network config is HTTPS-only.
- Release builds are obfuscated.
- Updates are SHA-256-verified, and Android only installs them if they're signed with the BuildCrew release key.

## 6. Releases & signing (maintainers)

`.github/workflows/android.yml` runs on every push to `main` that touches `mobile/`. It:

1. Generates the Android project.
2. Runs analysis and tests.
3. Builds per-CPU APKs signed with the permanent release key.
4. Checks the signing certificate.
5. Publishes a GitHub Release with `update.json`, which the in-app updater reads.

Required repository secrets: `KEYSTORE_BASE64` and `KEYSTORE_PASSWORD`. Optional repository variable: `API_BASE_URL`, the deployed backend; leave it empty for demo mode.

> ⚠️ **Never lose the release keystore.** Phones only accept an update signed with the same key. If the key is lost, every user has to uninstall and reinstall the app. Keep a backup in a password manager.

To publish an update: bump `version:` in `mobile/pubspec.yaml`, write the notes in `mobile/release_notes.json`, and push. To force a security update, set `minSupportedBuild` to the build number every phone must have at least. Users on older builds then get an update screen they can't dismiss.

## 7. Repo map

```
backend/app/
  models.py            all entities (money in paise)
  domain/state.py      job / bid / escrow state machines + audit
  domain/fees.py       ₹30 flat + optional take rate
  domain/policies.py   who may see private media
  services/            Payment · Translation · Speech · Storage · SMS · Maps · Realtime (mock + real)
  i18n/locales/        server strings (errors, SMS) for 12 languages
  seed.py              Pune demo data
mobile/lib/
  core/updater.dart    in-app self-update
  core/theme.dart      design tokens
  l10n/app_*.arb       12 languages (en + hi complete; others: onboarding + trades done)
admin/src/             admin console
```
