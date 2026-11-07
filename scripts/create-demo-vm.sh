#!/usr/bin/env bash
#
# Creates the RHEL 9 demo-app VM inside the ROSA cluster's VPC, so AAP job pods
# can SSH to it over its private IP.
#
# Needs: aws CLI configured with the Open Environment credentials, and `oc`
# logged in to the cluster (used to discover the cluster's VPC).
#
#   ./scripts/create-demo-vm.sh
#
# Optional overrides:
#   AWS_REGION=us-east-2  VPC_ID=vpc-...  SUBNET_ID=subnet-...
#   INSTANCE_TYPE=t3.small  PUBKEY=~/.ssh/id_ed25519.pub  NAME=selfheal-demo-app01

set -euo pipefail

here="$(cd "$(dirname "$0")/.." && pwd)"
REGION="${AWS_REGION:-${AWS_DEFAULT_REGION:-us-east-2}}"
NAME="${NAME:-selfheal-demo-app01}"
INSTANCE_TYPE="${INSTANCE_TYPE:-t3.small}"
PUBKEY="${PUBKEY:-$HOME/.ssh/id_ed25519.pub}"
OUT="${here}/demo-vm.env"

awsr() { aws --region "${REGION}" "$@"; }

[[ -f "${OUT}" ]] && { echo "!! ${OUT} exists — a VM was already created. Run scripts/delete-demo-vm.sh first." >&2; exit 1; }
[[ -f "${PUBKEY}" ]] || { echo "!! No public key at ${PUBKEY}. Create one: ssh-keygen -t ed25519" >&2; exit 1; }
awsr sts get-caller-identity >/dev/null || { echo "!! aws CLI not configured. Run 'aws configure' with the Open Environment keys." >&2; exit 1; }

# ---- 1. Find the ROSA VPC via a worker node's EC2 instance ID
if [[ -z "${VPC_ID:-}" ]]; then
  echo "==> Discovering the ROSA cluster VPC"
  provider_id=$(oc get nodes -l node-role.kubernetes.io/worker -o jsonpath='{.items[0].spec.providerID}')
  worker_instance="${provider_id##*/}"
  VPC_ID=$(awsr ec2 describe-instances --instance-ids "${worker_instance}" \
    --query 'Reservations[0].Instances[0].VpcId' --output text)
fi
VPC_CIDR=$(awsr ec2 describe-vpcs --vpc-ids "${VPC_ID}" --query 'Vpcs[0].CidrBlock' --output text)
echo "    VPC ${VPC_ID} (${VPC_CIDR})"

# ---- 2. Find a public subnet (route table with an internet gateway)
if [[ -z "${SUBNET_ID:-}" ]]; then
  echo "==> Finding a public subnet"
  for s in $(awsr ec2 describe-subnets --filters "Name=vpc-id,Values=${VPC_ID}" --query 'Subnets[].SubnetId' --output text); do
    if awsr ec2 describe-route-tables --filters "Name=association.subnet-id,Values=${s}" \
         --query 'RouteTables[].Routes[].GatewayId' --output text | tr '\t' '\n' | grep -q '^igw-'; then
      SUBNET_ID="${s}"; break
    fi
  done
  [[ -n "${SUBNET_ID:-}" ]] || { echo "!! No public subnet found in ${VPC_ID}. Set SUBNET_ID=... and re-run." >&2; exit 1; }
fi
echo "    subnet ${SUBNET_ID}"

# ---- 3. Latest RHEL 9 (Hourly — subscription included in the price)
AMI_ID=$(awsr ec2 describe-images --owners 309956199498 \
  --filters 'Name=name,Values=RHEL-9.*_HVM-*-x86_64-*Hourly*' 'Name=architecture,Values=x86_64' \
  --query 'sort_by(Images,&CreationDate)[-1].ImageId' --output text)
echo "    AMI ${AMI_ID}"

MY_IP="$(curl -s https://checkip.amazonaws.com | tr -d '[:space:]')/32"
echo "    your IP ${MY_IP}"

# ---- 4. Key pair
KEY_NAME="${NAME}-key"
if ! awsr ec2 describe-key-pairs --key-names "${KEY_NAME}" >/dev/null 2>&1; then
  echo "==> Importing SSH key ${KEY_NAME}"
  awsr ec2 import-key-pair --key-name "${KEY_NAME}" --public-key-material "fileb://${PUBKEY}" >/dev/null
