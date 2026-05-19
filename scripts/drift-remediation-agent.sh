#!/bin/bash
#
# drift-remediation-agent.sh
# Detects Terraform state drift and auto-remediates safe changes.
#
# SAFETY CONSTRAINTS (never auto-apply):
#   - Changes to: module.vpc, module.eks, module.iam, aws_kms_key
#   - Action types: REPLACE (tainted), DELETE
#   - Environments: only runs in test/staging; prod requires DRIFT_ALLOW_PROD=true
#
# Usage: ./drift-remediation-agent.sh [--environment ENV] [--dry-run]
# Env:   DRIFT_AUTO_APPLY (default: false), DRIFT_ALLOW_PROD (default: false)
#        AWS_ACCOUNT_ID, AWS_REGION
#

set -euo pipefail

ENVIRONMENT="${ENVIRONMENT:-}"
DRY_RUN=false
[[ "${1:-}" == "--dry-run" ]] && DRY_RUN=true
[[ "${2:-}" == "--dry-run" ]] && DRY_RUN=true

DRIFT_AUTO_APPLY="${DRIFT_AUTO_APPLY:-false}"
DRIFT_ALLOW_PROD="${DRIFT_ALLOW_PROD:-false}"
AWS_ACCOUNT_ID="${AWS_ACCOUNT_ID:-}"
AWS_REGION="${AWS_REGION:-us-east-1}"
REPORT_FILE="artifacts/drift-remediation-report.json"
LOG_FILE="artifacts/drift-remediation-agent.log"

mkdir -p artifacts

log() {
  local ts
  ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  echo "[$ts] $*" | tee -a "$LOG_FILE"
}

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "Drift Remediation Agent"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
log "auto_apply=$DRIFT_AUTO_APPLY dry_run=$DRY_RUN"

# ── Protected resource prefixes — NEVER auto-apply ────────────────────────────
PROTECTED_PREFIXES=(
  "module.vpc"
  "module.eks"
  "module.iam"
  "aws_kms_key"
  "module.github_oidc"
)

is_protected() {
  local resource="$1"
  for prefix in "${PROTECTED_PREFIXES[@]}"; do
    if [[ "$resource" == "$prefix"* ]]; then
      return 0
    fi
  done
  return 1
}

# ── Determine environments to check ──────────────────────────────────────────
ENVS=()
if [[ -n "$ENVIRONMENT" ]]; then
  ENVS=("$ENVIRONMENT")
