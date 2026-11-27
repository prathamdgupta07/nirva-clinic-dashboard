-- ==== 20260929174826_allow_unrestricted_contact_numbers.sql
-- Phone identity accepts whatever local, landline, or international number
-- the caller provides. Do not add a country code or impose a length rule.
-- Keep the historical function name so existing RPCs and staff tools remain
-- compatible; the result is now a normalized contact string, not validated E.164.
create or replace function private.canonical_e164(p_value text)
returns text
language plpgsql
immutable
strict
set search_path = pg_catalog
as $$
declare
  v_phone text := regexp_replace(btrim(p_value), '[[:space:]().-]', '', 'g');
begin
  if v_phone = '' or v_phone !~ '[0-9]' then
    return null;
  end if;
  return v_phone;
end;
$$;

comment on function private.canonical_e164(text) is
  'Legacy name retained for compatibility. Normalizes caller-provided contact numbers without a country-code or digit-length requirement.';

;
-- ==== 20261006095057_auto_mark_overdue_bookings_no_show.sql
-- An unattended confirmed appointment is a no-show, never a cancellation.
-- The 24-hour grace period was chosen by the clinic during testing.
begin;

create or replace function private.mark_overdue_confirmed_bookings_no_show()
returns integer
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
declare
  v_count integer;
begin
  with changed as (
    update public.bookings
       set status = 'no_show',
           updated_at = now(),
           updated_by = null
     where status = 'confirmed'
       and appointment_time <= now() - interval '24 hours'
    returning id, appointment_time
  )
  insert into public.appointment_events
    (booking_id, action, source, details)
  select id, 'no_show', 'system',
    jsonb_build_object('automatic', true, 'reason', 'unattended_after_24_hours', 'appointment_time', appointment_time)
  from changed;

  get diagnostics v_count = row_count;
  return v_count;
end;
$$;

revoke all on function private.mark_overdue_confirmed_bookings_no_show() from public, anon, authenticated;
grant execute on function private.mark_overdue_confirmed_bookings_no_show() to service_role;

do $$
declare v_job_id bigint;
begin
  select jobid into v_job_id from cron.job where jobname = 'mark-overdue-bookings-no-show';
  if v_job_id is not null then perform cron.unschedule(v_job_id); end if;
  perform cron.schedule('mark-overdue-bookings-no-show', '5 * * * *',
    'select private.mark_overdue_confirmed_bookings_no_show()');
end;
$$;

commit;

;
-- ==== 20261006165235_add_staff_activity_audit.sql
begin;

-- Immutable, staff-visible operational history. This stores no patient name,
-- phone number, or clinical content: the detailed patient record remains in
-- its existing protected tables.
create table if not exists public.activity_audit (
  id uuid primary key default gen_random_uuid(),
  entity_type text not null check (entity_type in ('booking', 'callback_request', 'doctor_leave', 'doctor_schedule')),
  entity_id uuid,
  action text not null,
  actor_user_id uuid references auth.users(id) on delete set null,
  source_event_id uuid unique,
  details jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now()
);

create index if not exists activity_audit_created_at_idx
  on public.activity_audit (created_at desc);
create index if not exists activity_audit_actor_created_at_idx
  on public.activity_audit (actor_user_id, created_at desc)
  where actor_user_id is not null;

alter table public.activity_audit enable row level security;
drop policy if exists "clinic team can view activity audit" on public.activity_audit;
create policy "clinic team can view activity audit"
  on public.activity_audit for select to authenticated
  using (
    exists (
      select 1 from public.profiles p
      where p.id = (select auth.uid())
        and lower(p.role) in ('doctor', 'staff', 'receptionist', 'admin', 'owner')
    )
  );

-- Changes to leave need a distinct editor marker. The leave edit RPC below
-- supplies it only after an authenticated password check in the Edge Function.
alter table public.doctor_leave
  add column if not exists updated_by uuid references auth.users(id) on delete set null,
  add column if not exists updated_at timestamptz;