fi

# ---- 5. Security group
echo "==> Creating security group"
SG_ID=$(awsr ec2 create-security-group --group-name "${NAME}-sg" \
  --description "Self-heal demo app: SSH from admin + ROSA VPC, HTTP from anywhere" \
  --vpc-id "${VPC_ID}" --query 'GroupId' --output text)
awsr ec2 authorize-security-group-ingress --group-id "${SG_ID}" --ip-permissions \
  "IpProtocol=tcp,FromPort=22,ToPort=22,IpRanges=[{CidrIp=${MY_IP},Description=admin-ssh}]" \
  "IpProtocol=tcp,FromPort=22,ToPort=22,IpRanges=[{CidrIp=${VPC_CIDR},Description=aap-job-pods}]" \
  "IpProtocol=tcp,FromPort=80,ToPort=80,IpRanges=[{CidrIp=0.0.0.0/0,Description=synthetic-monitor}]" >/dev/null

# ---- 6. Instance
echo "==> Launching ${INSTANCE_TYPE}"
INSTANCE_ID=$(awsr ec2 run-instances \
  --image-id "${AMI_ID}" --instance-type "${INSTANCE_TYPE}" \
  --key-name "${KEY_NAME}" --subnet-id "${SUBNET_ID}" --security-group-ids "${SG_ID}" \
  --associate-public-ip-address \
  --block-device-mappings 'DeviceName=/dev/sda1,Ebs={VolumeSize=20,VolumeType=gp3,Encrypted=true}' \
  --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=${NAME}},{Key=Purpose,Value=selfheal-demo}]" \
  --user-data "#!/bin/bash
hostnamectl set-hostname ${NAME}" \
  --query 'Instances[0].InstanceId' --output text)
awsr ec2 wait instance-running --instance-ids "${INSTANCE_ID}"

# ---- 7. Elastic IP so the synthetic monitor URL survives stop/start
echo "==> Attaching an Elastic IP"
ALLOC_ID=$(awsr ec2 allocate-address --domain vpc \
  --tag-specifications "ResourceType=elastic-ip,Tags=[{Key=Name,Value=${NAME}-eip}]" \
  --query 'AllocationId' --output text)
awsr ec2 associate-address --instance-id "${INSTANCE_ID}" --allocation-id "${ALLOC_ID}" >/dev/null

PUBLIC_IP=$(awsr ec2 describe-addresses --allocation-ids "${ALLOC_ID}" --query 'Addresses[0].PublicIp' --output text)
PRIVATE_IP=$(awsr ec2 describe-instances --instance-ids "${INSTANCE_ID}" \
  --query 'Reservations[0].Instances[0].PrivateIpAddress' --output text)

cat > "${OUT}" <<EOF
# Written by scripts/create-demo-vm.sh — used by delete-demo-vm.sh. Gitignored.
export AWS_REGION=${REGION}
export DEMO_VM_INSTANCE_ID=${INSTANCE_ID}
export DEMO_VM_ALLOC_ID=${ALLOC_ID}
export DEMO_VM_SG_ID=${SG_ID}
export DEMO_VM_KEY_NAME=${KEY_NAME}
export DEMO_VM_PUBLIC_IP=${PUBLIC_IP}
export DEMO_VM_PRIVATE_IP=${PRIVATE_IP}
export APP_URL=http://${PUBLIC_IP}/health
EOF

# Laptop inventory (public IP) — AAP uses the private IP instead
cat > "${here}/inventory/hosts.yml" <<EOF
---
# Laptop use only. In AAP, host app01 uses ansible_host: ${PRIVATE_IP}
all:
  children:
    demo_app:
      hosts:
        app01:
          ansible_host: ${PUBLIC_IP}
          ansible_user: ec2-user
EOF

echo
echo "  Instance   : ${INSTANCE_ID}"
echo "  Public IP  : ${PUBLIC_IP}   (browser, Dynatrace synthetic monitor, your SSH)"
echo "  Private IP : ${PRIVATE_IP}  (use this for host app01 in the AAP inventory)"
echo
echo "  ssh ec2-user@${PUBLIC_IP}   (give it ~60s to finish booting)"
echo "  Saved to ${OUT}"
