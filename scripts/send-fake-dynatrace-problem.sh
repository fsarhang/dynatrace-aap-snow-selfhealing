#!/usr/bin/env bash
#
# Pretends to be Dynatrace: posts a realistic problem notification to the EDA
# event stream. Exercises the whole chain — EDA rule -> job template ->
# ServiceNow -> remediation — without spending Dynatrace trial days.
#
#   source demo.env
#   ./scripts/send-fake-dynatrace-problem.sh            # OPEN problem
#   STATE=RESOLVED ./scripts/send-fake-dynatrace-problem.sh
#
#   # throttling test: send the same problem twice -> only ONE job runs
#   PROBLEM_ID=demo-1 ./scripts/send-fake-dynatrace-problem.sh
#   PROBLEM_ID=demo-1 ./scripts/send-fake-dynatrace-problem.sh
#
#   # guardrail test: entity not tagged for automation -> rule does NOT fire
#   TAGS="env:demo" ./scripts/send-fake-dynatrace-problem.sh
#
# Needs EDA_EVENT_STREAM_URL plus one way to log in:
#   EDA_EVENT_STREAM_USERNAME + EDA_EVENT_STREAM_PASSWORD  (Dynatrace Event Stream / Basic)
#   or EDA_EVENT_STREAM_TOKEN (+ EDA_EVENT_STREAM_HEADER)   (Token Event Stream)

set -euo pipefail

: "${EDA_EVENT_STREAM_URL:?set EDA_EVENT_STREAM_URL (copy it from the event stream page in AAP)}"
if [[ -n "${EDA_EVENT_STREAM_USERNAME:-}" && -n "${EDA_EVENT_STREAM_PASSWORD:-}" ]]; then
  auth_header="Authorization: Basic $(printf %s "${EDA_EVENT_STREAM_USERNAME}:${EDA_EVENT_STREAM_PASSWORD}" | base64)"
elif [[ -n "${EDA_EVENT_STREAM_TOKEN:-}" ]]; then
  auth_header="${EDA_EVENT_STREAM_HEADER:-X-Dynatrace-Token}: ${EDA_EVENT_STREAM_TOKEN}"
else
  echo "!! Set EDA_EVENT_STREAM_USERNAME and EDA_EVENT_STREAM_PASSWORD (or EDA_EVENT_STREAM_TOKEN) in demo.env" >&2; exit 1
fi
STATE="${STATE:-OPEN}"
PID_FAKE="${PID_FAKE:-P-$(date +%y%m%d%H%M)}"
PROBLEM_ID="${PROBLEM_ID:--1234567890123456789_$(date +%s)000V2}"
TAGS="${TAGS:-env:demo, automation:selfheal}"

payload=$(cat <<JSON
{
  "problem_id": "${PROBLEM_ID}",
  "pid": "${PID_FAKE}",
  "title": "Client Portal unavailable",
  "state": "${STATE}",
  "severity": "AVAILABILITY",
  "impact": "SERVICE",
  "impacted_entity": "app01",
  "url": "https://example.live.dynatrace.com/#problems/problemdetails;pid=${PID_FAKE}",
  "tags": "${TAGS}"
}
JSON
)

echo "==> Sending fake ${STATE} problem ${PID_FAKE} to EDA"
code=$(curl -sk -o /tmp/eda-response.txt -w '%{http_code}' -X POST \
  -H "Content-Type: application/json" \
  -H "${auth_header}" \
  -d "${payload}" "${EDA_EVENT_STREAM_URL}")

if [[ "${code}" =~ ^20[0-9]$ ]]; then
  echo "==> Accepted (HTTP ${code})."
  echo "    EDA:  Automation Decisions > Rule Audit — rule 'Remediate an availability problem' should fire"
  echo "    AAP:  Automation Execution > Jobs — 'Self-Heal :: Service Recovery' should start"
else
  echo "!! EDA returned HTTP ${code}:" >&2; cat /tmp/eda-response.txt >&2; echo >&2
  case "${code}" in
    401|403) echo "   -> Username/password (or token) doesn't match the event stream credential." >&2 ;;
    404)     echo "   -> Wrong URL, or the event stream isn't attached to a running activation." >&2 ;;
  esac
  exit 1
fi