create or replace function private.write_activity_audit(
  p_entity_type text,
  p_entity_id uuid,
  p_action text,
  p_actor_user_id uuid,
  p_source_event_id uuid default null,
  p_details jsonb default '{}'::jsonb,
  p_created_at timestamptz default now()
)
returns void
language sql
security definer
set search_path = pg_catalog, public
as $$
  insert into public.activity_audit
    (entity_type, entity_id, action, actor_user_id, source_event_id, details, created_at)
  values
    (p_entity_type, p_entity_id, p_action, p_actor_user_id, p_source_event_id, coalesce(p_details, '{}'::jsonb), p_created_at)
  on conflict (source_event_id) do nothing
$$;

create or replace function private.audit_appointment_event()
returns trigger
language plpgsql
security definer
set search_path = pg_catalog, public, private
as $$
begin
  perform private.write_activity_audit(
    'booking', new.booking_id, 'booking_' || new.action, new.actor_user_id,
    new.id, jsonb_build_object('source', new.source), new.created_at
  );
  return new;
end;
$$;

create or replace function private.audit_callback_request()
returns trigger
language plpgsql
security definer
set search_path = pg_catalog, public, private
as $$
declare
  v_action text;
  v_actor uuid;
  v_when timestamptz;
begin
  if tg_op = 'INSERT' then
    v_action := 'callback_created';
    v_actor := new.created_by;
    v_when := new.created_at;
  elsif new.status = 'contacted' and old.status is distinct from new.status then
    v_action := 'callback_contacted';
    v_actor := new.contacted_by;
    v_when := coalesce(new.contacted_at, now());
  else
    return new;
  end if;
  perform private.write_activity_audit('callback_request', new.id, v_action, v_actor, null, '{}'::jsonb, v_when);
  return new;
end;
$$;

create or replace function private.audit_doctor_leave()
returns trigger
language plpgsql
security definer
set search_path = pg_catalog, public, private
as $$
begin
  if tg_op = 'INSERT' then
    perform private.write_activity_audit('doctor_leave', new.id, 'doctor_leave_created', new.created_by, null,
      jsonb_build_object('doctor_id', new.doctor_id), new.created_at);
  elsif new.leave_start_date is distinct from old.leave_start_date
     or new.leave_end_date is distinct from old.leave_end_date
     or new.reason is distinct from old.reason then
    perform private.write_activity_audit('doctor_leave', new.id, 'doctor_leave_updated', coalesce(new.updated_by, new.created_by), null,
      jsonb_build_object('doctor_id', new.doctor_id), coalesce(new.updated_at, now()));
  end if;
  return new;
end;
$$;

create or replace function private.audit_doctor_schedule_change()
returns trigger
language plpgsql
security definer
set search_path = pg_catalog, public, private
as $$
begin
  if tg_op = 'INSERT' then
    perform private.write_activity_audit('doctor_schedule', new.id, 'doctor_schedule_created', new.created_by, null,
      jsonb_build_object('doctor_id', new.doctor_id), new.created_at);
  end if;
  return new;
end;
$$;

drop trigger if exists activity_audit_appointment_events on public.appointment_events;
create trigger activity_audit_appointment_events
  after insert on public.appointment_events
  for each row execute function private.audit_appointment_event();
drop trigger if exists activity_audit_callback_requests on public.callback_requests;
create trigger activity_audit_callback_requests
  after insert or update on public.callback_requests
  for each row execute function private.audit_callback_request();
drop trigger if exists activity_audit_doctor_leave on public.doctor_leave;
create trigger activity_audit_doctor_leave
  after insert or update on public.doctor_leave
  for each row execute function private.audit_doctor_leave();
drop trigger if exists activity_audit_doctor_schedule_changes on public.doctor_schedule_changes;
create trigger activity_audit_doctor_schedule_changes
  after insert on public.doctor_schedule_changes
  for each row execute function private.audit_doctor_schedule_change();

