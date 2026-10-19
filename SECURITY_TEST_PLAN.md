# Nirva security release checks

Run these checks in a staging Supabase project with synthetic patients and test
accounts. Do not use real patient data or production webhook secrets.

## Required test accounts

- One staff account
- One doctor account linked to a `doctors.user_id`
- One unlinked authenticated account
- One owner/admin account, if administration is enabled

## Role and direct-API checks

1. Sign in as staff. Confirm appointment and callback actions work.
2. As staff, attempt a direct `insert`, `update`, and `delete` against the
   `doctors` REST endpoint. Every write must fail; a directory `select` may
   succeed.
3. As staff, call `update-doctor-leave` and edit a leave record through the
   REST API. Both must fail.
4. Sign in as a doctor. Confirm only that doctor's leave/schedule can change.
   Confirm booking and callback mutations fail.
5. As the unlinked account, query patient, booking, callback, and audit REST
   endpoints. Every query must return no data or an authorization error.

## MFA checks

1. Sign in with an account that has no factor. It must go to `mfa.html`, not a
   clinic page.
2. Enroll a TOTP factor and verify a current code. Confirm the session reports
   `aal2`, then confirm clinic pages load.
3. Sign out and sign in again. Confirm the code challenge is required before
   the dashboard loads.
4. With any account, make a REST request using an AAL1 token before MFA
   enrollment/challenge. It must be rejected by the restrictive RLS policy.
5. Repeat the same request with an AAL2 token and confirm normal role policies
   still apply.
6. Call each dashboard mutation Edge Function (`staff-book-appointment`,
   `staff-complete-callback`, `staff-appointment-action`, and
   `update-doctor-leave`) with a valid AAL1 token. Each must return HTTP 403
   with the safe `mfa_required` code; repeat with an AAL2 token and confirm
   the normal role checks still apply.

## Webhook checks

1. Invoke every public webhook without `x-webhook-secret`; expect HTTP 401.
2. Invoke with an incorrect secret; expect HTTP 401 and no patient data in the
   response.
3. Send 61 valid requests to one function in one minute using a test secret;
   the final request must return HTTP 429.
4. Send a booking, cancellation, reschedule, or callback request without a
   stable `platform_call_id` or UUID `idempotency_key`; expect HTTP 400 and no
   state change.
5. Deliver the same post-call webhook twice with the same `call.id`; confirm
   only one `calls` record exists.
6. Deliver the same callback request twice with the same stable identifier;
   confirm only one callback record exists.
7. Send a post-call webhook without a provider call id; expect HTTP 400 and no
   call record.

## Browser deployment checks

After deploying a preview, run:

```sh
curl -sSI https://YOUR-PREVIEW.vercel.app/login.html
```

Verify `Content-Security-Policy`, `X-Content-Type-Options`, `Referrer-Policy`,
`Permissions-Policy`, and `X-Frame-Options` are present. Load every dashboard
page in a browser and check the console for CSP or Subresource Integrity
errors.

## Release evidence

Record the date, tester, environment, test-account aliases, and result for
each check. Treat a role bypass, MFA bypass for an enrolled account, duplicate
call record, missing header, or exposed sensitive error as a release blocker.
