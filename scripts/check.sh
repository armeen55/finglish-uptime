#!/usr/bin/env bash
# scripts/uptime/check.sh: the production health check run by .github/workflows/uptime.yml (also fine to run by hand).
#
#   SUPABASE_ANON_KEY=... bash scripts/uptime/check.sh
#
# Every check is a read, or a POST that is rejected before anything is written:
#   GET  /                      200 and the page contains "Finglish"
#   GET  /robots.txt            200
#   GET  /sitemap.xml           200
#   GET  /llms.txt              200
#   GET  Supabase auth health   200 (needs the PUBLIC anon key in an `apikey` header)
#   POST /api/email-signup {}   400 (route + validation are up; the body is invalid so no row is written)
#   POST /api/client-error {}   200 (route is up; an empty report is acknowledged and ignored)
# A failed check is retried ONCE after RETRY_DELAY seconds; only a check that fails twice fails the run.
# Secrets are never printed: the key goes to curl through a config file descriptor, not argv, and no response body is echoed.
set -u

BASE_URL="${UPTIME_BASE_URL:-https://tryfinglish.com}"
SUPABASE_URL="${UPTIME_SUPABASE_URL:-https://qzwyvpqrvumuqkbmdxho.supabase.co}"
RETRY_DELAY="${UPTIME_RETRY_DELAY:-30}"
CONNECT_TIMEOUT=10
MAX_TIME=20
UA="finglish-uptime-check/1 (+github-actions)"

BODY_FILE="$(mktemp)"
trap 'rm -f "$BODY_FILE"' EXIT

if [ -z "${SUPABASE_ANON_KEY:-}" ]; then
  echo "::error title=Uptime check misconfigured::The repository secret SUPABASE_ANON_KEY is missing, so the Supabase auth health check cannot run. Add it under GitHub > Settings > Secrets and variables > Actions."
  echo "SUPABASE_ANON_KEY is not set" >&2
  exit 2
fi

# Check ids, in order. Each is defined in run_check below.
CHECKS=(home robots sitemap llms supabase_auth email_signup client_error)

# run_check <id>: prints one line, returns 0 when the check passes.
run_check() {
  local id="$1" want url code=""
  case "$id" in
    home)
      want=200; url="$BASE_URL/"
      code="$(curl -sS -L --connect-timeout $CONNECT_TIMEOUT --max-time $MAX_TIME -A "$UA" -o "$BODY_FILE" -w '%{http_code}' "$url" 2>/dev/null)" || code="000"
      if [ "$code" = "$want" ] && ! grep -q "Finglish" "$BODY_FILE"; then echo "GET / answered 200 but the page does not contain \"Finglish\""; return 1; fi
      ;;
    robots)  want=200; url="$BASE_URL/robots.txt";  code="$(curl -sS -L --connect-timeout $CONNECT_TIMEOUT --max-time $MAX_TIME -A "$UA" -o /dev/null -w '%{http_code}' "$url" 2>/dev/null)" || code="000" ;;
    sitemap) want=200; url="$BASE_URL/sitemap.xml"; code="$(curl -sS -L --connect-timeout $CONNECT_TIMEOUT --max-time $MAX_TIME -A "$UA" -o /dev/null -w '%{http_code}' "$url" 2>/dev/null)" || code="000" ;;
    llms)    want=200; url="$BASE_URL/llms.txt";    code="$(curl -sS -L --connect-timeout $CONNECT_TIMEOUT --max-time $MAX_TIME -A "$UA" -o /dev/null -w '%{http_code}' "$url" 2>/dev/null)" || code="000" ;;
    supabase_auth)
      want=200; url="$SUPABASE_URL/auth/v1/health"
      # The key rides in a curl config read from a descriptor, so it never appears in argv or the log.
      code="$(curl -sS --connect-timeout $CONNECT_TIMEOUT --max-time $MAX_TIME -A "$UA" -o /dev/null -w '%{http_code}' \
        --config <(printf 'header = "apikey: %s"\n' "$SUPABASE_ANON_KEY") "$url" 2>/dev/null)" || code="000"
      ;;
    email_signup)
      want=400; url="$BASE_URL/api/email-signup"
      code="$(curl -sS --connect-timeout $CONNECT_TIMEOUT --max-time $MAX_TIME -A "$UA" -o /dev/null -w '%{http_code}' \
        -X POST -H 'content-type: application/json' --data '{}' "$url" 2>/dev/null)" || code="000"
      ;;
    client_error)
      want=200; url="$BASE_URL/api/client-error"
      code="$(curl -sS --connect-timeout $CONNECT_TIMEOUT --max-time $MAX_TIME -A "$UA" -o /dev/null -w '%{http_code}' \
        -X POST -H 'content-type: application/json' --data '{}' "$url" 2>/dev/null)" || code="000"
      ;;
    *) echo "unknown check $id"; return 1 ;;
  esac
  if [ "$code" = "$want" ]; then echo "ok   $id ($code)"; return 0; fi
  echo "FAIL $id: expected $want, got $code ($url)"
  return 1
}

FAILED=()
for id in "${CHECKS[@]}"; do
  if out="$(run_check "$id")"; then echo "$out"; else echo "$out"; FAILED+=("$id"); fi
done

if [ "${#FAILED[@]}" -gt 0 ]; then
  echo "First pass failed: ${FAILED[*]}. Retrying once in ${RETRY_DELAY}s so a blip pages nobody."
  sleep "$RETRY_DELAY"
  STILL=()
  for id in "${FAILED[@]}"; do
    if out="$(run_check "$id")"; then echo "retry: $out"; else echo "retry: $out"; STILL+=("$id"); fi
  done
  FAILED=("${STILL[@]+"${STILL[@]}"}")
fi

if [ "${#FAILED[@]}" -gt 0 ]; then
  MSG="DOWN: ${FAILED[*]} failed twice (${RETRY_DELAY}s apart) against $BASE_URL"
  echo "::error title=Finglish uptime check failed::$MSG"
  if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then echo "### Finglish is failing checks: ${FAILED[*]}" >> "$GITHUB_STEP_SUMMARY"; fi
  exit 1
fi

echo "All ${#CHECKS[@]} checks passed."
if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then echo "All ${#CHECKS[@]} checks passed." >> "$GITHUB_STEP_SUMMARY"; fi
