-- Live dashboard updates: let Supabase Realtime send booking, call and
-- callback changes to signed-in staff (row-level security still applies).
-- Run once per test project in the Supabase SQL editor.
do $$
declare t text;
begin
  foreach t in array array['bookings','callback_requests','calls'] loop
    if not exists (select 1 from pg_publication_tables
                   where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = t) then
      execute format('alter publication supabase_realtime add table public.%I', t);
    end if;
  end loop;
end $$;