-- Doctors may add their own leave, but existing leave records are no longer
-- directly editable from the browser. Edits use the protected RPC below.
drop policy if exists "doctor can manage own leave" on public.doctor_leave;
create policy "doctor can add own leave"
  on public.doctor_leave for insert to authenticated
  with check (private.is_own_doctor(doctor_id) and created_by = (select auth.uid()));
create policy "doctor can view own leave"
  on public.doctor_leave for select to authenticated
  using (private.is_own_doctor(doctor_id));

create or replace function public.update_doctor_leave_v1(
  p_actor_user_id uuid,
  p_leave_id uuid,
  p_leave_start_date date,
  p_leave_end_date date,
  p_reason text default null
)
returns jsonb
language plpgsql
security definer
set search_path = pg_catalog, public, private
as $$
declare
  v_leave public.doctor_leave%rowtype;
  v_role text;
begin
  if p_actor_user_id is null or p_leave_id is null or p_leave_start_date is null or p_leave_end_date is null or p_leave_start_date > p_leave_end_date then
    return jsonb_build_object('success', false, 'error_code', 'invalid_request');
  end if;
  select * into v_leave from public.doctor_leave where id = p_leave_id for update;
  if v_leave.id is null then return jsonb_build_object('success', false, 'error_code', 'leave_not_found'); end if;
  select lower(btrim(role)) into v_role from public.profiles where id = p_actor_user_id;
  if v_role = 'doctor' and not exists (
    select 1 from public.doctors d
    where d.id = v_leave.doctor_id and d.user_id = p_actor_user_id
  ) then
    return jsonb_build_object('success', false, 'error_code', 'unauthorized');
  end if;
  if coalesce(v_role, '') not in ('doctor', 'staff', 'receptionist', 'admin', 'owner') then
    return jsonb_build_object('success', false, 'error_code', 'unauthorized');
  end if;
  update public.doctor_leave
     set leave_start_date = p_leave_start_date,
         leave_end_date = p_leave_end_date,
         reason = nullif(btrim(coalesce(p_reason, '')), ''),
         updated_by = p_actor_user_id,
         updated_at = now()
   where id = p_leave_id;
  return jsonb_build_object('success', true, 'leave_id', p_leave_id);
end;
$$;

revoke all on function private.write_activity_audit(text,uuid,text,uuid,uuid,jsonb,timestamptz) from public, anon, authenticated;
revoke all on function private.audit_appointment_event() from public, anon, authenticated;
revoke all on function private.audit_callback_request() from public, anon, authenticated;
revoke all on function private.audit_doctor_leave() from public, anon, authenticated;
revoke all on function private.audit_doctor_schedule_change() from public, anon, authenticated;
revoke all on function public.update_doctor_leave_v1(uuid,uuid,date,date,text) from public, anon, authenticated;
grant execute on function public.update_doctor_leave_v1(uuid,uuid,date,date,text) to service_role;

-- Bring the existing booking history into the new activity feed exactly once.
insert into public.activity_audit (entity_type, entity_id, action, actor_user_id, source_event_id, details, created_at)
select 'booking', e.booking_id, 'booking_' || e.action, e.actor_user_id, e.id,
       jsonb_build_object('source', e.source), e.created_at
from public.appointment_events e
on conflict (source_event_id) do nothing;

insert into public.activity_audit (entity_type, entity_id, action, actor_user_id, details, created_at)
select 'doctor_leave', l.id, 'doctor_leave_created', l.created_by,
       jsonb_build_object('doctor_id', l.doctor_id), l.created_at
from public.doctor_leave l
where not exists (select 1 from public.activity_audit a where a.entity_type = 'doctor_leave' and a.entity_id = l.id and a.action = 'doctor_leave_created');

insert into public.activity_audit (entity_type, entity_id, action, actor_user_id, details, created_at)
select 'callback_request', c.id, 'callback_created', c.created_by, '{}'::jsonb, c.created_at
from public.callback_requests c
where not exists (select 1 from public.activity_audit a where a.entity_type = 'callback_request' and a.entity_id = c.id and a.action = 'callback_created');

