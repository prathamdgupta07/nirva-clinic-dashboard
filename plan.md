# Nirva Hospital Dashboard — Rebuild Plan

_Last updated: 2026-08-22_
_Status: v1 built and verified working — login, dashboard board, calendar,
patients (real data + call history), call performance stats, and
missed-call/callback tracking are all live and tested. Old Supabase project
(`yjpifecpuecbivsjcupw`) not yet deleted — do that once fully happy with
everything. VAPI→n8n calls pipeline still blocked on n8n payment (due
Sunday) — nothing else depends on it._

This is a **practice/demo project** (fictional "Nirva Hospital," not a real
client). Two purposes: (1) learn how a real full-stack app fits together —
auth, database, live UI, and (2) build something polished enough to demo to
a prospective clinic client, and to seed a future real product later.

---

## 1. Why we're rebuilding

The current Supabase project (`nirva-dashboard`, id `yjpifecpuecbivsjcupw`)
has one messy table (`bookings`, all-text columns, no relationships) that
was created by clicking around in the Supabase dashboard UI. There's no
record of *how* it was built — `list_migrations` returns empty even though
the table exists. Rather than patch that, we're starting over with a real
plan and tracked migrations, so the history of "how this was built" is
readable and repeatable.

**Decision:** delete the old Supabase project once the new one is confirmed
working, and create a brand-new project (new URL, new API keys — this means
every page below needs to be repointed, and SMTP has to be set up again from
scratch, correctly this time).

---

## 2. The core story (this drives every feature decision)

Nirva AI already sells AI voice agents (VAPI) and automations (n8n). The
real-world pain point this dashboard demonstrates solving:

> A patient calls the clinic. The AI voice agent answers and books the
> appointment automatically. Staff see it appear live on the dashboard —
> nobody had to touch a keyboard.

Every feature below is either **core** to telling this story, or
**supporting cast** that makes the demo feel like a real working system.
Anything that doesn't serve either gets deliberately cut from v1.

---

## 3. Feature scope (v1)

### 3a. Layout for today's schedule — board view, not a flat list

A plain table/list ("attendance sheet") works but reads like a spreadsheet,
not a dashboard — every row looks the same regardless of what state it's
in, and staff have to scan a status column to know what needs attention.

**Better option: a Kanban-style board**, with one column per status:

`Confirmed` → `Arrived` → `Completed`
(with `No-show` and `Cancelled` as a smaller side column, or filtered out
by default)

Each booking is a card (patient name, doctor, time, source tag). Staff
click a button on the card to move it forward (e.g. "Mark Arrived" moves
it from the Confirmed column to the Arrived column) — this maps directly
onto the unified `status` lifecycle above, so there's no mismatch between
the data model and the UI. It's also just more visual and demo-friendly:
a client looking at the dashboard can tell at a glance how the day is
going ("8 confirmed, 3 arrived, 1 no-show") without reading a table.

Trade-off: a board is a bit more UI work than a table (needs columns,
card components, move actions) — but not by much, and it reads far better
in a demo. Recommended for v1.

**Add-on: "next patient" highlight.** Within the Confirmed column, the
card with the soonest upcoming `appointment_time` is visually pinned/
highlighted. Front-desk staff mostly need to know one thing at a glance —
who's up next per doctor — this turns "a board full of cards" into "a
board that tells you what to do right now."

### Ready to build now
These don't depend on anything outside this project — data either already
exists (bookings) or is created directly by the dashboard.

| Feature | Notes |
|---|---|
| Staff login | Single login for now. No roles/permissions yet. |
| Today's schedule / agenda | Bookings filtered to today, sorted by time. |
| Live bookings feed | Updates without a manual page refresh (Supabase Realtime). **Better option:** don't just silently insert the new card — show a toast/banner ("New booking from AI Agent") when an `ai_agent`-sourced booking lands, optionally with a soft sound. This is the actual "wow moment" of the demo story; a card quietly appearing in a list is easy to miss, especially in a live demo with someone watching over your shoulder. |
| Source tag on bookings | **Better option:** a small colored badge/icon (robot icon = AI, person icon = staff) instead of plain text — far more scannable at a glance than reading each card, especially on a Kanban board (see 3a) where the whole point is glancing, not reading. |
| Manual "add booking" | Staff can add a booking by hand, so it's a real usable system, not an automation-only toy. **Upgrade:** the form takes a patient name + phone directly, and creates the `patients` row automatically if that patient doesn't already exist — instead of forcing staff to pick from the seeded patient list first. Roughly half of real front-desk calls are new patients, so requiring a separate "create patient" step before booking would be two steps for something that should be one. |
| Patient arrival check-in | Staff moves a booking through its lifecycle: `confirmed` → `arrived` → `completed`, or `confirmed` → `no_show` / `cancelled`. One unified status field (see schema below), not a separate attendance flag — see section 3a for the board-view UI this enables. |
| Doctor leave link | **Already built** — checked `settings.html`/`ai-receptionist.html`, both already have a "Report Doctor Leave" (Google Form) and "Doctor Schedule" (Google Sheet) link in the sidebar's bottom section. No new work needed; just carry the same sidebar into the new/rebuilt pages. |
| Doctors + patients | Seeded with a handful of fake records. Not manageable through the UI in v1. |

