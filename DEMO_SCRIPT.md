# BuildCrew — presentation script (one phone, ~10 minutes)

Demo mode needs no server. All demo accounts share the data on the phone, so whatever the customer posts, the mason sees.

**Demo accounts** (OTP is always **123456**; on the login screen tap a name to fill the number):

| Role | Phone |
|---|---|
| Customer: Priya | 9100000001 |
| Mason: Ramesh | 9200000001 |
| Plumber: Imran | 9200000003 |
| Electrician: Venkat | 9200000005 |
| Painter: Selvam | 9200000009 |

**Switch accounts instantly:** Profile → *Demo: switch account*. **Start clean:** Profile → *Reset demo data*.

## The full story

1. **Customer posts work** (Priya)
   - *Post a Job* → tap **Mason** → add 2 photos → type an instruction → **Record voice note** → check the transcript.
   - Next: the map opens at your location and the address fills itself → choose a date → see the **fair price** → **Post job**.
2. **Mason sees it and quotes**
   - Profile → switch to **Ramesh (mason)**. Your job is at the top of *Jobs* with your photos, 🔊 voice note and distance.
   - Open it: swipe the photos, play the voice note, tap *Show text*. Say or type a price → **Send price**.
   - **Fair Wage Shield:** the price box shows the fair range for this job. Type a very low price (e.g. ₹500) to see the minimum-wage warning.
3. **Customer accepts and pays**
   - Switch to **Priya** → open the job.
   - Ramesh's quote appears next to quotes from other sample workers. Each quote is labelled **Fair price**, **Below minimum wage** or **Higher than usual**. Sort by price or rating, open his profile, or chat.
   - **Chat:** send Ramesh a message, switch to Ramesh — the chat icon at the top of *Jobs* shows an unread badge. Reply, switch back: it's in Priya's **Messages** tab.
   - Priya's **Bookings** tab lists every job as Open (getting quotes), Ongoing or Past.
   - **Accept** → **Continue to payment** → the payment page shows price + ₹30 fee → choose UPI → **Pay**.
   - The ✓ *Payment successful* screen shows the money held safely (escrow) and a transaction ID.
4. **Track the worker**
   - **Track Ramesh**: a live map shows him on the way, with distance and arrival time counting down.
   - The demo travels in 2 minutes. The ETA shown is the real-traffic estimate at 20 km/h.
5. **Work on site**
   - Switch to **Ramesh** → *My work* → **I've arrived — check in** (selfie + GPS). This works offline.
   - Then **Work finished**.
6. **Customer confirms and rates**
   - Switch to **Priya**: *"Ramesh says the work is finished"* → **Work is done**.
   - Rate **Quality, On time, Behaviour, Value for money** with stars. Overall is calculated automatically.
   - **Submit rating & pay worker** → *Payment released*.
7. **Receipt and earnings**
   - Priya → **View receipt**: price, fee, method, paid date, released date and transaction ID. Share it.
   - Switch to **Ramesh** → **Earnings**: the money is there → **Withdraw to UPI**. He can rate the customer too.

## Admin (optional)
BuildCrew Admin page: log in with `9000000001` / `123456`. It shows KYC approval, disputes with the voice note next to its transcript, the escrow ledger and the compliance export.

## Points to make
- **No payment until rated:** the server enforces it, not just the app.
- **Nobody starts before the money is held:** enforced on the server.
- **Fair Wage Shield (unique):** no other labour app warns when a quote is below the legal minimum wage — it protects workers and tells customers which prices are fair.
- **Workers:** voice-first, 12 languages, works offline, simple 4-tab app.
- **Privacy:** the exact address is shown only to the hired worker; voice notes are private; UPI IDs are encrypted.
- **Updates:** install inside the app.