insert into public.activity_audit (entity_type, entity_id, action, actor_user_id, details, created_at)
select 'callback_request', c.id, 'callback_contacted', c.contacted_by, '{}'::jsonb, c.contacted_at
from public.callback_requests c
where c.status = 'contacted' and c.contacted_at is not null
  and not exists (select 1 from public.activity_audit a where a.entity_type = 'callback_request' and a.entity_id = c.id and a.action = 'callback_contacted');

insert into public.activity_audit (entity_type, entity_id, action, actor_user_id, details, created_at)
select 'doctor_schedule', s.id, 'doctor_schedule_created', s.created_by,
       jsonb_build_object('doctor_id', s.doctor_id), s.created_at
from public.doctor_schedule_changes s
where not exists (select 1 from public.activity_audit a where a.entity_type = 'doctor_schedule' and a.entity_id = s.id and a.action = 'doctor_schedule_created');

commit;

;
-- ==== 20261006171059_add_activity_actor_name.sql
begin;

alter table public.activity_audit
  add column if not exists actor_name text;

create or replace function private.write_activity_audit(
  p_entity_type text,
  p_entity_id uuid,
  p_action text,
  p_actor_user_id uuid,
  p_source_event_id uuid default null,
  p_details jsonb default '{}'::jsonb,
  p_created_at timestamptz default now()
)
returns void
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
declare
  v_actor_name text;
begin
  if p_actor_user_id is not null then
    select nullif(btrim(full_name), '') into v_actor_name
    from public.profiles where id = p_actor_user_id;
  end if;
  insert into public.activity_audit
    (entity_type, entity_id, action, actor_user_id, actor_name, source_event_id, details, created_at)
  values
    (p_entity_type, p_entity_id, p_action, p_actor_user_id, v_actor_name, p_source_event_id, coalesce(p_details, '{}'::jsonb), p_created_at)
  on conflict (source_event_id) do nothing;
end;
$$;

update public.activity_audit a
set actor_name = nullif(btrim(p.full_name), '')
from public.profiles p
where p.id = a.actor_user_id and a.actor_name is null;

revoke all on function private.write_activity_audit(text,uuid,text,uuid,uuid,jsonb,timestamptz) from public, anon, authenticated;

commit;

;
-- ==== 20261006171237_use_email_when_audit_profile_missing.sql
begin;

create or replace function private.write_activity_audit(
  p_entity_type text,
  p_entity_id uuid,
  p_action text,
  p_actor_user_id uuid,
  p_source_event_id uuid default null,
  p_details jsonb default '{}'::jsonb,
  p_created_at timestamptz default now()
)
returns void
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
declare
  v_actor_name text;
begin
  if p_actor_user_id is not null then
    select coalesce(nullif(btrim(p.full_name), ''), u.email)
      into v_actor_name
      from auth.users u
      left join public.profiles p on p.id = u.id
     where u.id = p_actor_user_id;
  end if;
  insert into public.activity_audit
    (entity_type, entity_id, action, actor_user_id, actor_name, source_event_id, details, created_at)
  values
    (p_entity_type, p_entity_id, p_action, p_actor_user_id, v_actor_name, p_source_event_id, coalesce(p_details, '{}'::jsonb), p_created_at)
  on conflict (source_event_id) do nothing;
end;
$$;

update public.activity_audit a
set actor_name = u.email
from auth.users u
where u.id = a.actor_user_id and a.actor_name is null;

revoke all on function private.write_activity_audit(text,uuid,text,uuid,uuid,jsonb,timestamptz) from public, anon, authenticated;

commit;

;
-- ==== 20261006171859_restrict_leave_edits_to_own_doctor.sql
begin;

