-- Riya test projects (Bolna / Sarvam): replay of Vani project migrations 1-17
-- (initial_schema .. lock_availability_function_search_path). Comments trimmed.
create extension if not exists pgcrypto;

create table doctors (
  id uuid primary key default gen_random_uuid(),
  name text not null,
  specialty text,
  active boolean not null default true
);

create table patients (
  id uuid primary key default gen_random_uuid(),
  name text not null,
  phone text,
  email text
);

create table bookings (
  id uuid primary key default gen_random_uuid(),
  patient_id uuid not null references patients(id),
  doctor_id uuid not null references doctors(id),
  appointment_time timestamptz not null,
  status text not null default 'confirmed',
  source text not null,
  created_at timestamptz not null default now(),
  tool_call_id text,
  calendar_event_id text
);

create unique index bookings_no_double_book
  on bookings (doctor_id, appointment_time)
  where (status = 'confirmed');

create table calls (
  id uuid primary key default gen_random_uuid(),
  call_id text,
  patient_id uuid references patients(id),
  phone_number text,
  outcome text,
  duration_seconds integer,
  created_at timestamptz not null default now(),
  callback_done boolean not null default false,
  caller_name text
);

-- auth_and_rls
create table profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  full_name text,
  role text not null default 'staff'
);

create or replace function public.handle_new_user()
returns trigger
language plpgsql
security definer
set search_path to 'public'
as $function$
begin
  insert into public.profiles (id, full_name, role)
  values (new.id, new.raw_user_meta_data->>'full_name', 'staff');
  return new;
end;
$function$;

create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function handle_new_user();

alter table doctors enable row level security;
alter table patients enable row level security;
alter table bookings enable row level security;
alter table calls enable row level security;
alter table profiles enable row level security;

create policy "staff can view doctors" on doctors for select
  using (exists (select 1 from profiles where profiles.id = auth.uid()));
create policy "staff can manage doctors" on doctors for all
  using (exists (select 1 from profiles where profiles.id = auth.uid()))
  with check (exists (select 1 from profiles where profiles.id = auth.uid()));
create policy "staff can view patients" on patients for select
  using (exists (select 1 from profiles where profiles.id = auth.uid()));
create policy "staff can manage patients" on patients for all
  using (exists (select 1 from profiles where profiles.id = auth.uid()))
  with check (exists (select 1 from profiles where profiles.id = auth.uid()));
create policy "staff can view bookings" on bookings for select
  using (exists (select 1 from profiles where profiles.id = auth.uid()));
create policy "staff can manage bookings" on bookings for all
  using (exists (select 1 from profiles where profiles.id = auth.uid()))
  with check (exists (select 1 from profiles where profiles.id = auth.uid()));
create policy "staff can view calls" on calls for select
  using (exists (select 1 from profiles where profiles.id = auth.uid()));
create policy "staff can manage calls" on calls for all
  using (exists (select 1 from profiles where profiles.id = auth.uid()))
  with check (exists (select 1 from profiles where profiles.id = auth.uid()));
create policy "user can view own profile" on profiles for select
  using (id = auth.uid());

-- add_login_history
create table public.login_history (
  id uuid primary key default gen_random_uuid(),
  user_id uuid references public.profiles(id) on delete cascade,
  login_time timestamptz not null default now(),
  ip_address text
);
alter table public.login_history enable row level security;
create policy "staff can view login history"
  on public.login_history for select
  using (exists (select 1 from public.profiles where profiles.id = auth.uid()));
create policy "staff can insert own login history"
  on public.login_history for insert
  with check (user_id = auth.uid());

-- add_doctor_working_hours
alter table public.doctors
  add column start_time time not null default '09:00',
  add column end_time time not null default '18:00';

