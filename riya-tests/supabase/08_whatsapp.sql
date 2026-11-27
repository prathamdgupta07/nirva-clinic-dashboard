-- WhatsApp confirmations and reminders (Meta WhatsApp Cloud API).
-- Run once in the Supabase SQL editor of the Sarvam test project, after 01-07.
-- Safe to run again.
--
-- How it works:
--   1. Riya or staff book / reschedule / cancel. That writes a row in
--      public.appointment_events.
--   2. A trigger turns that row into a queued WhatsApp message in
--      private.whatsapp_messages and pokes the `whatsapp-send` Edge Function.
--   3. The Edge Function sends queued messages through Meta and records the
--      result. A cron job every minute retries anything still waiting.
--   4. Every day at 18:00 India time a cron job queues reminders for
--      tomorrow's confirmed appointments.
-- Nothing is sent until private.whatsapp_settings.enabled = true.
-- A failure here can never block a booking: every step catches its errors.

create extension if not exists pg_net with schema extensions;
create schema if not exists private;

-- ---------------------------------------------------------------- settings
create table if not exists private.whatsapp_settings (
  id boolean primary key default true check (id),           -- single row
  enabled boolean not null default false,
  function_url text,                                        -- https://<ref>.supabase.co/functions/v1/whatsapp-send
  clinic_name text not null default 'Nirva Multi-Specialty Hospital',
  clinic_address text,                                      -- optional; shown as "Address:"
  clinic_phone text,                                        -- number patients call to change a visit
  template_language text not null default 'en',
  time_zone text not null default 'Asia/Kolkata',
  updated_at timestamptz not null default now()
);
insert into private.whatsapp_settings (id) values (true) on conflict (id) do nothing;
alter table private.whatsapp_settings enable row level security;

-- ------------------------------------------------------------------ queue
create table if not exists private.whatsapp_messages (
  id uuid primary key default gen_random_uuid(),
  booking_id uuid not null references public.bookings(id) on delete cascade,
  kind text not null check (kind in ('confirmation','reschedule','cancellation','reminder')),
  to_e164 text not null,
  template_name text not null,
  template_language text not null,
  params jsonb not null check (jsonb_typeof(params) = 'array'),
  status text not null default 'pending'
    check (status in ('pending','sending','sent','failed','skipped')),
  attempts integer not null default 0,
  next_attempt_at timestamptz not null default now(),
  last_error text,
  meta_message_id text,
  created_at timestamptz not null default now(),
  sent_at timestamptz,
  unique (booking_id, kind)
);
create index if not exists whatsapp_messages_pending_idx
  on private.whatsapp_messages (next_attempt_at) where status = 'pending';
alter table private.whatsapp_messages enable row level security;

-- ------------------------------------------------------- message building
create or replace function private.whatsapp_fmt_date(p_ts timestamptz, p_tz text)
returns text language sql immutable set search_path = pg_catalog as $$
  select to_char(p_ts at time zone p_tz, 'Dy, FMDD Mon YYYY');
$$;

create or replace function private.whatsapp_fmt_time(p_ts timestamptz, p_tz text)
returns text language sql immutable set search_path = pg_catalog as $$
  select to_char(p_ts at time zone p_tz, 'FMHH12:MI AM');
$$;

create or replace function private.whatsapp_fmt_phone(p_e164 text)
returns text language sql immutable set search_path = pg_catalog as $$
  select case when p_e164 ~ '^\+91[0-9]{10}$'
              then '+91 ' || substr(p_e164, 4, 5) || ' ' || substr(p_e164, 9, 5)
              else p_e164 end;
$$;

-- Queue one message for a booking. Returns true when a new row was queued.
create or replace function private.whatsapp_enqueue(p_booking_id uuid, p_kind text)
returns boolean
language plpgsql security definer
set search_path = pg_catalog, public, private
as $$
declare
  s private.whatsapp_settings%rowtype;
  b public.bookings%rowtype;
  v_doctor text;
  v_name text;
  v_phone text;
  v_old_time timestamptz;
  v_address text;
  v_call text;
  v_params jsonb;
  v_template text;