-- Only the doctor who owns the leave record may edit it. Staff, reception,
-- owners, and admins deliberately have no bypass for this patient-schedule
-- decision; they can continue to read leave and manage bookings/callbacks.
create or replace function public.update_doctor_leave_v1(
  p_actor_user_id uuid,
  p_leave_id uuid,
  p_leave_start_date date,
  p_leave_end_date date,
  p_reason text default null
)
returns jsonb
language plpgsql
security definer
set search_path = pg_catalog, public, private
as $$
declare
  v_leave public.doctor_leave%rowtype;
  v_role text;
begin
  if p_actor_user_id is null or p_leave_id is null or p_leave_start_date is null or p_leave_end_date is null or p_leave_start_date > p_leave_end_date then
    return jsonb_build_object('success', false, 'error_code', 'invalid_request');
  end if;
  select * into v_leave from public.doctor_leave where id = p_leave_id for update;
  if v_leave.id is null then
    return jsonb_build_object('success', false, 'error_code', 'leave_not_found');
  end if;
  select lower(btrim(role)) into v_role from public.profiles where id = p_actor_user_id;
  if v_role <> 'doctor' or not exists (
    select 1 from public.doctors d
    where d.id = v_leave.doctor_id and d.user_id = p_actor_user_id
  ) then
    return jsonb_build_object('success', false, 'error_code', 'unauthorized');
  end if;
  update public.doctor_leave
     set leave_start_date = p_leave_start_date,
         leave_end_date = p_leave_end_date,
         reason = nullif(btrim(coalesce(p_reason, '')), ''),
         updated_by = p_actor_user_id,
         updated_at = now()
   where id = p_leave_id;
  return jsonb_build_object('success', true, 'leave_id', p_leave_id);
end;
$$;

revoke all on function public.update_doctor_leave_v1(uuid,uuid,date,date,text) from public, anon, authenticated;
grant execute on function public.update_doctor_leave_v1(uuid,uuid,date,date,text) to service_role;

commit;

;
-- ==== 20261011175306_add_activity_patient_context.sql
begin;

-- Keep the patient and doctor context alongside booking events. This snapshot
-- makes the permanent Supabase history useful even if a booking is later
-- edited or removed. No phone number, email address, or clinical data is
-- placed in the audit record.
create or replace function private.audit_appointment_event()
returns trigger
language plpgsql
security definer
set search_path = pg_catalog, public, private
as $$
declare
  v_patient_name text;
  v_doctor_name text;
begin
  select coalesce(nullif(b.patient_name_snapshot, ''), p.name), d.name
    into v_patient_name, v_doctor_name
    from public.bookings b
    left join public.patients p on p.id = b.patient_id
    left join public.doctors d on d.id = b.doctor_id
   where b.id = new.booking_id;

  perform private.write_activity_audit(
    'booking', new.booking_id, 'booking_' || new.action, new.actor_user_id,
    new.id,
    jsonb_strip_nulls(jsonb_build_object(
      'source', new.source,
      'patient_name', v_patient_name,
      'doctor_name', v_doctor_name
    )),
    new.created_at
  );
  return new;
end;
$$;

-- Enrich historical booking events already retained in Supabase. The update is
-- deliberately limited to missing fields, so it never rewrites recorded audit
-- actions, actors, or timestamps.
update public.activity_audit a
   set details = a.details || jsonb_strip_nulls(jsonb_build_object(
     'patient_name', coalesce(nullif(b.patient_name_snapshot, ''), p.name),
     'doctor_name', d.name
   ))
  from public.bookings b
  left join public.patients p on p.id = b.patient_id
  left join public.doctors d on d.id = b.doctor_id
 where a.entity_type = 'booking'
   and a.entity_id = b.id
   and (a.details ->> 'patient_name' is null or a.details ->> 'doctor_name' is null);

revoke all on function private.audit_appointment_event() from public, anon, authenticated;

commit;

;
-- ==== 20261011175402_add_activity_actor_email.sql
begin;

alter table public.activity_audit
  add column if not exists actor_email text;