else
  for env_dir in terraform/environments/*/; do
    env_name=$(basename "$env_dir")
    if [[ "$env_name" == "prod" ]] && [[ "$DRIFT_ALLOW_PROD" != "true" ]]; then
      log "SKIP prod (set DRIFT_ALLOW_PROD=true to include)"
      continue
    fi
    ENVS+=("$env_name")
  done
fi

log "Checking environments: ${ENVS[*]}"

ALL_RESULTS=()
TOTAL_DRIFT=0
TOTAL_REMEDIATED=0
TOTAL_SKIPPED=0

for env in "${ENVS[@]}"; do
  ENV_DIR="terraform/environments/$env"
  if [[ ! -d "$ENV_DIR" ]]; then
    log "SKIP: $ENV_DIR does not exist"
    continue
  fi

  log "Scanning $env for drift..."

  # Run terraform plan -refresh-only to detect drift
  PLAN_OUT=$(mktemp)
  set +e
  terraform -chdir="$ENV_DIR" plan \
    -refresh-only \
    -var="aws_account_id=${AWS_ACCOUNT_ID:-placeholder}" \
    -var="app_image_tag=latest" \
    -no-color \
    -detailed-exitcode \
    > "$PLAN_OUT" 2>&1
  PLAN_EXIT=$?
  set -e

  if [[ "$PLAN_EXIT" -eq 0 ]]; then
    log "$env: No drift detected."
    ALL_RESULTS+=("{\"environment\":\"$env\",\"drift_detected\":false,\"changes\":[],\"action\":\"none\"}")
    rm -f "$PLAN_OUT"
    continue
  fi

  if [[ "$PLAN_EXIT" -eq 1 ]]; then
    log "WARNING: terraform plan failed for $env (credentials or backend issue)"
    ALL_RESULTS+=("{\"environment\":\"$env\",\"drift_detected\":false,\"error\":\"plan_failed\",\"action\":\"skipped\"}")
    rm -f "$PLAN_OUT"
    continue
  fi

  # Exit code 2 = changes detected
  log "$env: Drift detected. Analyzing..."
  ((TOTAL_DRIFT++))

  # Extract changed resources
  DRIFTED_RESOURCES=()
  HAS_UNSAFE=false
  UNSAFE_RESOURCES=()
  SAFE_RESOURCES=()

  while IFS= read -r line; do
    # Lines like "  ~ module.ecr.aws_ecr_lifecycle_policy.this will be updated in-place"
    # Lines like "  -/+ module.vpc.aws_subnet.private[0] must be replaced"
    resource=""
    action=""

    if echo "$line" | grep -qE '^\s+[~] '; then
      resource=$(echo "$line" | grep -oP '(?<=~ )[\w.\/\[\]"]+')
      action="UPDATE"
    elif echo "$line" | grep -qE '^\s+\+ '; then
      resource=$(echo "$line" | grep -oP '(?<=\+ )[\w.\/\[\]"]+')
      action="CREATE"
    elif echo "$line" | grep -qE '^\s+-/\+|\s+\+/-'; then
      resource=$(echo "$line" | grep -oP 'module\.\w+[\w.\/\[\]"]*' | head -1)
      action="REPLACE"
      HAS_UNSAFE=true
    elif echo "$line" | grep -qE '^\s+- '; then
      resource=$(echo "$line" | grep -oP '(?<=- )[\w.\/\[\]"]+')
      action="DELETE"
      HAS_UNSAFE=true
    fi

    [[ -z "$resource" ]] && continue

    DRIFTED_RESOURCES+=("{\"resource\":\"$resource\",\"action\":\"$action\"}")

    if [[ "$action" == "REPLACE" || "$action" == "DELETE" ]]; then
      UNSAFE_RESOURCES+=("$resource ($action)")
      HAS_UNSAFE=true
      log "UNSAFE [$action]: $resource"
    elif is_protected "$resource"; then
      UNSAFE_RESOURCES+=("$resource (protected)")
      HAS_UNSAFE=true
      log "PROTECTED: $resource"
    else
      SAFE_RESOURCES+=("$resource ($action)")
      log "SAFE [$action]: $resource"
    fi
  done < <(grep -E '^\s+(~|\+|-|=|-/\+|\+/-)' "$PLAN_OUT" || true)

  rm -f "$PLAN_OUT"

  DRIFTED_JSON=$(printf '%s\n' "${DRIFTED_RESOURCES[@]:-}" | jq -s '.' 2>/dev/null || echo "[]")
  SAFE_COUNT=${#SAFE_RESOURCES[@]}
  UNSAFE_COUNT=${#UNSAFE_RESOURCES[@]}

  log "$env: safe=$SAFE_COUNT unsafe=$UNSAFE_COUNT"

  if [[ "$HAS_UNSAFE" == "true" ]]; then
    log "SKIP auto-remediation: $UNSAFE_COUNT unsafe change(s) in $env"
    ALL_RESULTS+=("{\"environment\":\"$env\",\"drift_detected\":true,\"safe_count\":$SAFE_COUNT,\"unsafe_count\":$UNSAFE_COUNT,\"changes\":$DRIFTED_JSON,\"action\":\"manual_review_required\",\"reason\":\"unsafe or protected resource changes detected\"}")
    ((TOTAL_SKIPPED++))
    continue
  fi

  if [[ "$SAFE_COUNT" -eq 0 ]]; then
    ALL_RESULTS+=("{\"environment\":\"$env\",\"drift_detected\":true,\"safe_count\":0,\"unsafe_count\":0,\"changes\":$DRIFTED_JSON,\"action\":\"no_safe_changes\"}")
    continue
  fi

  # Only safe changes remain
  if [[ "$DRIFT_AUTO_APPLY" != "true" ]] || [[ "$DRY_RUN" == "true" ]]; then
    log "$env: $SAFE_COUNT safe change(s) found. Not applying (DRIFT_AUTO_APPLY=$DRIFT_AUTO_APPLY, dry_run=$DRY_RUN)."
    ALL_RESULTS+=("{\"environment\":\"$env\",\"drift_detected\":true,\"safe_count\":$SAFE_COUNT,\"unsafe_count\":0,\"changes\":$DRIFTED_JSON,\"action\":\"would_remediate\"}")
    continue
  fi

  log "$env: Auto-applying $SAFE_COUNT safe drift change(s)..."
  set +e
  terraform -chdir="$ENV_DIR" apply \
    -refresh-only \
    -auto-approve \
    -var="aws_account_id=${AWS_ACCOUNT_ID:-placeholder}" \
    -var="app_image_tag=latest" \
    2>&1 | tee -a "$LOG_FILE"
  APPLY_EXIT=$?
  set -e

  if [[ "$APPLY_EXIT" -eq 0 ]]; then
    log "$env: Drift remediated successfully."
    ALL_RESULTS+=("{\"environment\":\"$env\",\"drift_detected\":true,\"safe_count\":$SAFE_COUNT,\"unsafe_count\":0,\"changes\":$DRIFTED_JSON,\"action\":\"remediated\"}")
    ((TOTAL_REMEDIATED++))
  else
    log "ERROR: Remediation failed for $env (exit=$APPLY_EXIT)"
    ALL_RESULTS+=("{\"environment\":\"$env\",\"drift_detected\":true,\"safe_count\":$SAFE_COUNT,\"unsafe_count\":0,\"changes\":$DRIFTED_JSON,\"action\":\"remediation_failed\"}")
    ((TOTAL_SKIPPED++))
  fi
done

RESULTS_JSON=$(printf '%s\n' "${ALL_RESULTS[@]:-}" | jq -s '.' 2>/dev/null || echo "[]")

cat > "$REPORT_FILE" << EOF
{
  "timestamp": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "environments_checked": ${#ENVS[@]},
  "total_drift_detected": $TOTAL_DRIFT,
  "total_remediated": $TOTAL_REMEDIATED,
  "total_skipped": $TOTAL_SKIPPED,
  "drift_auto_apply": $([[ "$DRIFT_AUTO_APPLY" == "true" ]] && echo "true" || echo "false"),
  "dry_run": $DRY_RUN,
  "results": $RESULTS_JSON,
  "agent_version": "1.0"
}
EOF

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "Drift Remediation Summary"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "Environments checked:  ${#ENVS[@]}"
echo "Drift detected:        $TOTAL_DRIFT"
echo "Remediated:            $TOTAL_REMEDIATED"
echo "Requires manual review:$TOTAL_SKIPPED"
echo ""
echo "Report: $REPORT_FILE"
exit 0
