
-- ######## 01b_foundation.sql
-- Phase-1 foundation that exists in the Vani DB but was never saved as a migration.
-- Rebuilt from the live Vani schema (read only), 23 Nov 2026.
create schema if not exists private;

alter table public.patients add column if not exists phone_e164 text;
alter table public.patients add constraint patients_phone_e164_format_check
  check (phone_e164 is null or phone_e164 ~ '^\+[1-9][0-9]{6,14}$') not valid;
create index if not exists patients_phone_e164_idx on public.patients (phone_e164);

alter table public.bookings
  add column if not exists patient_name_snapshot text,
  add column if not exists phone_e164_snapshot text,
  add column if not exists platform_call_id text;
alter table public.bookings add constraint bookings_snapshot_phone_e164_format_check
  check (phone_e164_snapshot is null or phone_e164_snapshot ~ '^\+[1-9][0-9]{6,14}$') not valid;
create index if not exists bookings_patient_id_idx on public.bookings (patient_id);
create index if not exists bookings_doctor_status_time_idx on public.bookings (doctor_id, status, appointment_time);

create table if not exists public.appointment_events (
  id uuid primary key default gen_random_uuid(),
  booking_id uuid not null references public.bookings(id) on delete restrict,
  related_booking_id uuid references public.bookings(id) on delete restrict,
  action text not null check (action in ('created','rescheduled','cancelled','arrived','completed','no_show','confirmed')),
  source text not null check (source in ('ai_agent','staff','system')),
  platform_call_id text,
  idempotency_key uuid,
  details jsonb not null default '{}'::jsonb check (jsonb_typeof(details) = 'object'),
  created_at timestamptz not null default now()
);
create index if not exists appointment_events_booking_created_idx
  on public.appointment_events (booking_id, created_at desc);
alter table public.appointment_events enable row level security;

create table if not exists private.appointment_operations (
  id uuid primary key default gen_random_uuid(),
  action text not null check (action in ('book','reschedule','cancel')),
  idempotency_key uuid not null,
  request_fingerprint text not null,
  booking_id uuid references public.bookings(id),
  related_booking_id uuid references public.bookings(id),
  result jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  unique (action, idempotency_key)
);
alter table private.appointment_operations enable row level security;


;

-- ######## 02_appointments_and_staff.sql
-- ==== 20260924103000_appointment_transactions_v2.sql
-- Appointment transaction API v2 (REVIEW BEFORE APPLYING).
--
-- This migration deliberately depends on the Phase-1 schema foundation already
-- present in production: patients.phone_e164, booking snapshots,
-- appointment_events, private.appointment_operations, and the existing
-- unique confirmed (doctor_id, appointment_time) protection.
-- It does not grant EXECUTE to browser roles. Edge Functions invoke these RPCs
-- using their service-role key after their own webhook authentication.

begin;

create schema if not exists private;

-- The transaction checks availability optimistically, then this partial index
-- is the final concurrency guard: two confirmed bookings can never occupy the
-- same doctor and instant, even when requests arrive simultaneously.
create unique index if not exists bookings_one_confirmed_slot_idx
  on public.bookings (doctor_id, appointment_time)
  where status = 'confirmed';

create or replace function private.normalized_patient_name(p_value text)
returns text
language sql
immutable
strict
set search_path = pg_catalog
as $$
  select lower(regexp_replace(btrim(p_value), '[[:space:]]+', ' ', 'g'))
$$;

create or replace function private.display_patient_name(p_value text)
returns text
language sql
immutable
strict
set search_path = pg_catalog
as $$
  select regexp_replace(btrim(p_value), '[[:space:]]+', ' ', 'g')
$$;

create or replace function private.canonical_e164(p_value text)
returns text
language plpgsql
immutable
strict
set search_path = pg_catalog
as $$
declare
  v_phone text := regexp_replace(btrim(p_value), '[() .-]', '', 'g');
begin
  -- Canonical input is E.164.  We also accept a leading international 00
  -- prefix because callers commonly dictate it that way; no country is assumed.
  if v_phone like '00%' then
    v_phone := '+' || substr(v_phone, 3);
  end if;
  if v_phone !~ E'^\\+[1-9][0-9]{6,14}$' then
    return null;
  end if;
  return v_phone;
end;
$$;

create or replace function private.mask_e164(p_phone text)
returns text
language sql
immutable
strict
set search_path = pg_catalog
as $$
  select case
    when length(p_phone) <= 5 then '***'
    else left(p_phone, greatest(2, length(p_phone) - 4)) || '****'
  end
$$;

create or replace function private.appointment_result(
  p_success boolean,
  p_action text,
  p_error_code text default null,
  p_result_text text default null,
  p_booking_id uuid default null,
  p_old_booking_id uuid default null,
  p_patient_name text default null,
  p_phone_e164 text default null,
  p_doctor_name text default null,
  p_appointment_time timestamptz default null,
  p_old_appointment_time timestamptz default null,
  p_status text default null
)
returns jsonb
language sql
stable
set search_path = pg_catalog
as $$
  select jsonb_strip_nulls(jsonb_build_object(
    'success', p_success,
    'booking_success', case when p_action = 'book' then p_success else false end,
    'reschedule_success', case when p_action = 'reschedule' then p_success else false end,
    'cancellation_success', case when p_action = 'cancel' then p_success else false end,
    'error_code', p_error_code,
    'result_text', p_result_text,
    'booking_id', p_booking_id,
    'old_booking_id', p_old_booking_id,
    'patient_name', p_patient_name,
    'masked_phone', private.mask_e164(p_phone_e164),
    'canonical_doctor_name', p_doctor_name,
    'appointment_time_india', case when p_appointment_time is null then null
      else to_char(p_appointment_time at time zone 'Asia/Kolkata', 'YYYY-MM-DD HH24:MI') end,
    'old_appointment_time_india', case when p_old_appointment_time is null then null
      else to_char(p_old_appointment_time at time zone 'Asia/Kolkata', 'YYYY-MM-DD HH24:MI') end,
    'status', p_status
  ));
$$;

create or replace function private.operation_replay_or_lock(
  p_action text,
  p_idempotency_key uuid,
  p_fingerprint text
)
returns jsonb
language plpgsql
security definer
set search_path = pg_catalog, private
as $$
declare
  v_operation private.appointment_operations%rowtype;
begin
  if p_idempotency_key is null then
    return private.appointment_result(false, p_action, 'IDEMPOTENCY_KEY_REQUIRED',
      'Please try the request again.');
  end if;

  -- Serialize same action/key before checking, avoiding a duplicate mutation
  -- during a network retry. UUID key is supplied by the server, never a
  -- Voice-AI provider tool-call id.
  perform pg_advisory_xact_lock(hashtextextended(p_action || ':' || p_idempotency_key::text, 0));
  select * into v_operation
  from private.appointment_operations
  where action = p_action and idempotency_key = p_idempotency_key
  for update;

  if found then
    if v_operation.request_fingerprint <> p_fingerprint then
      return private.appointment_result(false, p_action, 'IDEMPOTENCY_MISMATCH',
        'That retry does not match the original request.');
    end if;
    return v_operation.result;
  end if;
  return null;
end;
$$;

create or replace function private.store_operation(
  p_action text,
  p_idempotency_key uuid,
  p_fingerprint text,
  p_booking_id uuid,
  p_related_booking_id uuid,
  p_result jsonb
)
returns void
language sql
security definer
set search_path = pg_catalog, private
as $$
  insert into private.appointment_operations
    (action, idempotency_key, request_fingerprint, booking_id, related_booking_id, result)
  values
    (p_action, p_idempotency_key, p_fingerprint, p_booking_id, p_related_booking_id, p_result)