create or replace function private.write_activity_audit(
  p_entity_type text,
  p_entity_id uuid,
  p_action text,
  p_actor_user_id uuid,
  p_source_event_id uuid default null,
  p_details jsonb default '{}'::jsonb,
  p_created_at timestamptz default now()
)
returns void
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
declare
  v_actor_name text;
  v_actor_email text;
begin
  if p_actor_user_id is not null then
    select coalesce(nullif(btrim(p.full_name), ''), u.email), u.email
      into v_actor_name, v_actor_email
      from auth.users u
      left join public.profiles p on p.id = u.id
     where u.id = p_actor_user_id;
  end if;
  insert into public.activity_audit
    (entity_type, entity_id, action, actor_user_id, actor_name, actor_email, source_event_id, details, created_at)
  values
    (p_entity_type, p_entity_id, p_action, p_actor_user_id, v_actor_name, v_actor_email, p_source_event_id, coalesce(p_details, '{}'::jsonb), p_created_at)
  on conflict (source_event_id) do nothing;
end;
$$;

update public.activity_audit a
   set actor_email = u.email,
       actor_name = coalesce(nullif(btrim(a.actor_name), ''), nullif(btrim(p.full_name), ''), u.email)
  from auth.users u
  left join public.profiles p on p.id = u.id
 where u.id = a.actor_user_id
   and (a.actor_email is null or a.actor_name is null or btrim(a.actor_name) = '');

revoke all on function private.write_activity_audit(text,uuid,text,uuid,uuid,jsonb,timestamptz) from public, anon, authenticated;

commit;

;
-- ==== 20261019153857_security_hardening.sql
-- Nirva security hardening:
-- 1. Staff may read the doctor directory but may not create, edit, or delete
--    doctor accounts. Doctor administration belongs to an owner/admin workflow.
-- 2. Public webhook callers are capped per authenticated integration source.
-- 3. Every browser Data API request must carry an AAL2 session. Supabase Auth
--    endpoints remain available at AAL1 so a user can sign in, enroll TOTP,
--    complete the challenge, and then access clinic data.

begin;

drop policy if exists "staff can manage doctors" on public.doctors;

-- Recreate the existing read policies with an explicit database role. The
-- predicates remain the source of authorization; TO authenticated prevents
-- anonymous access from being accidentally included through PUBLIC.
drop policy if exists "staff can view doctors" on public.doctors;
create policy "staff can view doctors"
  on public.doctors for select to authenticated
  using (private.is_staff());

drop policy if exists "doctor can view doctors" on public.doctors;
create policy "doctor can view doctors"
  on public.doctors for select to authenticated
  using (private.is_any_doctor());

create table if not exists private.webhook_rate_limits (
  source text not null,
  window_started_at timestamptz not null,
  request_count integer not null default 0 check (request_count >= 0),
  primary key (source, window_started_at)
);

revoke all on table private.webhook_rate_limits from public, anon, authenticated;

-- Delivery receipts make provider retries of state-changing webhooks a safe
-- no-op. The id is a UUID derived from the provider's stable delivery/call id
-- (or a provider-supplied UUID), never a server-generated retry token.
create table if not exists private.webhook_deliveries (
  operation text not null,
  delivery_id uuid not null,
  received_at timestamptz not null default now(),
  primary key (operation, delivery_id)
);

revoke all on table private.webhook_deliveries from public, anon, authenticated;

-- Edesy/Vani may retry a completed webhook. A provider call id is therefore
-- unique for stored calls; NULL remains allowed for legacy rows that predate
-- this requirement.
create unique index if not exists calls_unique_provider_call_id
  on public.calls (call_id)
  where call_id is not null;

-- This RPC must live in the exposed public schema for the service-role Edge
-- Function client to call it. EXECUTE is explicitly revoked from every public
-- role below; only service_role may invoke it.
create or replace function public.consume_webhook_rate_limit(
  p_source text,
  p_limit integer default 60
)
returns boolean
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_window timestamptz := date_trunc('minute', now());
  v_count integer;
