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
   - *Post a Job* → tap a common job (e.g. **Compound wall**, or pick **Mason**; **See an example** shows a good post) → add 2 photos (several at once from the gallery) → type an instruction → **Record voice note** → check the transcript.
   - Next: the map opens at your location and the address fills itself → choose a date → see the **fair price** → **Post job**.
2. **Mason sees it and quotes**
   - Profile → switch to **Ramesh (mason)**. Your job is at the top of *Jobs* with your photos, 🔊 voice note and distance.
   - Open it: swipe the photos, play the voice note, tap *Show text*. Say or type a price → **Send price**.
   - **Fair Wage Shield:** the price box shows the fair range for this job. Type a very low price (e.g. ₹500) to see the minimum-wage warning.
3. **Customer accepts and pays**
   - Switch to **Priya** → open the job.
   - Ramesh's quote appears next to quotes from other sample workers. Each quote is labelled **Fair price**, **Below minimum wage** or **Higher than usual**. One quote is marked **Best match** with a one-line why (fair price, rating, distance, police verified) and some show **Can come today**. Sort by best match, price, rating or verified, open his profile, or chat. The job screen shows a 5-step progress header with "what happens next".
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

## Trust & worker features (3 minutes, each is independent)
1. **Start code** — Priya → *Bookings* → the paid carpenter job (Harpreet) shows a 4-digit **start code** card. Switch to **Harpreet** → *My work* → **I've arrived — check in** asks for the code. A wrong code says how many tries are left; 5 wrong tries lock it for 10 minutes. The right code starts the work. Without a network the check-in is saved as *waiting for code* and is verified when the code is entered online. For a contractor team, each worker has a new code every day on the roster.
2. **Share live trip** — Priya on a job where the worker is on the way → **Share live trip**. The text has the worker's name, trade, shield, a masked phone and a link `buildcrew.app/t/...`. The link works without logging in and stops once work starts.
3. **Police-verified shield** — Switch to **Gopal** → *Profile* → *Verification* → **Request police check**. In the demo it is approved after about 20 seconds. Customers see the shield next to the name and *Verified first* ranking in *Browse workers*. Admin → *Workers* → *Police check* is the review queue.
4. **Work warranty** — Priya → *Bookings* → *Past* → the finished plumber job *Kitchen sink* (Imran) shows **30-day guarantee** → **Problem came back** → reason and a photo. A free re-fix visit is created: no payment, no rating, the worker gets a start code too. One open re-fix at a time, 2 per job, none after the guarantee ends.
5. **Same-day pay** — Switch to **Imran** → *Earnings* → **Paid today**: *₹1,300 sent to your UPI im****@okaxis*. When Priya releases a payment, the money moves to UPI at once (*Processing*, then *Paid* after about 5 seconds) and the worker gets a notice. Without a UPI ID, an **Add UPI** nudge is shown. Manual withdraw still works.
6. **Skill level and streak** — Switch to **Ramesh** → *Profile*: **Skilled** level card with a progress bar to *Master* (jobs, rating, few re-fixes) and **4-week streak**. A higher level only widens the suggested price range; the legal minimum wage never changes.
10. **Hire again** — Priya → *Home* → **Your workers** → Imran → **Hire again**, or *Bookings* → *Past* → **Hire again**. *Post a job* opens filled in, with **Send to Imran first**. The job is only visible to him for 2 hours. Switch to **Ramesh** → *Jobs*: *Priya wants you again* with a **Direct request** badge at the top (Decline is on the card). After a decline or 2 hours it opens to everyone.

## Admin (optional)
BuildCrew Admin page: log in with `9000000001` / `123456`. It shows KYC approval, the police-verification queue, disputes with the voice note next to its transcript, the escrow ledger and the compliance export.

## Points to make
- **No payment until rated:** the server enforces it, not just the app.
- **Nobody starts before the money is held:** enforced on the server.
- **Fair Wage Shield (unique):** no other labour app warns when a quote is below the legal minimum wage — it protects workers and tells customers which prices are fair.
- **Workers:** voice-first, 12 languages, works offline, simple 4-tab app.
- **Privacy:** the exact address is shown only to the hired worker; voice notes are private; UPI IDs are encrypted.
- **Updates:** install inside the app.
