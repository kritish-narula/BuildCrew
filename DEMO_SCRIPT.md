# BuildCrew — 10-minute demo script

Works on the released APK in demo mode (no server needed). The OTP is always **123456**.

## 1. Worker: Ramesh, a mason who speaks Marathi (3 min)
1. Open the app and tap **मराठी** (tap 🔊 first to hear it). The whole app switches language immediately.
2. Tap **मला काम हवे आहे** (I want work), enter `9200000001`, then the OTP.
3. **Jobs tab.** The green card at the top is today's work, the compound wall in Hadapsar. Tap it, then **Check in**: take a selfie, and GPS is captured. Put the phone in airplane mode and check out: you'll see *"Saved. Will send when network returns."* and a pending chip. Turn the network back on and it syncs.
4. Back on **Jobs**, open the Kothrud job. Swipe the photos and play the **customer's voice note** (only one plays at a time). Tap **Show text** for the transcript.
5. Tap the mic and say *"पंद्रह सौ"* or *"1500"*. The price fills in. Tap **Send price**.
6. **My Bids** shows the amber "waiting" pill. After about 30 s the demo customer accepts and it turns green.
7. **Earnings** shows the big ₹ number. Tap a row to hear it read aloud, then withdraw to UPI.
8. **Profile** shows the rating breakdown, the *Trusted Mason* badge, past work and **My Labour Card**. Tap Share.

## 2. Customer: Priya, a homeowner (4 min)
1. Profile → Log out. Choose **हिन्दी**, then **मुझे कारीगर चाहिए** (I need workers), and enter `9100000001`.
2. **काम डालें** (Post a Job):
   - Pick *Plumber* and *Painter*. Two work cards appear.
   - On Plumber, add 2 photos and **record a voice note**. Agree to the consent line, watch the level meter, pause and resume, then attach.
   - The transcript appears; edit a word.
   - Pick the area and date. The **Fair price** screen shows the expected range. Post.
3. About 15 s later, pull to refresh: *"3 workers have quoted"*. Open the job, sort by rating, open a worker's profile and chat with them.
4. **Accept** a quote. The dialog shows the quote + ₹30 fee and explains escrow. The tracker moves to Assigned.
5. Open the Wakad/Aundh job → **Work is done**. The **rating screen** opens.
   - There is no way to pay the worker without rating; the server enforces this too.
   - Rate all 4 parameters and watch the overall update. Submit to see *Payment released*.

## 3. Admin (3 min): the BuildCrew Admin page, or http://localhost:5173
1. Log in with `9000000001` and `123456`. The **Dashboard** shows KPIs and the live job map.
2. **Workers & KYC**: approve Harpreet's Aadhaar (it moves him to L2). Filter the directory by *Plumber* or *4.5★+* and suspend a worker.
3. **Disputes**: open the Wakad dispute.
   - Play the customer's audio next to its transcript, then read the chat and attendance (one day was *away from site*).
   - Split 50%, tick *penalise*, and resolve. The ledger shows the payment as **split**.
4. **Payments** shows the escrow ledger and payout queue. **Compliance** has the eShram status and CSV export.

## What to point out
- **Mandatory rating before payment:** see `backend/app/domain/flows.py::release_payment` and its tests.
- **Offline-safe:** bids and attendance carry a `client_ref`, so replaying them never creates duplicates.
- **Privacy:**
  - Encrypted UPI and eShram IDs.
  - Aadhaar/PAN numbers are never stored.
  - Media links are signed and expire in 10 minutes.
  - Voice notes are visible only to the job's customer, eligible workers and admins.
- **In-app updates:** push to `main` and phones show "New update ready". The update installs over the existing app.
