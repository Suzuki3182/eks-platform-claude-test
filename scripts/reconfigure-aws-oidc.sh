#!/usr/bin/env bash
set -euo pipefail

# Recreates/updates GitHub OIDC provider + environment roles via Terraform,
# then updates GitHub Actions secrets with the resulting role ARNs.

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
AWS_REGION="${AWS_REGION:-us-east-1}"
GITHUB_REPO="${GITHUB_REPO:-}"
AUTO_SET_SECRETS="${AUTO_SET_SECRETS:-true}"
export AWS_PAGER=""

if [[ -z "$GITHUB_REPO" ]]; then
  REMOTE_URL="$(git -C "$ROOT_DIR" remote get-url origin 2>/dev/null || true)"
  if [[ -n "$REMOTE_URL" ]]; then
    GITHUB_REPO="$(echo "$REMOTE_URL" | sed -E 's#^(git@github.com:|https://github.com/)##; s#\.git$##')"
  fi
fi

if [[ -z "$GITHUB_REPO" || ! "$GITHUB_REPO" =~ .+/.+ ]]; then
  echo "ERROR: Could not determine GITHUB_REPO."
  echo "Set it explicitly, e.g.:"
  echo "  GITHUB_REPO=owner/repo scripts/reconfigure-aws-oidc.sh"
  exit 1
fi

if ! command -v terraform >/dev/null 2>&1; then
  echo "ERROR: terraform is required in PATH."
  exit 1
fi

if ! command -v aws >/dev/null 2>&1; then
  echo "ERROR: aws CLI is required in PATH."
  exit 1
fi

if [[ "$AUTO_SET_SECRETS" == "true" ]] && ! command -v gh >/dev/null 2>&1; then
  echo "ERROR: gh CLI is required when AUTO_SET_SECRETS=true."
  echo "Set AUTO_SET_SECRETS=false to skip secret updates."
  exit 1
fi

AWS_ACCOUNT_ID="${AWS_ACCOUNT_ID:-$(aws sts get-caller-identity --query Account --output text)}"

if [[ -z "$AWS_ACCOUNT_ID" ]]; then
  echo "ERROR: Could not resolve AWS account ID."
  exit 1
fi

echo "Using:"
echo "  AWS_ACCOUNT_ID=$AWS_ACCOUNT_ID"
echo "  AWS_REGION=$AWS_REGION"
echo "  GITHUB_REPO=$GITHUB_REPO"

declare -A ENV_SECRET_MAP=(
  [test]="AWS_ROLE_TEST"
  [staging]="AWS_ROLE_STAGING"
  [prod]="AWS_ROLE_PROD"
)

declare -A ROLE_ARN_MAP=()

for env_name in test staging prod; do
  env_dir="$ROOT_DIR/terraform/environments/$env_name"

  echo ""
  echo "==> Applying OIDC config for $env_name"

  terraform -chdir="$env_dir" init
  terraform -chdir="$env_dir" apply -auto-approve \
    -target="module.github_oidc" \
    -var="aws_account_id=$AWS_ACCOUNT_ID" \
    -var="aws_region=$AWS_REGION" \
    -var="github_repo=$GITHUB_REPO"

  role_arn="$(terraform -chdir="$env_dir" output -raw github_actions_role_arn)"
  if [[ -z "$role_arn" ]]; then
    echo "ERROR: Missing github_actions_role_arn output for $env_name"
    exit 1
  fi

  ROLE_ARN_MAP[$env_name]="$role_arn"
  echo "Role ($env_name): $role_arn"
done

if [[ "$AUTO_SET_SECRETS" == "true" ]]; then
  echo ""
  echo "==> Updating GitHub repository secrets"
  for env_name in test staging prod; do
    secret_name="${ENV_SECRET_MAP[$env_name]}"
    secret_value="${ROLE_ARN_MAP[$env_name]}"

    gh secret set "$secret_name" --repo "$GITHUB_REPO" --body "$secret_value"
    echo "Updated secret $secret_name"
  done

  gh secret set AWS_ACCOUNT_ID --repo "$GITHUB_REPO" --body "$AWS_ACCOUNT_ID"
  echo "Updated secret AWS_ACCOUNT_ID"
fi

echo ""
echo "OIDC reconfiguration complete."
if [[ "$AUTO_SET_SECRETS" == "false" ]]; then
  echo "Role ARNs:"
  for env_name in test staging prod; do
    echo "  ${ENV_SECRET_MAP[$env_name]}=${ROLE_ARN_MAP[$env_name]}"
  done
fi
