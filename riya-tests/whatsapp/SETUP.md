# WhatsApp confirmations and reminders: setup

What patients get (Sarvam Riya and the staff dashboard):

| When | Message |
|---|---|
| Riya or staff books | Confirmation: name, phone, doctor, date, time, address |
| Riya or staff reschedules | New date and time, plus the old slot that was released |
| Riya or staff cancels | Cancellation notice with the number to rebook |
| 2 hours before the visit | Reminder (change the gap in step 5) |

Messages go through Meta's WhatsApp Cloud API directly (no monthly fee,
about ₹0.115 + GST per message). Nothing is sent until step 5 turns it on.

Files:
- `supabase/08_whatsapp.sql`: queue, trigger, reminder job, settings
- `functions/whatsapp-send/index.ts`: the Edge Function that talks to Meta
- `whatsapp/templates.md`: the 4 message templates to create in Meta

---

## 1. Meta app and free test number (about 15 minutes)

1. Go to https://developers.facebook.com/apps, then **Create app**, then
   choose **Other**, then **Business**. Name it `Nirva Riya`.
2. In the app, find **WhatsApp** and click **Set up**. Pick or create a
   Meta Business portfolio (your own name is fine for testing).
3. Open **WhatsApp > API Setup**. Meta gives you a **test phone number**.
   - Note the **Phone number ID** (a long number, not the phone number itself).
   - Under **To**, add your own mobile and confirm the code WhatsApp sends.
     The test number can message up to 5 numbers you add here.
   - Click **Generate access token**. This token works for 24 hours, which
     is fine for the first test. Step 6 makes a permanent one.

## 2. Create the 4 templates

Open **WhatsApp Manager > Message templates > Create template** and copy the
four templates from `whatsapp/templates.md` exactly (category **Utility**,
language **English**). Approval usually takes a few minutes to a day.

## 3. Put the Meta details in your secrets file (on your Mac)

Add two lines to `~/.riya-test-secrets/sarvam.env` (the same file the deploy
script already uses). Do not paste these into chat or commit them:

```
WHATSAPP_TOKEN=<the access token>
WHATSAPP_PHONE_NUMBER_ID=<the phone number ID>
```

Then deploy as usual: `./riya-tests/deploy-functions.sh sarvam`. This adds the
`whatsapp-send` function and uploads the two secrets.

## 4. Run the SQL

In the Sarvam project's Supabase **SQL editor**, paste and run
`supabase/08_whatsapp.sql`. It ends with `whatsapp ok`.

## 5. Turn it on

Run this in the SQL editor (change the address and phone to the real ones):

```sql
update private.whatsapp_settings set
  enabled        = true,
  function_url   = 'https://wsqwgomduqehbtdiawcw.supabase.co/functions/v1/whatsapp-send',
  clinic_name    = 'Nirva Multi-Specialty Hospital',
  clinic_address = 'Your clinic address here',
  clinic_phone   = '+91 XXXXX XXXXX',
  reminder_minutes_before = 120,   -- 120 = 2 hours before, 60 = 1 hour before
  updated_at     = now()
where id;
```

If the address is left empty, the message shows the clinic name instead.
Set `enabled = false` at any time to stop all messages.

**Test:** book an appointment with Riya using your own mobile number (one of
the 5 you added). The WhatsApp should arrive within a few seconds.

## 6. Before a real clinic

- **Permanent token:** Meta Business settings > Users > System users > Add
  (Admin), assign the WhatsApp app and account, Generate token with
  `whatsapp_business_messaging` and `whatsapp_business_management`, set it to
  never expire, and replace `WHATSAPP_TOKEN` in the secrets file.
- **Business verification** in Meta Business settings (GST, Udyam or shop licence).
- **A real number** that is not already on the normal WhatsApp or WhatsApp
  Business app. Ideally each clinic has its own number and display name.
- Recreate the 4 templates on that number's WhatsApp account.
- Riya should say "You'll get a WhatsApp confirmation" on calls (patient consent).

## Checking what was sent

```sql
select created_at, kind, to_e164, status, attempts, last_error
from private.whatsapp_messages order by created_at desc limit 50;
```

`sent` = Meta accepted it. `failed` = gave up (see `last_error`, for example a
template that is not approved yet). `skipped` = the visit was cancelled or
moved before the message went out. Failed sends retry up to 3 times
(after 2, 4 and 8 minutes).

To change the reminder gap later, run for example
`update private.whatsapp_settings set reminder_minutes_before = 60 where id;`
(60 = 1 hour before). A booking made less than that before the visit gets
only the confirmation, no separate reminder.
