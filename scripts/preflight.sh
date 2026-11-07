#!/usr/bin/env bash
#
# Run this 30 minutes before you present. Every item that can silently rot
# between rehearsals is checked here.
#
#   source demo.env && source demo-vm.env
#   ./scripts/preflight.sh

set -uo pipefail

pass=0; fail=0
check() {
  local label="$1"; shift
  if "$@" >/dev/null 2>&1; then
    printf '  \033[32m✓\033[0m %s\n' "${label}"; pass=$((pass+1))
  else
    printf '  \033[31m✗\033[0m %s\n' "${label}"; fail=$((fail+1))
  fi
}

http_ok() { # url, expected_code, [curl args...]
  local url="$1" expect="$2"; shift 2
  local code
  code=$(curl -sk -o /dev/null -w '%{http_code}' --max-time 15 "$@" "${url}")
  [[ "${code}" == "${expect}" ]]
}

echo
echo "Self-healing demo preflight — $(date -u '+%Y-%m-%d %H:%M:%SZ')"
echo

echo "Demo workload"
check "app /health returns 200 (service is UP before you break it)" \
  http_ok "${APP_URL:-}" 200
check "app landing page returns 200" \
  http_ok "${APP_URL%/health}/" 200

echo
echo "ServiceNow PDI"
check "instance awake and API reachable" \
  http_ok "${SN_HOST:-}/api/now/table/incident?sysparm_limit=1" 200 \
  -u "${SN_USERNAME:-}:${SN_PASSWORD:-}" -H 'Accept: application/json'

echo
echo "Ansible Automation Platform"
check "controller API reachable and token valid" \
  http_ok "${AAP_HOST:-}/api/controller/v2/me/" 200 \
  -H "Authorization: Bearer ${AAP_TOKEN:-}"
check "job template ${AAP_JOB_TEMPLATE_ID:-?} visible to the token" \
  http_ok "${AAP_HOST:-}/api/controller/v2/job_templates/${AAP_JOB_TEMPLATE_ID:-0}/" 200 \
  -H "Authorization: Bearer ${AAP_TOKEN:-}"

eda_running() {
  curl -sk --max-time 15 -H "Authorization: Bearer ${AAP_TOKEN:-}" --get \
    --data-urlencode "name=${EDA_ACTIVATION_NAME:-Dynatrace Self-Heal}" \
    "${AAP_HOST:-}/api/eda/v1/activations/" \
    | python3 -c 'import json,sys; r=json.load(sys.stdin)["results"]; sys.exit(0 if r and r[0]["status"]=="running" else 1)'
}
check "EDA rulebook activation '${EDA_ACTIVATION_NAME:-Dynatrace Self-Heal}' is running" eda_running

echo
echo "Dynatrace"
check "tenant API reachable and token valid" \
  http_ok "${DT_TENANT_URL:-}/api/v2/problems?pageSize=1" 200 \
  -H "Authorization: Api-Token ${DT_API_TOKEN:-}"

echo
if [[ -n "${DT_TENANT_URL:-}" && -n "${DT_API_TOKEN:-}" ]]; then
  open_problems=$(curl -sk --max-time 15 \
    -H "Authorization: Api-Token ${DT_API_TOKEN}" \
    "${DT_TENANT_URL}/api/v2/problems?problemSelector=status(\"open\")&pageSize=50" \
    | python3 -c 'import json,sys; print(json.load(sys.stdin).get("totalCount",0))' 2>/dev/null || echo "?")
  echo "Open Dynatrace problems right now: ${open_problems}"
  [[ "${open_problems}" != "0" ]] && echo "  (clear these first — a pre-existing problem muddies the demo)"
fi

echo
echo "  ${pass} passed, ${fail} failed"
echo
[[ "${fail}" -eq 0 ]] || { echo "Fix the above before presenting. Fall back to the recording if you cannot."; exit 1; }
echo "Good to go."
