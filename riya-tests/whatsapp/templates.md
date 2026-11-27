# WhatsApp message templates (create in Meta WhatsApp Manager)

For each one: **Category: Utility**, **Language: English**, type **Default**,
and the **Name** exactly as written (lowercase with underscores). Paste the body
exactly as written. Leave header, footer and buttons empty. Meta asks for a
sample value for every {{n}}; use the samples given.

Keep these strictly about the appointment. Any offer or promotion makes Meta
bill it as marketing (₹0.86 instead of ₹0.115) or reject it.

---

## 1. `appointment_confirmation`

```
Your appointment at {{1}} is confirmed.

Patient name: {{2}}
Phone: {{3}}
Doctor: {{4}}
Date: {{5}}
Time: {{6}}
Address: {{7}}

To reschedule or cancel, please call us on {{8}}.
```

Samples: 1 `Nirva Multi-Specialty Hospital` · 2 `Rahul Sharma` · 3 `+91 98765 43210` ·
4 `Dr. Ananya Sharma` · 5 `Sat, 28 Nov 2026` · 6 `11:30 AM` · 7 `12 MG Road, Andheri West, Mumbai` ·
8 `+91 22 4000 1234`

## 2. `appointment_rescheduled`

```
Your appointment at {{1}} has been moved to a new time.

Patient name: {{2}}
Phone: {{3}}
Doctor: {{4}}
New date: {{5}}
New time: {{6}}
Address: {{7}}

Your earlier slot on {{8}} has been released. For any change, please call us on {{9}}.
```

Samples: 1 `Nirva Multi-Specialty Hospital` · 2 `Rahul Sharma` · 3 `+91 98765 43210` ·
4 `Dr. Ananya Sharma` · 5 `Mon, 30 Nov 2026` · 6 `4:00 PM` · 7 `12 MG Road, Andheri West, Mumbai` ·
8 `Sat, 28 Nov 2026 at 11:30 AM` · 9 `+91 22 4000 1234`

## 3. `appointment_cancelled`

```
Your appointment at {{1}} has been cancelled.

Patient name: {{2}}
Doctor: {{3}}
Date: {{4}}
Time: {{5}}

To book a new appointment, please call us on {{6}}.
```

Samples: 1 `Nirva Multi-Specialty Hospital` · 2 `Rahul Sharma` · 3 `Dr. Ananya Sharma` ·
4 `Sat, 28 Nov 2026` · 5 `11:30 AM` · 6 `+91 22 4000 1234`

## 4. `appointment_reminder`

```
Reminder: your appointment at {{1}} is coming up soon.

Patient name: {{2}}
Phone: {{3}}
Doctor: {{4}}
Date: {{5}}
Time: {{6}}
Address: {{7}}

Please arrive 10 minutes early. To reschedule or cancel, please call us on {{8}}.
```

Samples: 1 `Nirva Multi-Specialty Hospital` · 2 `Rahul Sharma` · 3 `+91 98765 43210` ·
4 `Dr. Ananya Sharma` · 5 `Sat, 28 Nov 2026` · 6 `11:30 AM` · 7 `12 MG Road, Andheri West, Mumbai` ·
8 `+91 22 4000 1234`

The order of the {{n}} values must stay exactly as above: the database fills
them in this order (see `private.whatsapp_enqueue` in `supabase/08_whatsapp.sql`).
