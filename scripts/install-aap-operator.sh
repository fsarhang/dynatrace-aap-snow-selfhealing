#!/usr/bin/env bash
#
# Installs the Ansible Automation Platform operator on ROSA and deploys one AAP
# instance (gateway + controller + EDA). Requires `oc` logged in as cluster-admin.
#
#   ./scripts/install-aap-operator.sh
#
# Optional:
#   CHANNEL=stable-2.5   # pin a channel instead of auto-detecting the newest

set -euo pipefail

here="$(cd "$(dirname "$0")/.." && pwd)"
NS=aap

oc whoami >/dev/null 2>&1 || { echo "!! Not logged in. Run the 'oc login' command from the OpenShift console first." >&2; exit 1; }
[[ "$(oc auth can-i create subscriptions -n openshift-marketplace)" == "yes" ]] \
  || { echo "!! Your user is not cluster-admin. Re-order the environment with 'Set up cluster admin in ROSA' ticked." >&2; exit 1; }

if [[ -z "${CHANNEL:-}" ]]; then
  echo "==> Finding the newest stable AAP operator channel"
  CHANNEL=$(oc get packagemanifest ansible-automation-platform-operator -n openshift-marketplace \
    -o jsonpath='{range .status.channels[*]}{.name}{"\n"}{end}' \
    | grep -E '^stable-2\.[0-9]+$' | sort -t. -k2 -n | tail -1)
  [[ -n "${CHANNEL}" ]] || { echo "!! Could not find a stable-2.x channel. Check OperatorHub." >&2; exit 1; }
fi
echo "    using channel ${CHANNEL}"

echo "==> Creating namespace and operator group"
oc apply -f "${here}/openshift/00-namespace.yml"

echo "==> Subscribing to the operator"
sed "s/CHANNEL/${CHANNEL}/" "${here}/openshift/01-subscription.yml" | oc apply -f -

echo -n "==> Waiting for the operator to install (2-5 min)"
for _ in $(seq 1 90); do
  phase=$(oc get csv -n "${NS}" -o jsonpath='{range .items[*]}{.metadata.name}{" "}{.status.phase}{"\n"}{end}' 2>/dev/null \
    | awk '/aap-operator|ansible-automation-platform/ {print $2}' | head -1)
  [[ "${phase}" == "Succeeded" ]] && break
  echo -n "."; sleep 10
done
echo
[[ "${phase:-}" == "Succeeded" ]] || { echo "!! Operator did not reach Succeeded. Check: oc get csv -n ${NS}" >&2; exit 1; }

echo "==> Deploying the AAP instance"
oc apply -f "${here}/openshift/02-aap-instance.yml"

echo -n "==> Waiting for the platform gateway route (10-20 min)"
for _ in $(seq 1 120); do
  host=$(oc get route aap -n "${NS}" -o jsonpath='{.spec.host}' 2>/dev/null || true)
  if [[ -n "${host}" ]] && curl -sk -o /dev/null -w '%{http_code}' "https://${host}/api/gateway/v1/ping/" | grep -q 200; then
    break
  fi
  echo -n "."; sleep 15
done
echo

host=$(oc get route aap -n "${NS}" -o jsonpath='{.spec.host}' 2>/dev/null || true)
password=$(oc get secret aap-admin-password -n "${NS}" -o jsonpath='{.data.password}' 2>/dev/null | base64 -d || true)

echo
echo "  AAP URL : https://${host:-<not ready — run: oc get routes -n ${NS}>}"
echo "  User    : admin"
echo "  Password: ${password:-<not ready — run: oc get secret aap-admin-password -n ${NS} -o jsonpath='{.data.password}' | base64 -d>}"
echo
echo "  All pods: oc get pods -n ${NS}"
echo "  Next    : log in, upload your subscription manifest, then follow docs/02-aap-on-rosa.md step 5."