-- add_doctor_schedule_changes
create table public.doctor_schedule_changes (
  id uuid primary key default gen_random_uuid(),
  doctor_id uuid not null references public.doctors(id) on delete cascade,
  new_start_time time not null,
  new_end_time time not null,
  effective_from timestamptz not null,
  applied boolean not null default false,
  created_at timestamptz not null default now(),
  constraint valid_time_range check (new_start_time < new_end_time)
);
create index idx_doctor_schedule_changes_due
  on public.doctor_schedule_changes (effective_from)
  where applied = false;
alter table public.doctor_schedule_changes enable row level security;
create policy "staff can view schedule changes"
  on public.doctor_schedule_changes for select
  using (exists (select 1 from public.profiles where profiles.id = auth.uid()));
create policy "staff can manage schedule changes"
  on public.doctor_schedule_changes for all
  using (exists (select 1 from public.profiles where profiles.id = auth.uid()))
  with check (exists (select 1 from public.profiles where profiles.id = auth.uid()));

-- enable_pg_cron
create extension if not exists pg_cron with schema extensions;

-- add_apply_schedule_changes_function
create or replace function public.apply_due_doctor_schedule_changes()
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  update public.doctors d
  set start_time = c.new_start_time,
      end_time   = c.new_end_time
  from public.doctor_schedule_changes c
  where c.doctor_id = d.id
    and c.applied = false
    and c.effective_from <= now();

  update public.doctor_schedule_changes
  set applied = true
  where applied = false
    and effective_from <= now();
end;
$$;

select cron.schedule(
  'apply-doctor-schedule-changes',
  '*/2 * * * *',
  $$select public.apply_due_doctor_schedule_changes();$$
);

revoke execute on function public.apply_due_doctor_schedule_changes() from anon, authenticated;

-- add_working_days_to_doctors
alter table doctors add column if not exists working_days text;

-- doctor_login_leave_callbacks_schema
alter table doctors add column if not exists user_id uuid references auth.users(id);

create table if not exists doctor_leave (
  id uuid primary key default gen_random_uuid(),
  doctor_id uuid not null references doctors(id),
  leave_start_date date not null,
  leave_end_date date not null,
  reason text,
  created_by uuid references auth.users(id),
  created_at timestamptz not null default now()
);

create table if not exists callback_requests (
  id uuid primary key default gen_random_uuid(),
  caller_name text not null,
  doctor_id uuid references doctors(id),
  phone_number text not null,
  status text not null default 'pending',
  created_by uuid references auth.users(id),
  created_at timestamptz not null default now(),
  contacted_by uuid references auth.users(id),
  contacted_at timestamptz
);

alter table doctor_schedule_changes add column if not exists created_by uuid references auth.users(id);
alter table bookings add column if not exists updated_by uuid references auth.users(id);
alter table bookings add column if not exists updated_at timestamptz;
alter table bookings add column if not exists rescheduled_to_booking_id uuid references bookings(id);

-- rls_role_aware_policies_and_new_tables
create schema if not exists private;

create or replace function private.is_staff()
returns boolean
language plpgsql
security definer
set search_path = ''
as $$
begin
  return exists (
    select 1 from public.profiles
    where profiles.id = (select auth.uid()) and profiles.role = 'staff'
  );
end;
$$;

create or replace function private.is_own_doctor(target_doctor_id uuid)
returns boolean
language plpgsql
security definer
set search_path = ''
as $$
begin
  return exists (
    select 1 from public.doctors
    where doctors.id = target_doctor_id and doctors.user_id = (select auth.uid())
  );
end;
$$;

create or replace function private.is_any_doctor()
returns boolean
language plpgsql
security definer
set search_path = ''
as $$
begin
  return exists (select 1 from public.doctors where doctors.user_id = (select auth.uid()));
end;
$$;

drop policy "staff can manage bookings" on bookings;
create policy "staff can manage bookings" on bookings for all
  using (private.is_staff()) with check (private.is_staff());