begin
  select * into s from private.whatsapp_settings where id;
  if not found or not s.enabled then return false; end if;

  select * into b from public.bookings where id = p_booking_id;
  if not found then return false; end if;

  v_phone := coalesce(b.phone_e164_snapshot, (select phone_e164 from public.patients where id = b.patient_id));
  if v_phone is null or v_phone !~ '^\+[1-9][0-9]{6,14}$' then return false; end if;

  v_name := coalesce(nullif(btrim(b.patient_name_snapshot), ''),
                     (select name from public.patients where id = b.patient_id), 'Patient');
  select name into v_doctor from public.doctors where id = b.doctor_id;
  v_doctor := coalesce(v_doctor, 'our doctor');
  v_address := coalesce(nullif(btrim(s.clinic_address), ''), s.clinic_name);
  v_call := coalesce(nullif(btrim(s.clinic_phone), ''), 'the clinic');

  if p_kind = 'confirmation' then
    v_template := 'appointment_confirmation';
    v_params := jsonb_build_array(s.clinic_name, v_name, private.whatsapp_fmt_phone(v_phone), v_doctor,
      private.whatsapp_fmt_date(b.appointment_time, s.time_zone),
      private.whatsapp_fmt_time(b.appointment_time, s.time_zone), v_address, v_call);
  elsif p_kind = 'reschedule' then
    select o.appointment_time into v_old_time
    from public.bookings o where o.rescheduled_to_booking_id = b.id limit 1;
    v_template := 'appointment_rescheduled';
    v_params := jsonb_build_array(s.clinic_name, v_name, private.whatsapp_fmt_phone(v_phone), v_doctor,
      private.whatsapp_fmt_date(b.appointment_time, s.time_zone),
      private.whatsapp_fmt_time(b.appointment_time, s.time_zone), v_address,
      coalesce(private.whatsapp_fmt_date(v_old_time, s.time_zone) || ' at '
               || private.whatsapp_fmt_time(v_old_time, s.time_zone), 'your earlier time'),
      v_call);
  elsif p_kind = 'cancellation' then
    v_template := 'appointment_cancelled';
    v_params := jsonb_build_array(s.clinic_name, v_name, v_doctor,
      private.whatsapp_fmt_date(b.appointment_time, s.time_zone),
      private.whatsapp_fmt_time(b.appointment_time, s.time_zone), v_call);
  elsif p_kind = 'reminder' then
    v_template := 'appointment_reminder';
    v_params := jsonb_build_array(s.clinic_name, v_name, private.whatsapp_fmt_phone(v_phone), v_doctor,
      private.whatsapp_fmt_date(b.appointment_time, s.time_zone),
      private.whatsapp_fmt_time(b.appointment_time, s.time_zone), v_address, v_call);
  else
    return false;
  end if;

  insert into private.whatsapp_messages (booking_id, kind, to_e164, template_name, template_language, params)
  values (b.id, p_kind, v_phone, v_template, s.template_language, v_params)
  on conflict (booking_id, kind) do nothing;
  return found;
end $$;

-- Ask the Edge Function to send whatever is queued (fire and forget).
create or replace function private.whatsapp_kick()
returns void
language plpgsql security definer
set search_path = pg_catalog, public, private, extensions
as $$
declare v_url text;
begin
  select function_url into v_url from private.whatsapp_settings where id and enabled;
  if v_url is null then return; end if;
  if not exists (select 1 from private.whatsapp_messages
                 where status = 'pending' and next_attempt_at <= now() + interval '5 seconds') then
    return;
  end if;
  perform net.http_post(url := v_url, body := '{}'::jsonb,
                        headers := '{"Content-Type":"application/json"}'::jsonb,
                        timeout_milliseconds := 20000);
exception when others then
  raise warning 'whatsapp_kick failed: %', sqlerrm;
end $$;

-- ----------------------------------------------------------- the trigger
create or replace function private.whatsapp_on_appointment_event()
returns trigger
language plpgsql security definer
set search_path = pg_catalog, public, private
as $$
declare v_kind text;
begin
  if new.action = 'created' and new.details ? 'rescheduled_from_booking_id' then
    v_kind := 'reschedule';
  elsif new.action = 'created' then
    v_kind := 'confirmation';
  elsif new.action = 'cancelled' then
    v_kind := 'cancellation';
  else
    return null;                   -- arrived, completed, no_show, reopen: no message
  end if;
  if private.whatsapp_enqueue(new.booking_id, v_kind) then
    perform private.whatsapp_kick();
  end if;
  return null;
exception when others then
  raise warning 'whatsapp trigger skipped for booking %: %', new.booking_id, sqlerrm;
  return null;
end $$;