$$;

create or replace function private.validate_appointment_slot(
  p_doctor public.doctors,
  p_appointment_time timestamptz,
  p_booking_window_days integer default 7
)
returns text
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
declare
  v_local timestamp := p_appointment_time at time zone 'Asia/Kolkata';
  v_date date := (p_appointment_time at time zone 'Asia/Kolkata')::date;
  v_start time := p_doctor.start_time::time;
  v_end time := p_doctor.end_time::time;
  v_days integer[];
begin
  if date_trunc('minute', v_local) <> v_local
     or extract(minute from v_local)::integer % 15 <> 0 then
    return 'INVALID_SLOT_GRID';
  end if;
  if p_appointment_time < now() + interval '5 minutes' then
    return 'PAST_OR_TOO_SOON';
  end if;
  if v_date > (now() at time zone 'Asia/Kolkata')::date + greatest(1, least(coalesce(p_booking_window_days, 7), 30)) then
    return 'OUTSIDE_BOOKING_WINDOW';
  end if;
  v_days := regexp_split_to_array(coalesce(p_doctor.working_days, ''), '[[:space:]]*,[[:space:]]*')::integer[];
  if not (extract(dow from v_date)::integer = any(v_days)) then
    return 'DOCTOR_NOT_WORKING';
  end if;
  if v_local::time < v_start or (v_local + interval '15 minutes')::time > v_end then
    return 'OUTSIDE_DOCTOR_HOURS';
  end if;
  if exists (
    select 1 from public.doctor_leave dl
    where dl.doctor_id = p_doctor.id
      and v_date between dl.leave_start_date::date and dl.leave_end_date::date
  ) then
    return 'DOCTOR_ON_LEAVE';
  end if;
  return null;
end;
$$;

create or replace function private.resolve_active_doctor(p_doctor_name text)
returns public.doctors
language plpgsql
security definer
set search_path = pg_catalog, public, private
as $$
declare v_doctor public.doctors%rowtype;
begin
  -- A normalized exact name is intentional: surname and fuzzy matches can
  -- select a different clinician. The row lock serializes schedule updates.
  select d.* into v_doctor
  from public.doctors d
  where lower(regexp_replace(regexp_replace(btrim(d.name), '^dr[.]?[[:space:]]+', '', 'i'), '[[:space:]]+', ' ', 'g'))
      = lower(regexp_replace(regexp_replace(btrim(p_doctor_name), '^dr[.]?[[:space:]]+', '', 'i'), '[[:space:]]+', ' ', 'g'))
    and coalesce(d.active, false) = true
  for update;
  return v_doctor;
end;
$$;

create or replace function public.book_appointment_v2(
  p_patient_name text,
  p_phone_e164 text,
  p_doctor_name text,
  p_appointment_time timestamptz,
  p_idempotency_key uuid,
  p_platform_call_id text default null,
  p_source text default 'ai_agent',
  p_booking_window_days integer default 7
)
returns jsonb
language plpgsql
security definer
set search_path = pg_catalog, public, private
as $$
declare
  v_name text := private.display_patient_name(p_patient_name);
  v_name_key text := private.normalized_patient_name(p_patient_name);
  v_phone text := private.canonical_e164(p_phone_e164);
  v_fingerprint text;
  v_replay jsonb;
  v_result jsonb;
  v_doctor public.doctors%rowtype;
  v_patient public.patients%rowtype;
  v_booking public.bookings%rowtype;
  v_error text;
begin
  v_fingerprint := md5(concat_ws('|', v_name_key, coalesce(v_phone, ''), lower(btrim(p_doctor_name)), coalesce(p_appointment_time::text, ''), coalesce(p_source, '')));
  v_replay := private.operation_replay_or_lock('book', p_idempotency_key, v_fingerprint);
  if v_replay is not null then return v_replay; end if;
  if v_name_key is null or length(v_name) not between 2 and 120 then
    return private.appointment_result(false, 'book', 'INVALID_PATIENT_NAME', 'Please provide the patient name.');
  end if;
  if v_phone is null then
    return private.appointment_result(false, 'book', 'INVALID_PHONE_E164', 'Please provide the phone number with its country code.');
  end if;
  if p_appointment_time is null then
    return private.appointment_result(false, 'book', 'INVALID_APPOINTMENT_TIME', 'Please provide the appointment date and time.');
  end if;
  if p_source not in ('ai_agent', 'staff', 'system') then
    return private.appointment_result(false, 'book', 'INVALID_SOURCE', 'Unable to process that request.');
  end if;

  -- The existing schedule-change worker is the only component that knows the
  -- live doctor_schedule_changes shape. It must materialize due changes into
  -- doctors before this RPC is called; this transaction intentionally checks
  -- the locked current doctors row rather than guessing that function's API.
  select * into v_doctor from private.resolve_active_doctor(p_doctor_name);
  if v_doctor.id is null then
    return private.appointment_result(false, 'book', 'DOCTOR_NOT_FOUND_OR_INACTIVE', 'That doctor is not available for booking.');
  end if;
  v_error := private.validate_appointment_slot(v_doctor, p_appointment_time, p_booking_window_days);
  if v_error is not null then
    return private.appointment_result(false, 'book', v_error, 'That appointment time is not available.');
  end if;

  perform pg_advisory_xact_lock(hashtextextended(v_name_key || ':' || v_phone, 0));
  select * into v_patient from public.patients
  where private.normalized_patient_name(name) = v_name_key and phone_e164 = v_phone
  for update;
  if v_patient.id is null then
    insert into public.patients (name, phone, phone_e164)
    values (v_name, v_phone, v_phone)
    returning * into v_patient;
  end if;

  if exists (select 1 from public.bookings b where b.doctor_id = v_doctor.id and b.appointment_time = p_appointment_time and b.status = 'confirmed') then
    return private.appointment_result(false, 'book', 'SLOT_TAKEN', 'That slot was just taken. Please choose another time.');
  end if;
  begin
    insert into public.bookings (patient_id, doctor_id, appointment_time, status, source, patient_name_snapshot, phone_e164_snapshot, platform_call_id, updated_at)
    values (v_patient.id, v_doctor.id, p_appointment_time, 'confirmed', p_source, v_name, v_phone, nullif(btrim(p_platform_call_id), ''), now())
    returning * into v_booking;
  exception when unique_violation then
    return private.appointment_result(false, 'book', 'SLOT_TAKEN', 'That slot was just taken. Please choose another time.');
  end;
  insert into public.appointment_events (booking_id, action, source, platform_call_id, idempotency_key, details)
  values (v_booking.id, 'created', p_source, nullif(btrim(p_platform_call_id), ''), p_idempotency_key, jsonb_build_object('doctor_id', v_doctor.id));
  v_result := private.appointment_result(true, 'book', null, 'Appointment booked.', v_booking.id, null, v_name, v_phone, v_doctor.name, v_booking.appointment_time, null, v_booking.status);
  perform private.store_operation('book', p_idempotency_key, v_fingerprint, v_booking.id, null, v_result);
  return v_result;
end;
$$;

create or replace function public.reschedule_appointment_v2(
  p_patient_name text,
  p_phone_e164 text,
  p_doctor_name text,
  p_existing_appointment_time timestamptz,
  p_new_appointment_time timestamptz,
  p_idempotency_key uuid,
  p_platform_call_id text default null,
  p_source text default 'ai_agent',
  p_booking_window_days integer default 7
)
returns jsonb
language plpgsql
security definer
set search_path = pg_catalog, public, private
as $$
declare
  v_name text := private.display_patient_name(p_patient_name);
  v_name_key text := private.normalized_patient_name(p_patient_name);
  v_phone text := private.canonical_e164(p_phone_e164);
  v_fingerprint text; v_replay jsonb; v_result jsonb;
  v_doctor public.doctors%rowtype; v_old public.bookings%rowtype; v_new public.bookings%rowtype;
  v_error text;
