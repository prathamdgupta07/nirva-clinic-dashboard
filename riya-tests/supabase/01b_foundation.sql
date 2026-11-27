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

select 'foundation ok' as status;
