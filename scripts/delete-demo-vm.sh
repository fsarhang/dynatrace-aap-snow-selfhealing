#!/usr/bin/env bash
#
# Removes everything create-demo-vm.sh made: instance, Elastic IP, security
# group, key pair. Does not touch the ROSA cluster or AAP.

set -euo pipefail

here="$(cd "$(dirname "$0")/.." && pwd)"
env_file="${here}/demo-vm.env"
[[ -f "${env_file}" ]] || { echo "!! ${env_file} not found — nothing to delete." >&2; exit 1; }
# shellcheck disable=SC1090
source "${env_file}"

awsr() { aws --region "${AWS_REGION}" "$@"; }

read -r -p "Terminate ${DEMO_VM_INSTANCE_ID} (${DEMO_VM_PUBLIC_IP}) and release its resources? [y/N] " ok
[[ "${ok}" =~ ^[Yy]$ ]] || exit 0

echo "==> Terminating instance"
awsr ec2 terminate-instances --instance-ids "${DEMO_VM_INSTANCE_ID}" >/dev/null
awsr ec2 wait instance-terminated --instance-ids "${DEMO_VM_INSTANCE_ID}"

echo "==> Releasing Elastic IP"
awsr ec2 release-address --allocation-id "${DEMO_VM_ALLOC_ID}" || true

echo "==> Deleting security group and key pair"
awsr ec2 delete-security-group --group-id "${DEMO_VM_SG_ID}" || true
awsr ec2 delete-key-pair --key-name "${DEMO_VM_KEY_NAME}" || true

rm -f "${env_file}"
echo "==> Done"
