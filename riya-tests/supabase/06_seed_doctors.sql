-- Same 3 demo doctors, specialties, days and hours as the Nirva Hospital demo (Vani)
insert into public.doctors (name, specialty, active, start_time, end_time, working_days)
select v.* from (values
  ('Dr. Ananya Sharma', 'General Physician', true, time '10:00', time '13:00', '1,2,3,4,5'),
  ('Dr. Priya Nair',    'Pediatrics',        true, time '11:00', time '15:00', '1,3,5'),
  ('Dr. Raj Malhotra',  'Cardiology',        true, time '13:00', time '16:00', '3,5')
) as v(name, specialty, active, start_time, end_time, working_days)
where not exists (select 1 from public.doctors d where d.name = v.name);
select name, specialty, start_time, end_time, working_days from public.doctors order by name;
