#!/usr/bin/env bash
set -euo pipefail

# Local preflight for GitHub Actions OIDC AWS credentials.
# Validates provider, roles/trust policy, and required GitHub secrets.

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export AWS_PAGER=""

AWS_REGION="${AWS_REGION:-us-east-1}"
GITHUB_REPO="${GITHUB_REPO:-}"
AWS_ACCOUNT_ID="${AWS_ACCOUNT_ID:-}"

if [[ -z "$GITHUB_REPO" ]]; then
  REMOTE_URL="$(git -C "$ROOT_DIR" remote get-url origin 2>/dev/null || true)"
  if [[ -n "$REMOTE_URL" ]]; then
    GITHUB_REPO="$(echo "$REMOTE_URL" | sed -E 's#^(git@github.com:|https://github.com/)##; s#\.git$##')"
  fi
fi

if [[ -z "$GITHUB_REPO" || ! "$GITHUB_REPO" =~ .+/.+ ]]; then
  echo "ERROR: Could not resolve GITHUB_REPO."
  echo "Set it explicitly, e.g. GITHUB_REPO=owner/repo scripts/oidc-preflight-check.sh"
  exit 1
fi

if [[ -z "$AWS_ACCOUNT_ID" ]]; then
  AWS_ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text)"
fi

if [[ -z "$AWS_ACCOUNT_ID" ]]; then
  echo "ERROR: Could not resolve AWS_ACCOUNT_ID from STS."
  exit 1
fi

for cmd in aws jq gh; do
  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo "ERROR: Missing required command: $cmd"
    exit 1
  fi
done

if ! gh auth status >/dev/null 2>&1; then
  echo "ERROR: gh CLI is not authenticated."
  exit 1
fi

echo "Preflight context:"
echo "  AWS_ACCOUNT_ID=$AWS_ACCOUNT_ID"
echo "  AWS_REGION=$AWS_REGION"
echo "  GITHUB_REPO=$GITHUB_REPO"

declare -a FAILURES=()

# 1) OIDC provider exists
OIDC_PROVIDER_ARN="arn:aws:iam::${AWS_ACCOUNT_ID}:oidc-provider/token.actions.githubusercontent.com"
if aws iam get-open-id-connect-provider --open-id-connect-provider-arn "$OIDC_PROVIDER_ARN" >/dev/null 2>&1; then
  echo "OK: OIDC provider exists"
else
  FAILURES+=("OIDC provider missing: $OIDC_PROVIDER_ARN")
fi

# 2) Roles + trust policy validation
for env_name in test staging prod; do
  role_name="eks-platform-github-actions-${env_name}"

  if ! aws iam get-role --role-name "$role_name" >/dev/null 2>&1; then
    FAILURES+=("Role missing: $role_name")
    continue
  fi

  trust_doc="$(aws iam get-role --role-name "$role_name" --query 'Role.AssumeRolePolicyDocument' --output json)"

  aud="$(echo "$trust_doc" | jq -r '.Statement[] | select(.Action=="sts:AssumeRoleWithWebIdentity") | .Condition.StringEquals["token.actions.githubusercontent.com:aud"] // empty' | head -n1)"
  sub_env_match="$(echo "$trust_doc" | jq -r --arg repo "$GITHUB_REPO" --arg env "$env_name" '.Statement[] | select(.Action=="sts:AssumeRoleWithWebIdentity") | .Condition.StringLike["token.actions.githubusercontent.com:sub"]' | jq -r '.[]? // .' | grep -F "repo:${GITHUB_REPO}:environment:${env_name}" || true)"
  sub_main_match="$(echo "$trust_doc" | jq -r '.Statement[] | select(.Action=="sts:AssumeRoleWithWebIdentity") | .Condition.StringLike["token.actions.githubusercontent.com:sub"]' | jq -r '.[]? // .' | grep -F 'repo:' | grep -F ':ref:refs/heads/main' || true)"

  if [[ "$aud" != "sts.amazonaws.com" ]]; then
    FAILURES+=("Role $role_name has invalid aud condition")
  fi

  if [[ -z "$sub_env_match" ]]; then
    FAILURES+=("Role $role_name missing sub for repo/environment")
  fi

  if [[ -z "$sub_main_match" ]]; then
    FAILURES+=("Role $role_name missing sub for main branch")
  fi

  echo "OK: trust policy validated for $role_name"
done

# 3) GitHub secrets exist
secrets_list="$(gh secret list --repo "$GITHUB_REPO" --json name --jq '.[].name')"
for secret_name in AWS_ROLE_TEST AWS_ROLE_STAGING AWS_ROLE_PROD AWS_ACCOUNT_ID; do
  if echo "$secrets_list" | grep -Fx "$secret_name" >/dev/null 2>&1; then
    echo "OK: secret present: $secret_name"
  else
    FAILURES+=("Missing GitHub secret: $secret_name")
  fi
done

if [[ ${#FAILURES[@]} -gt 0 ]]; then
  echo ""
  echo "Preflight FAILED:"
  for f in "${FAILURES[@]}"; do
    echo "  - $f"
  done
  exit 1
fi

echo ""
echo "Preflight PASSED: OIDC roles, trust policies, and required secrets are valid."
