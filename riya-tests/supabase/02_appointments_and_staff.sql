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
