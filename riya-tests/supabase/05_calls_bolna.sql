-- Bolna test project only. Run AFTER replaying the Vani migrations.
-- Adds Bolna call-data columns to the existing calls table.
alter table public.calls
  add column if not exists platform text not null default 'bolna',
  add column if not exists status text,                 -- Bolna status: completed, failed, no-answer...
  add column if not exists termination_reason text,     -- user_hung_up, agent_ended_call, ...
  add column if not exists hangup_by text,
  add column if not exists to_number text,
  add column if not exists call_type text,              -- inbound / outbound
  add column if not exists transcript text,
  add column if not exists summary text,
  add column if not exists recording_url text,
  add column if not exists total_cost numeric,          -- unit to confirm on first call (cents vs dollars)
  add column if not exists cost_breakdown jsonb,
  add column if not exists extracted_data jsonb,
  add column if not exists started_at timestamptz,
  add column if not exists updated_at timestamptz default now(),
  add column if not exists raw_payload jsonb;

create unique index if not exists calls_call_id_key on public.calls (call_id);