drop trigger if exists whatsapp_on_appointment_event on public.appointment_events;
create trigger whatsapp_on_appointment_event
  after insert on public.appointment_events
  for each row execute function private.whatsapp_on_appointment_event();

-- -------------------------------------------------------------- reminders
-- Queue a reminder for every confirmed appointment tomorrow (India time).
create or replace function private.whatsapp_queue_reminders()
returns integer
language plpgsql security definer
set search_path = pg_catalog, public, private
as $$
declare
  v_tz text; v_count integer := 0; r record;
begin
  select time_zone into v_tz from private.whatsapp_settings where id and enabled;
  if v_tz is null then return 0; end if;
  for r in
    select id from public.bookings
    where status = 'confirmed'
      and (appointment_time at time zone v_tz)::date = (now() at time zone v_tz)::date + 1
  loop
    if private.whatsapp_enqueue(r.id, 'reminder') then v_count := v_count + 1; end if;
  end loop;
  perform private.whatsapp_kick();
  return v_count;
end $$;

-- ------------------------------------------- RPCs used by the Edge Function
-- Only the service role (the Edge Function) may call these.
create or replace function public.whatsapp_claim_batch(p_limit integer default 20)
returns table (id uuid, kind text, to_e164 text, template_name text, template_language text, params jsonb)
language plpgsql security definer
set search_path = pg_catalog, public, private
as $$
#variable_conflict use_column
begin
  -- A reminder or confirmation for a booking that is no longer confirmed is skipped.
  update private.whatsapp_messages m
     set status = 'skipped', last_error = 'booking no longer confirmed'
    from public.bookings b
   where b.id = m.booking_id and m.status = 'pending'
     and m.kind in ('reminder','confirmation','reschedule') and b.status <> 'confirmed';

  -- Rows stuck in "sending" for 10 minutes (function crashed) go back to the queue.
  update private.whatsapp_messages
     set status = 'pending'
   where status = 'sending' and next_attempt_at < now() - interval '10 minutes';

  return query
  with picked as (
    select m.id from private.whatsapp_messages m
     where m.status = 'pending' and m.next_attempt_at <= now()
     order by m.created_at
     limit greatest(1, least(p_limit, 50))
     for update skip locked
  )
  update private.whatsapp_messages m
     set status = 'sending', attempts = m.attempts + 1, next_attempt_at = now()
    from picked
   where m.id = picked.id
  returning m.id, m.kind, m.to_e164, m.template_name, m.template_language, m.params;
end $$;

create or replace function public.whatsapp_mark_result(
  p_id uuid, p_ok boolean, p_meta_message_id text default null,
  p_error text default null, p_permanent boolean default false)
returns void
language plpgsql security definer
set search_path = pg_catalog, public, private
as $$
begin
  if p_ok then
    update private.whatsapp_messages
       set status = 'sent', sent_at = now(), meta_message_id = p_meta_message_id, last_error = null
     where id = p_id and status = 'sending';
  else
    update private.whatsapp_messages
       set status = case when p_permanent or attempts >= 3 then 'failed' else 'pending' end,
           next_attempt_at = now() + make_interval(mins => power(2, attempts)::int),
           last_error = left(p_error, 1000)
     where id = p_id and status = 'sending';
  end if;
end $$;

revoke all on function public.whatsapp_claim_batch(integer) from public, anon, authenticated;
revoke all on function public.whatsapp_mark_result(uuid, boolean, text, text, boolean) from public, anon, authenticated;
grant execute on function public.whatsapp_claim_batch(integer) to service_role;
grant execute on function public.whatsapp_mark_result(uuid, boolean, text, text, boolean) to service_role;
revoke all on function private.whatsapp_enqueue(uuid, text) from public, anon, authenticated;
revoke all on function private.whatsapp_kick() from public, anon, authenticated;
revoke all on function private.whatsapp_queue_reminders() from public, anon, authenticated;

-- ---------------------------------------------------------------- cron jobs
do $$
begin
  perform cron.unschedule(jobname) from cron.job
   where jobname in ('whatsapp-retry', 'whatsapp-daily-reminders');
  perform cron.schedule('whatsapp-retry', '* * * * *', 'select private.whatsapp_kick()');
  -- 12:30 UTC = 18:00 India time
  perform cron.schedule('whatsapp-daily-reminders', '30 12 * * *', 'select private.whatsapp_queue_reminders()');
end $$;

select 'whatsapp ok' as status;
