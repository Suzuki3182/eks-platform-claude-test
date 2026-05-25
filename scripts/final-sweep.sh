#!/usr/bin/env bash
set -euo pipefail

OUT_DIR="artifacts"
mkdir -p "$OUT_DIR"
STAMP=$(date -u +%Y%m%d-%H%M%S)
OUT_FILE="$OUT_DIR/final-sweep-${STAMP}.txt"

{
  echo "Final sweep at $(date -u --iso-8601=seconds)"
  echo
  echo "All-region EKS clusters"
  for r in $(aws ec2 describe-regions --query 'Regions[].RegionName' --output text); do
    c=$(aws eks list-clusters --region "$r" --query 'length(clusters)' --output text 2>/dev/null || echo err)
    if [[ "$c" != "0" && "$c" != "err" ]]; then
      echo "region=$r clusters=$c"
      aws eks list-clusters --region "$r" --output table
    fi
  done
  echo
  echo "All-region running EC2, NAT, ELB"
  for r in $(aws ec2 describe-regions --query 'Regions[].RegionName' --output text); do
    ri=$(aws ec2 describe-instances --region "$r" --filters Name=instance-state-name,Values=running --query 'length(Reservations[].Instances[])' --output text 2>/dev/null || echo 0)
    ng=$(aws ec2 describe-nat-gateways --region "$r" --query "length(NatGateways[?State=='available' || State=='pending'])" --output text 2>/dev/null || echo 0)
    lb=$(aws elbv2 describe-load-balancers --region "$r" --query 'length(LoadBalancers)' --output text 2>/dev/null || echo 0)
    ve=$(aws ec2 describe-vpc-endpoints --region "$r" --query "length(VpcEndpoints[?State=='available' || State=='pendingAcceptance' || State=='pending'])" --output text 2>/dev/null || echo 0)
    if [[ "$ri" != "0" || "$ng" != "0" || "$lb" != "0" || "$ve" != "0" ]]; then
      echo "region=$r instances=$ri nat=$ng lb=$lb vpc_endpoints=$ve"
    fi
  done
  echo
  echo "KMS alias check (eks-platform*)"
  aws kms list-aliases --region us-east-1 --query "Aliases[?contains(AliasName, 'eks-platform')].[AliasName,TargetKeyId]" --output table
} | tee "$OUT_FILE"

echo "Saved: $OUT_FILE"
