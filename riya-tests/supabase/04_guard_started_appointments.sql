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