begin
  v_fingerprint := md5(concat_ws('|', v_name_key, coalesce(v_phone, ''), lower(btrim(p_doctor_name)), coalesce(p_existing_appointment_time::text, ''), coalesce(p_new_appointment_time::text, ''), coalesce(p_source, '')));
  v_replay := private.operation_replay_or_lock('reschedule', p_idempotency_key, v_fingerprint);
  if v_replay is not null then return v_replay; end if;
  if v_name_key is null or length(v_name) not between 2 and 120 then return private.appointment_result(false, 'reschedule', 'INVALID_PATIENT_NAME', 'Please provide the patient name.'); end if;
  if v_phone is null then return private.appointment_result(false, 'reschedule', 'INVALID_PHONE_E164', 'Please provide the phone number with its country code.'); end if;
  if p_existing_appointment_time is null or p_new_appointment_time is null then return private.appointment_result(false, 'reschedule', 'INVALID_APPOINTMENT_TIME', 'Please provide both appointment date and times.'); end if;
  if p_new_appointment_time = p_existing_appointment_time then return private.appointment_result(false, 'reschedule', 'SAME_APPOINTMENT_TIME', 'Please choose a different appointment time.'); end if;
  if p_source not in ('ai_agent', 'staff', 'system') then return private.appointment_result(false, 'reschedule', 'INVALID_SOURCE', 'Unable to process that request.'); end if;
  select * into v_doctor from private.resolve_active_doctor(p_doctor_name);
  if v_doctor.id is null then return private.appointment_result(false, 'reschedule', 'DOCTOR_NOT_FOUND_OR_INACTIVE', 'That doctor is not available.'); end if;
  select b.* into v_old from public.bookings b
  where b.doctor_id = v_doctor.id and b.appointment_time = p_existing_appointment_time and b.status = 'confirmed'
    and private.normalized_patient_name(b.patient_name_snapshot) = v_name_key and b.phone_e164_snapshot = v_phone
  for update;
  if v_old.id is null then return private.appointment_result(false, 'reschedule', 'BOOKING_NOT_FOUND', 'I could not find that exact confirmed appointment.'); end if;
  v_error := private.validate_appointment_slot(v_doctor, p_new_appointment_time, p_booking_window_days);
  if v_error is not null then return private.appointment_result(false, 'reschedule', v_error, 'That new appointment time is not available.'); end if;
  if exists (select 1 from public.bookings b where b.doctor_id = v_doctor.id and b.appointment_time = p_new_appointment_time and b.status = 'confirmed') then return private.appointment_result(false, 'reschedule', 'SLOT_TAKEN', 'That slot was just taken. Please choose another time.'); end if;
  begin
    insert into public.bookings (patient_id, doctor_id, appointment_time, status, source, patient_name_snapshot, phone_e164_snapshot, platform_call_id, updated_at)
    values (v_old.patient_id, v_doctor.id, p_new_appointment_time, 'confirmed', p_source, v_old.patient_name_snapshot, v_old.phone_e164_snapshot, nullif(btrim(p_platform_call_id), ''), now())
    returning * into v_new;
  exception when unique_violation then return private.appointment_result(false, 'reschedule', 'SLOT_TAKEN', 'That slot was just taken. Please choose another time.'); end;
  update public.bookings set status = 'rescheduled', rescheduled_to_booking_id = v_new.id, updated_at = now() where id = v_old.id;
  insert into public.appointment_events (booking_id, related_booking_id, action, source, platform_call_id, idempotency_key, details) values
    (v_old.id, v_new.id, 'rescheduled', p_source, nullif(btrim(p_platform_call_id), ''), p_idempotency_key, jsonb_build_object('direction', 'from')),
    (v_new.id, v_old.id, 'created', p_source, nullif(btrim(p_platform_call_id), ''), p_idempotency_key, jsonb_build_object('rescheduled_from_booking_id', v_old.id));
  v_result := private.appointment_result(true, 'reschedule', null, 'Appointment rescheduled.', v_new.id, v_old.id, v_old.patient_name_snapshot, v_old.phone_e164_snapshot, v_doctor.name, v_new.appointment_time, v_old.appointment_time, 'confirmed');
  perform private.store_operation('reschedule', p_idempotency_key, v_fingerprint, v_new.id, v_old.id, v_result);
  return v_result;
end;
$$;

create or replace function public.cancel_appointment_v2(
  p_patient_name text,
  p_phone_e164 text,
  p_doctor_name text,
  p_existing_appointment_time timestamptz,
  p_idempotency_key uuid,
  p_platform_call_id text default null,
  p_source text default 'ai_agent'
)
returns jsonb
language plpgsql
security definer
set search_path = pg_catalog, public, private
as $$
declare
  v_name text := private.display_patient_name(p_patient_name); v_name_key text := private.normalized_patient_name(p_patient_name); v_phone text := private.canonical_e164(p_phone_e164);
  v_fingerprint text; v_replay jsonb; v_result jsonb; v_doctor public.doctors%rowtype; v_booking public.bookings%rowtype;
begin
  v_fingerprint := md5(concat_ws('|', v_name_key, coalesce(v_phone, ''), lower(btrim(p_doctor_name)), coalesce(p_existing_appointment_time::text, ''), coalesce(p_source, '')));
  v_replay := private.operation_replay_or_lock('cancel', p_idempotency_key, v_fingerprint);
  if v_replay is not null then return v_replay; end if;
  if v_name_key is null or length(v_name) not between 2 and 120 then return private.appointment_result(false, 'cancel', 'INVALID_PATIENT_NAME', 'Please provide the patient name.'); end if;
  if v_phone is null then return private.appointment_result(false, 'cancel', 'INVALID_PHONE_E164', 'Please provide the phone number with its country code.'); end if;
  if p_existing_appointment_time is null then return private.appointment_result(false, 'cancel', 'INVALID_APPOINTMENT_TIME', 'Please provide the appointment date and time.'); end if;
  if p_source not in ('ai_agent', 'staff', 'system') then return private.appointment_result(false, 'cancel', 'INVALID_SOURCE', 'Unable to process that request.'); end if;
  select * into v_doctor from private.resolve_active_doctor(p_doctor_name);
  if v_doctor.id is null then return private.appointment_result(false, 'cancel', 'DOCTOR_NOT_FOUND_OR_INACTIVE', 'That doctor is not available.'); end if;
  select b.* into v_booking from public.bookings b
  where b.doctor_id = v_doctor.id and b.appointment_time = p_existing_appointment_time and b.status = 'confirmed'
    and private.normalized_patient_name(b.patient_name_snapshot) = v_name_key and b.phone_e164_snapshot = v_phone
  for update;
  if v_booking.id is null then return private.appointment_result(false, 'cancel', 'BOOKING_NOT_FOUND', 'I could not find that exact confirmed appointment.'); end if;
  update public.bookings set status = 'cancelled', updated_at = now() where id = v_booking.id;
  insert into public.appointment_events (booking_id, action, source, platform_call_id, idempotency_key, details)
  values (v_booking.id, 'cancelled', p_source, nullif(btrim(p_platform_call_id), ''), p_idempotency_key, '{}'::jsonb);
  v_result := private.appointment_result(true, 'cancel', null, 'Appointment cancelled.', v_booking.id, null, v_booking.patient_name_snapshot, v_booking.phone_e164_snapshot, v_doctor.name, v_booking.appointment_time, null, 'cancelled');
  perform private.store_operation('cancel', p_idempotency_key, v_fingerprint, v_booking.id, null, v_result);
  return v_result;
