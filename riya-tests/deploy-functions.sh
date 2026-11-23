#!/usr/bin/env bash
# Deploy Riya's Edge Functions to ONE test project.
# Usage: ./deploy-functions.sh bolna   or   ./deploy-functions.sh sarvam
# Needs: npx (Node), and `npx supabase login` done once with the NEW Supabase account.
# Secrets are generated once and kept OUTSIDE the repo in ~/.riya-test-secrets/<platform>.env
set -euo pipefail
PLATFORM="${1:?bolna or sarvam}"
case "$PLATFORM" in
  bolna)  REF=esvurkdwzcxtzimbpkwv; WEBHOOK=bolna-call-webhook;  SECRET_NAME=BOLNA_WEBHOOK_SECRET ;;
  sarvam) REF=wsqwgomduqehbtdiawcw; WEBHOOK=sarvam-call-webhook; SECRET_NAME=SARVAM_WEBHOOK_SECRET ;;
  *) echo "unknown platform $PLATFORM"; exit 1 ;;
esac
HERE="$(cd "$(dirname "$0")" && pwd)"
WORK="$(mktemp -d)"
mkdir -p "$WORK/supabase/functions"
for fn in check-availability book-appointment find-appointment-for-reschedule reschedule-appointment \
          cancel-appointment save-callback-request get-doctor-hours log-call \
          staff-book-appointment staff-appointment-action staff-complete-callback update-doctor-leave "$WEBHOOK"; do
  cp -R "$HERE/functions/$fn" "$WORK/supabase/functions/$fn"
done
{
  echo "project_id = \"nirva-riya-$PLATFORM-test\""
  for fn in check-availability book-appointment find-appointment-for-reschedule reschedule-appointment \
            cancel-appointment save-callback-request get-doctor-hours log-call "$WEBHOOK"; do
    printf '\n[functions.%s]\nverify_jwt = false\n' "$fn"
  done
  for fn in staff-book-appointment staff-appointment-action staff-complete-callback update-doctor-leave; do
    printf '\n[functions.%s]\nverify_jwt = true\n' "$fn"
  done
} > "$WORK/supabase/config.toml"

SECRETS_DIR="$HOME/.riya-test-secrets"; mkdir -p "$SECRETS_DIR"; chmod 700 "$SECRETS_DIR"
SECRETS_FILE="$SECRETS_DIR/$PLATFORM.env"
if [ ! -f "$SECRETS_FILE" ]; then
  echo "$SECRET_NAME=$(openssl rand -hex 24)" > "$SECRETS_FILE"
  chmod 600 "$SECRETS_FILE"
fi

cd "$WORK"
npx --yes supabase@latest functions deploy --project-ref "$REF" --use-api
npx --yes supabase@latest secrets set --project-ref "$REF" --env-file "$SECRETS_FILE"
npx --yes supabase@latest functions list --project-ref "$REF"
echo "Done: $PLATFORM ($REF). Tool secret is in $SECRETS_FILE"