begin
  if p_source not in ('vani', 'sarvam', 'bolna') or p_limit < 1 or p_limit > 1000 then
    raise exception 'invalid webhook rate-limit parameters';
  end if;

  -- Keep this private operational table bounded without a public cleanup
  -- endpoint. At most one minute per hour performs the inexpensive retention
  -- pass; concurrent requests safely delete the same old rows.
  if extract(minute from now()) = 0 then
    delete from private.webhook_rate_limits
    where window_started_at < now() - interval '7 days';
    delete from private.webhook_deliveries
    where received_at < now() - interval '30 days';
  end if;

  insert into private.webhook_rate_limits (source, window_started_at, request_count)
  values (p_source, v_window, 1)
  on conflict (source, window_started_at) do update
    set request_count = private.webhook_rate_limits.request_count + 1
    where private.webhook_rate_limits.request_count < p_limit
  returning request_count into v_count;

  return v_count is not null and v_count <= p_limit;
end;
$$;

revoke all on function public.consume_webhook_rate_limit(text, integer) from public, anon, authenticated;
grant execute on function public.consume_webhook_rate_limit(text, integer) to service_role;

-- The delivery claim and callback insert share one database transaction. If
-- validation or insertion fails, Postgres rolls back the claim so a provider
-- retry is not incorrectly treated as already completed.
create or replace function public.create_callback_from_webhook(
  p_delivery_id uuid,
  p_caller_name text,
  p_phone_number text,
  p_doctor_id uuid,
  p_reason text default null
)
returns boolean
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_claimed boolean := false;
begin
  insert into private.webhook_deliveries (operation, delivery_id)
  values ('callback_request', p_delivery_id)
  on conflict do nothing
  returning true into v_claimed;

  if not coalesce(v_claimed, false) then
    return false;
  end if;

  insert into public.callback_requests (caller_name, doctor_id, phone_number, reason)
  values (p_caller_name, p_doctor_id, p_phone_number, nullif(p_reason, ''));

  return true;
end;
$$;

revoke all on function public.create_callback_from_webhook(uuid, text, text, uuid, text) from public, anon, authenticated;
grant execute on function public.create_callback_from_webhook(uuid, text, text, uuid, text) to service_role;

-- This restrictive policy applies in addition to each table's role/ownership
-- policies. It deliberately denies all AAL1 Data API access, including for
-- existing accounts, until the user completes TOTP enrollment and challenge.
-- The MFA page calls Supabase Auth only, not these protected tables.
do $$
declare
  v_table text;
begin
  foreach v_table in array array[
    'activity_audit', 'appointment_events', 'bookings', 'callback_requests',
    'calls', 'doctor_leave', 'doctor_schedule_changes', 'doctors',
    'login_history', 'patients', 'profiles'
  ] loop
    execute format('drop policy if exists %I on public.%I', 'enrolled users require mfa', v_table);
    execute format(
      'create policy %I on public.%I as restrictive for all to authenticated using ((select auth.jwt() ->> ''aal'') = ''aal2'') with check ((select auth.jwt() ->> ''aal'') = ''aal2'')',
      'enrolled users require mfa', v_table
    );
  end loop;
end;
$$;

commit;

;
-- ==== 20261020151216_remove_mfa_requirement.sql
-- Remove the app-level AAL2 requirement from clinic data tables.
-- Email/password authentication, existing row-level authorization policies,
-- and server-side role checks remain in place.
DO $$
DECLARE
  v_table text;
BEGIN
  FOREACH v_table IN ARRAY ARRAY[
    'activity_audit', 'appointment_events', 'bookings', 'callback_requests',
    'calls', 'doctor_leave', 'doctor_schedule_changes', 'doctors',
    'login_history', 'patients', 'profiles'
  ] LOOP
    EXECUTE format(
      'DROP POLICY IF EXISTS %I ON public.%I',
      'enrolled users require mfa',
      v_table
    );
  END LOOP;
END;
$$;

;