end;
$$;

revoke all on function private.normalized_patient_name(text) from public;
revoke all on function private.display_patient_name(text) from public;
revoke all on function private.canonical_e164(text) from public;
revoke all on function private.mask_e164(text) from public;
revoke all on function private.appointment_result(boolean,text,text,text,uuid,uuid,text,text,text,timestamptz,timestamptz,text) from public;
revoke all on function private.operation_replay_or_lock(text,uuid,text) from public;
revoke all on function private.store_operation(text,uuid,text,uuid,uuid,jsonb) from public;
revoke all on function private.validate_appointment_slot(public.doctors,timestamptz,integer) from public;
revoke all on function private.resolve_active_doctor(text) from public;
revoke all on function public.book_appointment_v2(text,text,text,timestamptz,uuid,text,text,integer) from public, anon, authenticated;
revoke all on function public.reschedule_appointment_v2(text,text,text,timestamptz,timestamptz,uuid,text,text,integer) from public, anon, authenticated;
revoke all on function public.cancel_appointment_v2(text,text,text,timestamptz,uuid,text,text) from public, anon, authenticated;
grant execute on function public.book_appointment_v2(text,text,text,timestamptz,uuid,text,text,integer) to service_role;
grant execute on function public.reschedule_appointment_v2(text,text,text,timestamptz,timestamptz,uuid,text,text,integer) to service_role;
grant execute on function public.cancel_appointment_v2(text,text,text,timestamptz,uuid,text,text) to service_role;
-- Do not grant these routines to anon/authenticated until a staff-RPC design exists.

commit;

;
-- ==== 20260924162604_secure_staff_booking_rpc.sql
-- Secure staff booking RPC (STAGED ONLY — do not apply until the dashboard
-- Edge Function has been deployed and reviewed).
--
-- The browser must never receive a service-role key or call this function
-- directly. The staff-book Edge Function verifies the staff JWT and forwards
-- its authenticated user id as p_actor_user_id. This routine verifies the
-- actor's server-side profile again before it mutates appointment records.

begin;

alter table public.appointment_events
  add column if not exists actor_user_id uuid references auth.users(id) on delete restrict;

create index if not exists appointment_events_actor_created_idx
  on public.appointment_events (actor_user_id, created_at desc)
  where actor_user_id is not null;

create or replace function private.prevent_appointment_event_mutation()
returns trigger
language plpgsql
security definer
set search_path = pg_catalog
as $$
begin
  raise exception 'appointment events are immutable';
end;
$$;

drop trigger if exists appointment_events_immutable on public.appointment_events;
create trigger appointment_events_immutable
  before update or delete on public.appointment_events
  for each row execute function private.prevent_appointment_event_mutation();

create or replace function public.staff_book_appointment_v1(
  p_actor_user_id uuid,
  p_patient_name text,
  p_phone_e164 text,
  p_doctor_name text,
  p_appointment_time timestamptz,
  p_idempotency_key uuid,
  p_booking_window_days integer default 30
)
returns jsonb
language plpgsql
security definer
set search_path = pg_catalog
as $$
declare
  v_actor_role text;
  v_name text := private.display_patient_name(p_patient_name);
  v_name_key text := private.normalized_patient_name(p_patient_name);
  v_phone text := private.canonical_e164(p_phone_e164);
  v_fingerprint text;
  v_replay jsonb;
  v_result jsonb;
  v_doctor public.doctors%rowtype;
  v_patient public.patients%rowtype;
  v_booking public.bookings%rowtype;
  v_error text;
begin
  -- The Edge Function derives this id from the verified access token. It must
  -- never accept a user id supplied by untrusted browser JSON.
  if p_actor_user_id is null then
    return private.appointment_result(false, 'book', 'ACTOR_REQUIRED',
      'Sign in again before creating an appointment.');
  end if;

  select lower(btrim(p.role)) into v_actor_role
  from public.profiles p
  where p.id = p_actor_user_id;

  if coalesce(v_actor_role, '') not in ('staff', 'receptionist', 'admin', 'owner') then
    return private.appointment_result(false, 'book', 'STAFF_ROLE_REQUIRED',
      'This account is not allowed to create appointments.');
  end if;

  if v_name_key is null or length(v_name) not between 2 and 120 then
    return private.appointment_result(false, 'book', 'INVALID_PATIENT_NAME',
      'Please provide the patient name.');
  end if;
  if v_phone is null then
    return private.appointment_result(false, 'book', 'INVALID_PHONE_E164',
      'Please provide the phone number with its country code.');
  end if;
  if p_appointment_time is null then
    return private.appointment_result(false, 'book', 'INVALID_APPOINTMENT_TIME',
      'Please provide the appointment date and time.');
  end if;

  -- Bind retries to both the action and the verified staff actor.
  v_fingerprint := md5(concat_ws('|', p_actor_user_id::text, v_name_key,
    v_phone, lower(btrim(p_doctor_name)), p_appointment_time::text,
    greatest(1, least(coalesce(p_booking_window_days, 30), 90))::text));
  -- Reuse the established `book` action because the private idempotency ledger
  -- constrains action to book/reschedule/cancel. The actor is part of the
  -- fingerprint, so a key cannot be replayed by a different staff account.
  v_replay := private.operation_replay_or_lock('book', p_idempotency_key, v_fingerprint);
  if v_replay is not null then
    return v_replay;
  end if;

  select * into v_doctor from private.resolve_active_doctor(p_doctor_name);
  if v_doctor.id is null then
    return private.appointment_result(false, 'book', 'DOCTOR_NOT_FOUND_OR_INACTIVE',
      'That doctor is not available for booking.');
  end if;

  v_error := private.validate_appointment_slot(
    v_doctor,
    p_appointment_time,
    greatest(1, least(coalesce(p_booking_window_days, 30), 90))
  );
  if v_error is not null then
    return private.appointment_result(false, 'book', v_error,
      'That appointment time is not available.');
  end if;

  -- A fast pre-check gives staff a friendly response. The unique index remains
  -- authoritative, because another request may book the slot after this check.
  if exists (
    select 1 from public.bookings b
    where b.doctor_id = v_doctor.id
      and b.appointment_time = p_appointment_time
      and b.status = 'confirmed'
  ) then
    return private.appointment_result(false, 'book', 'SLOT_TAKEN',
      'That slot was just taken. Please choose another time.');
  end if;

  -- Keep identity creation and booking insertion in one nested transaction.
  -- If the final unique slot check loses a race, the nested block rolls back
  -- a newly-created patient instead of leaving an orphaned patient record.
  begin
    perform pg_advisory_xact_lock(hashtextextended(v_name_key || ':' || v_phone, 0));
    select * into v_patient
    from public.patients
    where private.normalized_patient_name(name) = v_name_key
      and phone_e164 = v_phone
    for update;

    if v_patient.id is null then
      insert into public.patients (name, phone, phone_e164)
      values (v_name, v_phone, v_phone)
      returning * into v_patient;
    end if;

    insert into public.bookings (
      patient_id, doctor_id, appointment_time, status, source,
      patient_name_snapshot, phone_e164_snapshot, updated_at, updated_by
    ) values (
      v_patient.id, v_doctor.id, p_appointment_time, 'confirmed', 'staff',
      v_name, v_phone, now(), p_actor_user_id
    ) returning * into v_booking;
  exception when unique_violation then
    return private.appointment_result(false, 'book', 'SLOT_TAKEN',
      'That slot was just taken. Please choose another time.');
  end;

  insert into public.appointment_events (
    booking_id, action, source, idempotency_key, actor_user_id, details
  ) values (
    v_booking.id, 'created', 'staff', p_idempotency_key, p_actor_user_id,
    jsonb_build_object('doctor_id', v_doctor.id, 'actor_role', v_actor_role)
  );

  v_result := private.appointment_result(
    true, 'book', null, 'Appointment booked.', v_booking.id, null,
    v_name, v_phone, v_doctor.name, v_booking.appointment_time, null,
    v_booking.status
  );
  perform private.store_operation('book', p_idempotency_key,
    v_fingerprint, v_booking.id, null, v_result);
  return v_result;