drop policy "staff can view bookings" on bookings;
create policy "staff can view bookings" on bookings for select using (private.is_staff());
drop policy "staff can manage calls" on calls;
create policy "staff can manage calls" on calls for all
  using (private.is_staff()) with check (private.is_staff());
drop policy "staff can view calls" on calls;
create policy "staff can view calls" on calls for select using (private.is_staff());
drop policy "staff can manage doctors" on doctors;
create policy "staff can manage doctors" on doctors for all
  using (private.is_staff()) with check (private.is_staff());
drop policy "staff can view doctors" on doctors;
create policy "staff can view doctors" on doctors for select using (private.is_staff());
drop policy "staff can view login history" on login_history;
create policy "staff can view login history" on login_history for select using (private.is_staff());
drop policy "staff can manage patients" on patients;
create policy "staff can manage patients" on patients for all
  using (private.is_staff()) with check (private.is_staff());
drop policy "staff can view patients" on patients;
create policy "staff can view patients" on patients for select using (private.is_staff());

drop policy "staff can manage schedule changes" on doctor_schedule_changes;
drop policy "staff can view schedule changes" on doctor_schedule_changes;
create policy "staff can view schedule changes" on doctor_schedule_changes for select
  using (private.is_staff());
create policy "doctor can manage own schedule changes" on doctor_schedule_changes for all
  using (private.is_own_doctor(doctor_id)) with check (private.is_own_doctor(doctor_id));

create policy "doctor can view bookings" on bookings for select using (private.is_any_doctor());
create policy "doctor can view doctors" on doctors for select using (private.is_any_doctor());
create policy "doctor can view patients" on patients for select using (private.is_any_doctor());
create policy "doctor can view calls" on calls for select using (private.is_any_doctor());

alter table doctor_leave enable row level security;
create policy "staff can view doctor leave" on doctor_leave for select using (private.is_staff());
create policy "doctor can manage own leave" on doctor_leave for all
  using (private.is_own_doctor(doctor_id)) with check (private.is_own_doctor(doctor_id));

alter table callback_requests enable row level security;
create policy "staff can view callbacks" on callback_requests for select using (private.is_staff());
create policy "staff can insert callbacks" on callback_requests for insert with check (private.is_staff());
create policy "staff can update callbacks" on callback_requests for update using (private.is_staff());

revoke execute on function public.apply_due_doctor_schedule_changes() from anon, authenticated;
revoke execute on function public.handle_new_user() from anon, authenticated;

-- revoke_public_execute_on_sensitive_functions
revoke execute on function public.apply_due_doctor_schedule_changes() from public;
revoke execute on function public.handle_new_user() from public;

-- drop_dead_calendar_event_id_add_logout_tracking
alter table public.bookings drop column if exists calendar_event_id;
alter table public.login_history add column if not exists logout_time timestamptz null;
create policy "user can view own login history row"
  on public.login_history for select to authenticated
  using (user_id = auth.uid());
create policy "user can update own login history row"
  on public.login_history for update to authenticated
  using (user_id = auth.uid()) with check (user_id = auth.uid());

-- add_reason_to_callback_requests
alter table public.callback_requests add column if not exists reason text null;

-- add_get_availability_context_function
create or replace function public.get_availability_context(doctor_surname text)
returns json
language sql
stable
as $$
  select json_build_object(
    'doctors', (
      select coalesce(json_agg(row_to_json(d)), '[]'::json)
      from doctors d
      where d.name ilike '%' || doctor_surname || '%'
    ),
    'leave', (
      select coalesce(json_agg(row_to_json(l)), '[]'::json)
      from doctor_leave l
    ),
    'bookings', (
      select coalesce(json_agg(row_to_json(b)), '[]'::json)
      from bookings b
      where b.status = 'confirmed'
        and b.appointment_time >= now()
        and b.appointment_time <= now() + interval '35 days'
    )
  );
$$;
grant execute on function public.get_availability_context(text) to anon, authenticated, service_role;
alter function public.get_availability_context(text) set search_path = public, pg_temp;
