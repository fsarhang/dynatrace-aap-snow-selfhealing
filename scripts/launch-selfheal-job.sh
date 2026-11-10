#!/usr/bin/env bash
#
# Launches the self-heal job template directly through the controller API,
# bypassing EDA. Use it to test AAP -> ServiceNow before EDA exists, and as the
# on-stage fallback if the event path misbehaves.
#
#   source demo.env
#   FOLLOW=1 ./scripts/launch-selfheal-job.sh

set -euo pipefail

: "${AAP_HOST:?set AAP_HOST, e.g. https://aap-aap.apps.xxxx.openshiftapps.com}"
: "${AAP_TOKEN:?set AAP_TOKEN}"
: "${AAP_JOB_TEMPLATE_ID:?set AAP_JOB_TEMPLATE_ID}"
API="${AAP_HOST}/api/controller/v2"
PID_FAKE="P-$(date +%y%m%d%H%M)"

body=$(cat <<JSON
{"extra_vars": {
  "dt_pid": "${PID_FAKE}",
  "dt_problem_title": "Client Portal unavailable",
  "dt_problem_severity": "AVAILABILITY",
  "dt_problem_state": "OPEN",
  "dt_impacted_entity": "app01",
  "target_host": "app01",
  "target_service": "demo-api"
}}
JSON
)

resp=$(curl -sk -w '\n%{http_code}' -X POST -H "Authorization: Bearer ${AAP_TOKEN}" \
  -H "Content-Type: application/json" -d "${body}" "${API}/job_templates/${AAP_JOB_TEMPLATE_ID}/launch/")
code=$(printf '%s' "${resp}" | tail -n1)
json=$(printf '%s' "${resp}" | sed '$d')

if [[ "${code}" != "201" ]]; then
  echo "!! Launch failed (HTTP ${code}): ${json}" >&2
  [[ "${code}" == "400" ]] && echo "   -> Tick 'Prompt on launch' for Variables on the job template." >&2
  exit 1
fi

job_id=$(printf '%s' "${json}" | python3 -c 'import json,sys; print(json.load(sys.stdin)["id"])')
echo "==> Job ${job_id} launched: ${AAP_HOST}/execution/jobs/playbook/${job_id}/output"

[[ "${FOLLOW:-0}" == "1" ]] || exit 0
echo -n "==> Waiting"
for _ in $(seq 1 120); do
  status=$(curl -sk -H "Authorization: Bearer ${AAP_TOKEN}" "${API}/jobs/${job_id}/" \
    | python3 -c 'import json,sys; print(json.load(sys.stdin)["status"])')
  case "${status}" in
    successful) echo; echo "==> SUCCESS"; exit 0 ;;
    failed|error|canceled) echo; echo "==> ${status} — open the job output in AAP"; exit 1 ;;
    *) echo -n "."; sleep 3 ;;
  esac
done
echo; echo "==> Timed out"; exit 1