end;
$$;

revoke all on function private.prevent_appointment_event_mutation() from public;
revoke all on function private.prevent_appointment_event_mutation() from anon, authenticated;
revoke all on function public.staff_book_appointment_v1(uuid,text,text,text,timestamptz,uuid,integer)
  from public, anon, authenticated;
grant execute on function public.staff_book_appointment_v1(uuid,text,text,text,timestamptz,uuid,integer)
  to service_role;

commit;

;
-- ==== 20260926165412_fix_staff_booking_atomicity.sql
begin;

create or replace function public.staff_book_appointment_v1(
  p_actor_user_id uuid,
  p_patient_name text,
  p_phone_e164 text,
  p_doctor_name text,
  p_appointment_time timestamptz,
  p_idempotency_key uuid,
  p_booking_window_days integer default 30
)
returns jsonb
language plpgsql
security definer
set search_path = pg_catalog
as $$
declare
  v_actor_role text;
  v_name text := private.display_patient_name(p_patient_name);
  v_name_key text := private.normalized_patient_name(p_patient_name);
  v_phone text := private.canonical_e164(p_phone_e164);
  v_fingerprint text;
  v_replay jsonb;
  v_result jsonb;
  v_doctor public.doctors%rowtype;
  v_patient public.patients%rowtype;
  v_booking public.bookings%rowtype;
  v_error text;
begin
  if p_actor_user_id is null then
    return private.appointment_result(false, 'book', 'ACTOR_REQUIRED', 'Sign in again before creating an appointment.');
  end if;

  select lower(btrim(p.role)) into v_actor_role from public.profiles p where p.id = p_actor_user_id;
  if coalesce(v_actor_role, '') not in ('staff', 'receptionist', 'admin', 'owner') then
    return private.appointment_result(false, 'book', 'STAFF_ROLE_REQUIRED', 'This account is not allowed to create appointments.');
  end if;
  if v_name_key is null or length(v_name) not between 2 and 120 then
    return private.appointment_result(false, 'book', 'INVALID_PATIENT_NAME', 'Please provide the patient name.');
  end if;
  if v_phone is null then
    return private.appointment_result(false, 'book', 'INVALID_PHONE_E164', 'Please provide the phone number with its country code.');
  end if;
  if p_appointment_time is null then
    return private.appointment_result(false, 'book', 'INVALID_APPOINTMENT_TIME', 'Please provide the appointment date and time.');
  end if;

  v_fingerprint := md5(concat_ws('|', p_actor_user_id::text, v_name_key, v_phone, lower(btrim(p_doctor_name)), p_appointment_time::text, greatest(1, least(coalesce(p_booking_window_days, 30), 90))::text));
  v_replay := private.operation_replay_or_lock('book', p_idempotency_key, v_fingerprint);
  if v_replay is not null then return v_replay; end if;

  select * into v_doctor from private.resolve_active_doctor(p_doctor_name);
  if v_doctor.id is null then
    return private.appointment_result(false, 'book', 'DOCTOR_NOT_FOUND_OR_INACTIVE', 'That doctor is not available for booking.');
  end if;
  v_error := private.validate_appointment_slot(v_doctor, p_appointment_time, greatest(1, least(coalesce(p_booking_window_days, 30), 90)));
  if v_error is not null then
    return private.appointment_result(false, 'book', v_error, 'That appointment time is not available.');
  end if;

  if exists (
    select 1 from public.bookings b
    where b.doctor_id = v_doctor.id and b.appointment_time = p_appointment_time and b.status = 'confirmed'
  ) then
    return private.appointment_result(false, 'book', 'SLOT_TAKEN', 'That slot was just taken. Please choose another time.');
  end if;

  begin
    perform pg_advisory_xact_lock(hashtextextended(v_name_key || ':' || v_phone, 0));
    select * into v_patient from public.patients
    where private.normalized_patient_name(name) = v_name_key and phone_e164 = v_phone
    for update;
    if v_patient.id is null then
      insert into public.patients (name, phone, phone_e164) values (v_name, v_phone, v_phone) returning * into v_patient;
    end if;
    insert into public.bookings (
      patient_id, doctor_id, appointment_time, status, source,
      patient_name_snapshot, phone_e164_snapshot, updated_at, updated_by
    ) values (
      v_patient.id, v_doctor.id, p_appointment_time, 'confirmed', 'staff',
      v_name, v_phone, now(), p_actor_user_id
    ) returning * into v_booking;
  exception when unique_violation then
    return private.appointment_result(false, 'book', 'SLOT_TAKEN', 'That slot was just taken. Please choose another time.');
  end;

  insert into public.appointment_events (booking_id, action, source, idempotency_key, actor_user_id, details)
  values (v_booking.id, 'created', 'staff', p_idempotency_key, p_actor_user_id,
    jsonb_build_object('doctor_id', v_doctor.id, 'actor_role', v_actor_role));
  v_result := private.appointment_result(true, 'book', null, 'Appointment booked.', v_booking.id, null, v_name, v_phone, v_doctor.name, v_booking.appointment_time, null, v_booking.status);
  perform private.store_operation('book', p_idempotency_key, v_fingerprint, v_booking.id, null, v_result);
  return v_result;
end;
$$;

revoke all on function public.staff_book_appointment_v1(uuid,text,text,text,timestamptz,uuid,integer) from public, anon, authenticated;
grant execute on function public.staff_book_appointment_v1(uuid,text,text,text,timestamptz,uuid,integer) to service_role;

commit;

;
-- ==== 20260926165432_secure_staff_action_rpcs.sql
-- Secure staff mutation APIs (STAGED ONLY — not applied or deployed here).
--
-- These routines replace direct browser writes for booking lifecycle actions
-- and callback completion.  Edge Functions must verify the staff JWT and pass
-- the derived Auth user id; browser supplied actor ids are never trusted.

begin;

create table if not exists private.staff_action_operations (
  action text not null,
  idempotency_key uuid not null,
  request_fingerprint text not null,
  result jsonb not null,
  created_at timestamptz not null default now(),
  primary key (action, idempotency_key)
);

create table if not exists private.staff_action_events (
  id uuid primary key default gen_random_uuid(),
  actor_user_id uuid not null references auth.users(id) on delete restrict,
  target_type text not null check (target_type in ('call', 'callback_request')),
  target_id uuid not null,
  action text not null check (action = 'callback_completed'),
  created_at timestamptz not null default now()
);
create index if not exists staff_action_events_target_idx
  on private.staff_action_events (target_type, target_id, created_at desc);

create or replace function private.staff_actor_role(p_actor_user_id uuid)
returns text
language sql
stable
security definer
set search_path = pg_catalog, public
as $$
  select lower(btrim(role)) from public.profiles where id = p_actor_user_id
$$;

