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
