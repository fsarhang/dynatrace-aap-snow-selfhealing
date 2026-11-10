#!/usr/bin/env bash
#
# Quick "is everything still up?" check. Run it whenever you come back to the build.
#
#   ./scripts/status.sh

here="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck disable=SC1091
source "${here}/demo.env" 2>/dev/null
# shellcheck disable=SC1091
source "${here}/demo-vm.env" 2>/dev/null

ok()  { printf '  \033[32m✓\033[0m %s\n' "$1"; }
bad() { printf '  \033[31m✗\033[0m %s\n' "$1"; }

echo
if oc whoami >/dev/null 2>&1; then
  ok "Cluster login ($(oc whoami))"
else
  bad "Cluster login expired. Run: oc login \"\$OCP_API\" -u \"\$OCP_ADMIN_USER\" -p \"\$OCP_ADMIN_PASSWORD\""
fi

code=$(curl -sk -o /dev/null -w '%{http_code}' --max-time 15 "${AAP_HOST:-https://unset}/api/gateway/v1/ping/")
[[ "${code}" == "200" ]] && ok "AAP (${AAP_HOST})" || bad "AAP not answering (HTTP ${code})"

if [[ -n "${DEMO_VM_PUBLIC_IP:-}" ]] && ssh -o ConnectTimeout=8 -o BatchMode=yes "ec2-user@${DEMO_VM_PUBLIC_IP}" true 2>/dev/null; then
  ok "Demo VM SSH (${DEMO_VM_PUBLIC_IP})"
else
  bad "Demo VM not reachable over SSH (${DEMO_VM_PUBLIC_IP:-no demo-vm.env})"
fi

code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 "http://${DEMO_VM_PUBLIC_IP:-0.0.0.0}/health")
[[ "${code}" == "200" ]] && ok "Client Portal app is healthy" || bad "Client Portal app not answering (HTTP ${code}). Expected until doc 02 step 10, or while it's broken on purpose"

code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 20 "${SN_HOST:-https://unset}/login.do")
[[ "${code}" == "200" ]] && ok "ServiceNow (${SN_HOST})" || bad "ServiceNow not answering (HTTP ${code}). It may be hibernating: wake it at developer.servicenow.com"
echo