create or replace function private.staff_action_replay_or_lock(
  p_action text,
  p_idempotency_key uuid,
  p_fingerprint text
)
returns jsonb
language plpgsql
security definer
set search_path = pg_catalog, private
as $$
declare v_operation private.staff_action_operations%rowtype;
begin
  if p_idempotency_key is null then
    return jsonb_build_object('success', false, 'error_code', 'IDEMPOTENCY_KEY_REQUIRED');
  end if;
  perform pg_advisory_xact_lock(hashtextextended('staff:' || p_action || ':' || p_idempotency_key::text, 0));
  select * into v_operation from private.staff_action_operations
  where action = p_action and idempotency_key = p_idempotency_key
  for update;
  if found then
    if v_operation.request_fingerprint <> p_fingerprint then
      return jsonb_build_object('success', false, 'error_code', 'IDEMPOTENCY_MISMATCH');
    end if;
    return v_operation.result;
  end if;
  return null;
end;
$$;

create or replace function private.store_staff_action(
  p_action text, p_idempotency_key uuid, p_fingerprint text, p_result jsonb
)
returns void
language sql
security definer
set search_path = pg_catalog, private
as $$
  insert into private.staff_action_operations (action, idempotency_key, request_fingerprint, result)
  values (p_action, p_idempotency_key, p_fingerprint, p_result)
$$;

create or replace function public.staff_update_booking_v1(
  p_actor_user_id uuid,
  p_booking_id uuid,
  p_action text,
  p_idempotency_key uuid,
  p_new_appointment_time timestamptz default null
)
returns jsonb
language plpgsql
security definer
set search_path = pg_catalog, public, private
as $$
declare
  v_role text;
  v_action text := lower(btrim(p_action));
  v_fingerprint text;
  v_replay jsonb;
  v_result jsonb;
  v_booking public.bookings%rowtype;
  v_doctor public.doctors%rowtype;
  v_new public.bookings%rowtype;
  v_slot_error text;
begin
  v_role := private.staff_actor_role(p_actor_user_id);
  if coalesce(v_role, '') not in ('staff', 'receptionist', 'admin', 'owner') then
    return jsonb_build_object('success', false, 'error_code', 'STAFF_ROLE_REQUIRED');
  end if;
  if p_booking_id is null or v_action not in ('arrived', 'completed', 'no_show', 'cancelled', 'confirmed', 'reschedule') then
    return jsonb_build_object('success', false, 'error_code', 'INVALID_REQUEST');
  end if;
  if v_action = 'reschedule' and p_new_appointment_time is null then
    return jsonb_build_object('success', false, 'error_code', 'INVALID_APPOINTMENT_TIME');
  end if;

  v_fingerprint := md5(concat_ws('|', p_actor_user_id::text, p_booking_id::text,
    v_action, coalesce(p_new_appointment_time::text, '')));
  v_replay := private.staff_action_replay_or_lock('booking_' || v_action, p_idempotency_key, v_fingerprint);
  if v_replay is not null then return v_replay; end if;

  select b.* into v_booking from public.bookings b
  where b.id = p_booking_id for update;
  if v_booking.id is null then
    return jsonb_build_object('success', false, 'error_code', 'BOOKING_NOT_FOUND');
  end if;
  select d.* into v_doctor from public.doctors d
  where d.id = v_booking.doctor_id for update;

  if v_action = 'reschedule' then
    if v_booking.status <> 'confirmed' then
      return jsonb_build_object('success', false, 'error_code', 'INVALID_STATUS_TRANSITION');
    end if;
    if p_new_appointment_time = v_booking.appointment_time then
      return jsonb_build_object('success', false, 'error_code', 'SAME_APPOINTMENT_TIME');
    end if;
    v_slot_error := private.validate_appointment_slot(v_doctor, p_new_appointment_time, 30);
    if v_slot_error is not null then
      return jsonb_build_object('success', false, 'error_code', v_slot_error);
    end if;
    -- The database unique index remains the final guard against a concurrent
    -- reservation of the exact new slot.
    begin
      insert into public.bookings (
        patient_id, doctor_id, appointment_time, status, source,
        patient_name_snapshot, phone_e164_snapshot, updated_at, updated_by
      ) values (
        v_booking.patient_id, v_booking.doctor_id, p_new_appointment_time, 'confirmed', 'staff',
        v_booking.patient_name_snapshot, v_booking.phone_e164_snapshot, now(), p_actor_user_id
      ) returning * into v_new;
    exception when unique_violation then
      return jsonb_build_object('success', false, 'error_code', 'SLOT_TAKEN');
    end;
    update public.bookings set status = 'rescheduled', rescheduled_to_booking_id = v_new.id,
      updated_at = now(), updated_by = p_actor_user_id where id = v_booking.id;
    insert into public.appointment_events
      (booking_id, related_booking_id, action, source, idempotency_key, actor_user_id, details)
    values
      (v_booking.id, v_new.id, 'rescheduled', 'staff', p_idempotency_key, p_actor_user_id,
       jsonb_build_object('direction', 'from', 'actor_role', v_role)),
      (v_new.id, v_booking.id, 'created', 'staff', p_idempotency_key, p_actor_user_id,
       jsonb_build_object('rescheduled_from_booking_id', v_booking.id, 'actor_role', v_role));
    v_result := jsonb_build_object('success', true, 'booking_id', v_new.id, 'old_booking_id', v_booking.id,
      'status', 'confirmed', 'appointment_time_india', to_char(p_new_appointment_time at time zone 'Asia/Kolkata', 'YYYY-MM-DD HH24:MI'));
  else
    if not (
      (v_booking.status = 'confirmed' and v_action in ('arrived', 'no_show', 'cancelled')) or
      (v_booking.status = 'arrived' and v_action = 'completed')
    ) then
      return jsonb_build_object('success', false, 'error_code', 'INVALID_STATUS_TRANSITION');
    end if;
    update public.bookings set status = v_action, updated_at = now(), updated_by = p_actor_user_id
      where id = v_booking.id;
    insert into public.appointment_events
      (booking_id, action, source, idempotency_key, actor_user_id, details)
    values (v_booking.id, v_action,
      'staff', p_idempotency_key, p_actor_user_id,
      jsonb_build_object('from_status', v_booking.status, 'to_status', v_action, 'actor_role', v_role));
    v_result := jsonb_build_object('success', true, 'booking_id', v_booking.id, 'status', v_action);
  end if;
  perform private.store_staff_action('booking_' || v_action, p_idempotency_key, v_fingerprint, v_result);
  return v_result;
end;
$$;

create or replace function public.staff_complete_callback_v1(
  p_actor_user_id uuid,
  p_target_type text,
  p_target_id uuid,
  p_idempotency_key uuid
)
returns jsonb
language plpgsql
security definer
set search_path = pg_catalog, public, private
as $$
declare
  v_role text;
  v_type text := lower(btrim(p_target_type));
  v_fingerprint text;
  v_replay jsonb;
  v_result jsonb;
  v_found uuid;
begin
  v_role := private.staff_actor_role(p_actor_user_id);
  if coalesce(v_role, '') not in ('staff', 'receptionist', 'admin', 'owner') then
    return jsonb_build_object('success', false, 'error_code', 'STAFF_ROLE_REQUIRED');
  end if;
  if v_type not in ('call', 'callback_request') or p_target_id is null then
    return jsonb_build_object('success', false, 'error_code', 'INVALID_REQUEST');
  end if;
  v_fingerprint := md5(concat_ws('|', p_actor_user_id::text, v_type, p_target_id::text));
  v_replay := private.staff_action_replay_or_lock('callback_completed_' || v_type, p_idempotency_key, v_fingerprint);
  if v_replay is not null then return v_replay; end if;
  if v_type = 'call' then
    update public.calls set callback_done = true
      where id = p_target_id and coalesce(callback_done, false) = false returning id into v_found;
  else
    update public.callback_requests set status = 'contacted', contacted_by = p_actor_user_id, contacted_at = now()
      where id = p_target_id and status = 'pending' returning id into v_found;
  end if;
  if v_found is null then
    return jsonb_build_object('success', false, 'error_code', 'CALLBACK_NOT_FOUND_OR_ALREADY_COMPLETED');
  end if;
  insert into private.staff_action_events (actor_user_id, target_type, target_id, action)
  values (p_actor_user_id, v_type, p_target_id, 'callback_completed');
  v_result := jsonb_build_object('success', true, 'target_type', v_type, 'target_id', p_target_id, 'status', 'completed');
  perform private.store_staff_action('callback_completed_' || v_type, p_idempotency_key, v_fingerprint, v_result);
  return v_result;