### Needs a data pipeline first (do NOT build the UI against fake data)
These depend on call records existing in Supabase, which isn't true yet —
VAPI calls aren't logged anywhere queryable right now.

| Feature | Blocked on |
|---|---|
| Call stats (counts + trend chart over time) | VAPI → n8n → Supabase `calls` table needs to be built first. |
| Callback list (missed calls + upcoming confirmation-call reminders) | Same — needs real call records to be meaningful. |

**Build order:** finish the "ready now" half completely first (steps 4–7
below), then wire up the VAPI→n8n→Supabase pipeline, then build stats/
callback UI on top of real data. Building charts against fake numbers now
just means re-doing the work later.

### Deliberately cut from v1 (revisit only if this becomes a real product)
- Doctor/patient management pages (add/edit through the UI)
- Staff roles/permissions (admin vs front-desk)
- Anything beyond one staff login

---

## 4. Database plan (Supabase)

### New project
- Create a brand-new Supabase project (keep the same region,
  `ap-northeast-1`, unless there's a reason to change).
- Every SQL change from here on is written as a numbered migration file
  and applied through the Supabase MCP tools — never by clicking around in
  the dashboard UI. This is the actual fix for "messy and hard to
  understand": a readable history of exactly how the database came to be.

### Tables (v1)

**`doctors`**
| column | type | notes |
|---|---|---|
| id | uuid, PK | |
| name | text | |
| specialty | text | |
| active | boolean | default true |

**`patients`**
| column | type | notes |
|---|---|---|
| id | uuid, PK | |
| name | text | |
| phone | text | |
| email | text | nullable |

**`bookings`**
| column | type | notes |
|---|---|---|
| id | uuid, PK | |
| patient_id | uuid, FK → patients | |
| doctor_id | uuid, FK → doctors | |
| appointment_time | timestamptz | real timestamp, not text — fixes the current table's biggest flaw |
| status | text | Single lifecycle field, check constraint limits it to: `confirmed`, `arrived`, `completed`, `no_show`, `cancelled`. Replaces the earlier two-field (status + attendance) design — one field means no invalid combinations like "cancelled but arrived." |
| source | text | `ai_agent` / `staff` — powers the source tag in the UI |
| created_at | timestamptz | default now() |

**`profiles`** (staff accounts)
| column | type | notes |
|---|---|---|
| id | uuid, PK | matches `auth.users.id` |
| full_name | text | |
| role | text | `staff` for now — single role, but the column exists so adding roles later doesn't require a schema change |

A trigger on `auth.users` insert automatically creates a matching `profiles`
row, so signup and staff-profile creation never fall out of sync.

**`calls`** (created later, once the VAPI pipeline is wired up — not in the
first migration)
| column | type | notes |
|---|---|---|
| id | uuid, PK | |
| vapi_call_id | text | VAPI's own call id, for dedup |
| patient_id | uuid, FK → patients, nullable | linked when the caller is matched to a known patient — decided now so `patients.html` can show real call history later without a schema redesign |
| phone_number | text | |
| outcome | text | `booked` / `missed` / `no_action` |
| duration_seconds | integer | |
| created_at | timestamptz | |

### Row Level Security (RLS)
- RLS is turned on for every table from the first migration — never left
  open "temporarily."
- Policy: only authenticated staff (rows that have a matching `profiles`
  entry) can read or write `bookings`, `patients`, `doctors`, `calls`.
- `profiles` itself: a user can read their own row; nobody can edit
  `role` except via a trusted server-side path (not exposed to the client).

### Auth / SMTP
- Email + password login (same UX as now).
- Fix Resend SMTP integration **before** wiring up forgot-password again,
  so we're not debugging the same `535 Authentication credentials invalid`
  error twice. (This was in progress before the rebuild decision — pick up
  with a fresh Resend API key.)

---

## 5. Frontend plan

Existing files in this folder that will be reused/updated, not rebuilt from
scratch:
- `login.html` — update to point at new Supabase project URL + anon key.
- `reset-password.html` — same update, re-test end-to-end once SMTP works.
- `dashboard-light.html` — becomes the base for the bookings feed + today's
  schedule view.
- `patients.html` — checked it: **not a harmless placeholder** — it shows
  fully invented data ("42 total" patients, fake names/phones/visit
  history). Since Nirva AI has zero real clients, fabricated-but-realistic
  patient records risk misrepresenting this as real usage if ever shown to
  a prospect. **Upgrade in v1**, not deferred: connect it to the real
  `patients` table (already in the v1 schema — needed for bookings
  anyway), so it shows "everyone the AI has actually spoken to," for real.
- `calls.html` — **merged into patients.html, not kept as a separate
  page.** Patients (one row per person) and calls (one row per phone call
  event) are different shapes of data, so a flat merge would either bury
  the patient list under repeated call rows or lose call-specific detail
  (duration, transcript). Instead: clicking into a patient on
  `patients.html` shows that patient's call history underneath, via the
  `calls.patient_id` link already added to the schema. The standalone
  `calls.html` page goes away. This part still can't show anything real
  until the VAPI→n8n→`calls` pipeline (phase 2) exists — until then, a
  patient's detail view just has an empty/"no calls yet" call history
  section, not invented data. Every page's sidebar currently has a "Calls"
  nav link pointing at `calls.html` — remove that link when rebuilding the
  shared sidebar, since the page it points to no longer exists on its own.
- `settings.html` + `ai-receptionist.html` — **merged into one page,
  renamed "Clinic Info."** Both were purely static/read-only (disabled
  inputs, inert toggles) and both do the same job — display information,
  not let anyone change anything. Since neither controls anything real
  (a "notifications" toggle doesn't touch VAPI's actual behavior, and
  neither will until VAPI is properly wired up as a separate later
  project), calling one of them "Settings" was misleading — the name
  implies you can configure something, and you can't. The merged page
  has two sections: **Clinic details** (name, phone, hours — read-only)
  and **What the AI can do** (Clara — books/reschedules/cancels, answers
  hours, escalates urgent calls — read-only). No fake interactivity
  anywhere on it; it's an honest reference page, not a control panel.
  Both old nav links ("Settings" and "AI Receptionist") collapse into one
  "Clinic Info" link in the sidebar.
- `calendar.html` (weekly/multi-day view) — **deliberately deferred, not
  part of v1.** The demo story is entirely about *today* ("a call comes in,
  it shows up live") — a multi-day calendar is a real feature a clinic
  would eventually want, but it doesn't serve the demo and is extra surface
  area to build/test right now. Left untouched; revisit only if this
  becomes a real product.

Steps:
1. Point every page at the new project's URL + anon key (single place to
   update this is worth doing — e.g. one shared `config.js` — instead of
   hardcoding it in every file, so the *next* migration doesn't repeat this
   pain).
2. Build today's schedule + live bookings feed against the new schema.
3. Build manual "add booking" form.
3a. Add Arrived / No-show buttons on today's schedule for attendance check-in.
4. Re-test login → forgot password → reset end-to-end.

---

## 6. Full build order

1. Create new Supabase project.
2. Write & apply migrations: `doctors`, `patients`, `bookings`, `profiles`
   + trigger, RLS policies on all of them.
3. Seed a handful of fake doctors + patients.
4. Fix Resend SMTP on the new project.
5. Update frontend pages to point at new project; re-test auth end-to-end.
6. Build today's schedule + live bookings feed + source tag.
7. Build manual add-booking form.
7a. Rewire `patients.html` to read real data from the `patients` table,
    removing the invented rows.
8. Confirm everything works, then delete the old Supabase project
   (`yjpifecpuecbivsjcupw`).
9. **Separate follow-up phase — on hold:** wire up VAPI → n8n → Supabase
    `calls` table, then build call stats + callback list on top of real
    data. **Blocked:** this needs an n8n plan tier that isn't paid for yet
    (confirmed 2026-08-22). Do not start this until that's sorted —
    nothing else in this plan depends on it.

---

## 7. Open questions / things to double check when we resume
- Confirm VAPI's API/webhook options for call logging (needed for step 10 —
  not blocking steps 1–9).
- Decide where `config.js` (Supabase URL + anon key) should live so it's
  not duplicated across every HTML file.
