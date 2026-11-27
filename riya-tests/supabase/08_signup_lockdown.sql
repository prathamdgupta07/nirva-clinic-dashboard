-- 08_signup_lockdown.sql  (27 Nov 2026)
-- Problem: public sign-up was on, and every new account was automatically
-- given role 'staff'. Anyone who knew the dashboard address could create an
-- account with their own email and see every patient, booking and callback.
--
-- Fix (database side): new accounts now start as 'pending' and see nothing.
-- An owner must change the role to 'staff' (or link a doctor) by hand in
-- Supabase > Table Editor > profiles. Existing accounts keep their roles.
-- Also turn OFF "Allow new users to sign up" in Supabase > Authentication >
-- Sign In / Providers. New staff are then added with "Invite user".
--
-- Safe to run more than once.

alter table public.profiles alter column role set default 'pending';

create or replace function public.handle_new_user()
returns trigger
language plpgsql
security definer
set search_path to 'public'
as $function$
begin
  insert into public.profiles (id, full_name, role)
  values (new.id, new.raw_user_meta_data->>'full_name', 'pending');
  return new;
end;
$function$;

revoke execute on function public.handle_new_user() from public, anon, authenticated;

-- Check: lists every account and its role. Any role you do not recognise
-- should be investigated.
select u.email, p.role, u.created_at
from auth.users u left join public.profiles p on p.id = u.id
order by u.created_at;