end;
$$;

revoke all on function private.staff_actor_role(uuid) from public, anon, authenticated;
revoke all on function private.staff_action_replay_or_lock(text,uuid,text) from public, anon, authenticated;
revoke all on function private.store_staff_action(text,uuid,text,jsonb) from public, anon, authenticated;
revoke all on function public.staff_update_booking_v1(uuid,uuid,text,uuid,timestamptz) from public, anon, authenticated;
revoke all on function public.staff_complete_callback_v1(uuid,text,uuid,uuid) from public, anon, authenticated;
grant execute on function public.staff_update_booking_v1(uuid,uuid,text,uuid,timestamptz) to service_role;
grant execute on function public.staff_complete_callback_v1(uuid,text,uuid,uuid) to service_role;

commit;

;
-- ==== 20260926170056_restrict_staff_browser_writes.sql
begin;

-- Staff still retain the narrowly scoped SELECT and callback-request INSERT
-- policies. All patient, booking, call, and callback-completion mutations now
-- pass through authenticated Edge Functions and audited database RPCs.
drop policy if exists "staff can manage patients" on public.patients;
drop policy if exists "staff can manage bookings" on public.bookings;
drop policy if exists "staff can manage calls" on public.calls;
drop policy if exists "staff can update callbacks" on public.callback_requests;

commit;

;
-- ==== 20260926170210_allow_audited_booking_reopen.sql
begin;

alter table public.appointment_events drop constraint if exists appointment_events_action_check;
alter table public.appointment_events add constraint appointment_events_action_check check (action = any (array['created','rescheduled','cancelled','arrived','completed','no_show','confirmed']));

create or replace function public.staff_reopen_booking_v1(p_actor_user_id uuid, p_booking_id uuid, p_idempotency_key uuid)
returns jsonb language plpgsql security definer set search_path = pg_catalog, public, private as $$
declare
  v_role text; v_fingerprint text; v_replay jsonb; v_booking public.bookings%rowtype; v_result jsonb;
begin
  v_role := private.staff_actor_role(p_actor_user_id);
  if coalesce(v_role, '') not in ('staff', 'receptionist', 'admin', 'owner') then return jsonb_build_object('success', false, 'error_code', 'STAFF_ROLE_REQUIRED'); end if;
  if p_booking_id is null then return jsonb_build_object('success', false, 'error_code', 'INVALID_REQUEST'); end if;
  v_fingerprint := md5(concat_ws('|', p_actor_user_id::text, p_booking_id::text, 'confirmed'));
  v_replay := private.staff_action_replay_or_lock('booking_confirmed', p_idempotency_key, v_fingerprint);
  if v_replay is not null then return v_replay; end if;
  select * into v_booking from public.bookings where id = p_booking_id for update;
  if v_booking.id is null then return jsonb_build_object('success', false, 'error_code', 'BOOKING_NOT_FOUND'); end if;
  if v_booking.status not in ('no_show', 'cancelled') then return jsonb_build_object('success', false, 'error_code', 'INVALID_STATUS_TRANSITION'); end if;
  update public.bookings set status = 'confirmed', updated_at = now(), updated_by = p_actor_user_id where id = v_booking.id;
  insert into public.appointment_events (booking_id, action, source, idempotency_key, actor_user_id, details)
  values (v_booking.id, 'confirmed', 'staff', p_idempotency_key, p_actor_user_id, jsonb_build_object('from_status', v_booking.status, 'to_status', 'confirmed', 'actor_role', v_role));
  v_result := jsonb_build_object('success', true, 'booking_id', v_booking.id, 'status', 'confirmed');
  perform private.store_staff_action('booking_confirmed', p_idempotency_key, v_fingerprint, v_result);
  return v_result;
end;
$$;

revoke all on function public.staff_reopen_booking_v1(uuid,uuid,uuid) from public, anon, authenticated;
grant execute on function public.staff_reopen_booking_v1(uuid,uuid,uuid) to service_role;
commit;

;
-- ==== secure_appointment_audit_rls
create policy "staff can view appointment events"
on public.appointment_events
for select
to authenticated
using (private.is_staff());

create policy "deny client access to appointment operations"
on private.appointment_operations
for all
to anon, authenticated
using (false)
with check (false);

;

-- ######## 03_audit_and_security.sql
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

;

-- ######## 04_guard_started_appointments.sql
-- guard_started_voice_appointment_changes (Vani project, 4 Nov 2026)
CREATE OR REPLACE FUNCTION public.cancel_appointment_v2(p_patient_name text, p_phone_e164 text, p_doctor_name text, p_existing_appointment_time timestamp with time zone, p_idempotency_key uuid, p_platform_call_id text DEFAULT NULL::text, p_source text DEFAULT 'ai_agent'::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public', 'private'
AS $function$
declare
  v_name text := private.display_patient_name(p_patient_name); v_name_key text := private.normalized_patient_name(p_patient_name); v_phone text := private.canonical_e164(p_phone_e164);
  v_fingerprint text; v_replay jsonb; v_result jsonb; v_doctor public.doctors%rowtype; v_booking public.bookings%rowtype;
begin
  v_fingerprint := md5(concat_ws('|', v_name_key, coalesce(v_phone, ''), lower(btrim(p_doctor_name)), coalesce(p_existing_appointment_time::text, ''), coalesce(p_source, '')));
  v_replay := private.operation_replay_or_lock('cancel', p_idempotency_key, v_fingerprint);
  if v_replay is not null then return v_replay; end if;
  if v_name_key is null or length(v_name) not between 2 and 120 then return private.appointment_result(false, 'cancel', 'INVALID_PATIENT_NAME', 'Please provide the patient name.'); end if;
  if v_phone is null then return private.appointment_result(false, 'cancel', 'INVALID_PHONE_E164', 'Please provide the phone number with its country code.'); end if;
  if p_existing_appointment_time is null then return private.appointment_result(false, 'cancel', 'INVALID_APPOINTMENT_TIME', 'Please provide the appointment date and time.'); end if;
  if p_source not in ('ai_agent', 'staff', 'system') then return private.appointment_result(false, 'cancel', 'INVALID_SOURCE', 'Unable to process that request.'); end if;
  select * into v_doctor from private.resolve_active_doctor(p_doctor_name);
  if v_doctor.id is null then return private.appointment_result(false, 'cancel', 'DOCTOR_NOT_FOUND_OR_INACTIVE', 'That doctor is not available.'); end if;
  select b.* into v_booking from public.bookings b
  where b.doctor_id = v_doctor.id and b.appointment_time = p_existing_appointment_time and b.status = 'confirmed'
    and private.normalized_patient_name(b.patient_name_snapshot) = v_name_key and b.phone_e164_snapshot = v_phone
  for update;
  if v_booking.id is null then return private.appointment_result(false, 'cancel', 'BOOKING_NOT_FOUND', 'I could not find that exact confirmed appointment.'); end if;
  if p_source = 'ai_agent' and v_booking.appointment_time <= clock_timestamp() then
    return private.appointment_result(false, 'cancel', 'APPOINTMENT_ALREADY_STARTED', 'This appointment has already started and cannot be changed by phone.');
  end if;
  update public.bookings set status = 'cancelled', updated_at = now() where id = v_booking.id;
  insert into public.appointment_events (booking_id, action, source, platform_call_id, idempotency_key, details)
  values (v_booking.id, 'cancelled', p_source, nullif(btrim(p_platform_call_id), ''), p_idempotency_key, '{}'::jsonb);
  v_result := private.appointment_result(true, 'cancel', null, 'Appointment cancelled.', v_booking.id, null, v_booking.patient_name_snapshot, v_booking.phone_e164_snapshot, v_doctor.name, v_booking.appointment_time, null, 'cancelled');
  perform private.store_operation('cancel', p_idempotency_key, v_fingerprint, v_booking.id, null, v_result);
  return v_result;
end;
$function$;

CREATE OR REPLACE FUNCTION public.reschedule_appointment_v2(p_patient_name text, p_phone_e164 text, p_doctor_name text, p_existing_appointment_time timestamp with time zone, p_new_appointment_time timestamp with time zone, p_idempotency_key uuid, p_platform_call_id text DEFAULT NULL::text, p_source text DEFAULT 'ai_agent'::text, p_booking_window_days integer DEFAULT 7)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public', 'private'
AS $function$
declare
  v_name text := private.display_patient_name(p_patient_name);
  v_name_key text := private.normalized_patient_name(p_patient_name);
  v_phone text := private.canonical_e164(p_phone_e164);
  v_fingerprint text; v_replay jsonb; v_result jsonb;
  v_doctor public.doctors%rowtype; v_old public.bookings%rowtype; v_new public.bookings%rowtype;
  v_error text;
begin
  v_fingerprint := md5(concat_ws('|', v_name_key, coalesce(v_phone, ''), lower(btrim(p_doctor_name)), coalesce(p_existing_appointment_time::text, ''), coalesce(p_new_appointment_time::text, ''), coalesce(p_source, '')));
  v_replay := private.operation_replay_or_lock('reschedule', p_idempotency_key, v_fingerprint);
  if v_replay is not null then return v_replay; end if;
  if v_name_key is null or length(v_name) not between 2 and 120 then return private.appointment_result(false, 'reschedule', 'INVALID_PATIENT_NAME', 'Please provide the patient name.'); end if;
  if v_phone is null then return private.appointment_result(false, 'reschedule', 'INVALID_PHONE_E164', 'Please provide the phone number with its country code.'); end if;
  if p_existing_appointment_time is null or p_new_appointment_time is null then return private.appointment_result(false, 'reschedule', 'INVALID_APPOINTMENT_TIME', 'Please provide both appointment date and times.'); end if;
  if p_new_appointment_time = p_existing_appointment_time then return private.appointment_result(false, 'reschedule', 'SAME_APPOINTMENT_TIME', 'Please choose a different appointment time.'); end if;
  if p_source not in ('ai_agent', 'staff', 'system') then return private.appointment_result(false, 'reschedule', 'INVALID_SOURCE', 'Unable to process that request.'); end if;
  select * into v_doctor from private.resolve_active_doctor(p_doctor_name);
  if v_doctor.id is null then return private.appointment_result(false, 'reschedule', 'DOCTOR_NOT_FOUND_OR_INACTIVE', 'That doctor is not available.'); end if;
  select b.* into v_old from public.bookings b
  where b.doctor_id = v_doctor.id and b.appointment_time = p_existing_appointment_time and b.status = 'confirmed'
    and private.normalized_patient_name(b.patient_name_snapshot) = v_name_key and b.phone_e164_snapshot = v_phone
  for update;
  if v_old.id is null then return private.appointment_result(false, 'reschedule', 'BOOKING_NOT_FOUND', 'I could not find that exact confirmed appointment.'); end if;
  v_error := private.validate_appointment_slot(v_doctor, p_new_appointment_time, p_booking_window_days);
  if v_error is not null then return private.appointment_result(false, 'reschedule', v_error, 'That new appointment time is not available.'); end if;
  if exists (select 1 from public.bookings b where b.doctor_id = v_doctor.id and b.appointment_time = p_new_appointment_time and b.status = 'confirmed') then return private.appointment_result(false, 'reschedule', 'SLOT_TAKEN', 'That slot was just taken. Please choose another time.'); end if;
  if p_source = 'ai_agent' and v_old.appointment_time <= clock_timestamp() then
    return private.appointment_result(false, 'reschedule', 'APPOINTMENT_ALREADY_STARTED', 'This appointment has already started and cannot be changed by phone.');
  end if;
  begin
    insert into public.bookings (patient_id, doctor_id, appointment_time, status, source, patient_name_snapshot, phone_e164_snapshot, platform_call_id, updated_at)
    values (v_old.patient_id, v_doctor.id, p_new_appointment_time, 'confirmed', p_source, v_old.patient_name_snapshot, v_old.phone_e164_snapshot, nullif(btrim(p_platform_call_id), ''), now())
    returning * into v_new;
  exception when unique_violation then return private.appointment_result(false, 'reschedule', 'SLOT_TAKEN', 'That slot was just taken. Please choose another time.'); end;
  update public.bookings set status = 'rescheduled', rescheduled_to_booking_id = v_new.id, updated_at = now() where id = v_old.id;
  insert into public.appointment_events (booking_id, related_booking_id, action, source, platform_call_id, idempotency_key, details) values
    (v_old.id, v_new.id, 'rescheduled', p_source, nullif(btrim(p_platform_call_id), ''), p_idempotency_key, jsonb_build_object('direction', 'from')),
    (v_new.id, v_old.id, 'created', p_source, nullif(btrim(p_platform_call_id), ''), p_idempotency_key, jsonb_build_object('rescheduled_from_booking_id', v_old.id));
  v_result := private.appointment_result(true, 'reschedule', null, 'Appointment rescheduled.', v_new.id, v_old.id, v_old.patient_name_snapshot, v_old.phone_e164_snapshot, v_doctor.name, v_new.appointment_time, v_old.appointment_time, 'confirmed');
  perform private.store_operation('reschedule', p_idempotency_key, v_fingerprint, v_new.id, v_old.id, v_result);
  return v_result;
end;
$function$;

-- Demo doctors: same names, specialties, hours and days as the Nirva Hospital demo
update public.doctors set start_time = '10:00', end_time = '13:00', working_days = '1,2,3,4,5' where name = 'Dr. Ananya Sharma';
update public.doctors set start_time = '11:00', end_time = '15:00', working_days = '1,3,5' where name = 'Dr. Priya Nair';
update public.doctors set start_time = '13:00', end_time = '16:00', working_days = '3,5' where name = 'Dr. Raj Malhotra';

;

-- ######## 05_calls_sarvam.sql
-- Sarvam test project only. Run AFTER replaying the Vani migrations.
-- Adds Sarvam call-data columns to the existing calls table.
alter table public.calls
  add column if not exists platform text not null default 'sarvam',
  add column if not exists agent_phone_number text,
  add column if not exists deployment_id text,
  add column if not exists app_version integer,
  add column if not exists started_at timestamptz,
  add column if not exists ended_at timestamptz,
  add column if not exists transcript jsonb,            -- [{role, en_text, indic_text}]
  add column if not exists extracted_data jsonb,        -- output_agent_variables
  add column if not exists final_variables jsonb,       -- final_agent_variables
  add column if not exists recording_url text,          -- optional, from signed-URL setting
  add column if not exists updated_at timestamptz default now(),
  add column if not exists raw_payload jsonb;

create unique index if not exists calls_call_id_key on public.calls (call_id);

;
select 'ALL DONE sarvam' as status, (select count(*) from pg_tables where schemaname in ('public','private')) as tables;
