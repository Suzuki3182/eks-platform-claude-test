#!/bin/bash
#
# auto-approval-engine.sh
# Autonomous decision engine that automatically approves production deployments
# based on configured policies and confidence thresholds
#
# This is the framework that can be enabled/disabled via GITHUB_ENV
#
# Usage: ./auto-approval-engine.sh
#

set -e

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "Auto-Approval Engine (Decision Framework)"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

# Load configuration
if [[ -f .github/auto-approval-config.env ]]; then
  # shellcheck source=/dev/null
  source .github/auto-approval-config.env
  echo "✅ Loaded configuration from .github/auto-approval-config.env"
else
  echo "⚠️  No configuration found. Using defaults."
fi

# Configuration defaults (can be overridden by env vars or config file)
AUTO_APPROVAL_ENABLED="${AUTO_APPROVAL_ENABLED:-false}"
MIN_CONFIDENCE_FOR_AUTO="${MIN_CONFIDENCE_FOR_AUTO:-0.90}"
AUTO_APPROVE_ON_PATCH="${AUTO_APPROVE_ON_PATCH:-true}"
AUTO_APPROVE_ON_ADDON_UPDATE="${AUTO_APPROVE_ON_ADDON_UPDATE:-true}"
AUTO_APPROVE_ON_SECURITY_FIX="${AUTO_APPROVE_ON_SECURITY_FIX:-true}"
REQUIRE_MANUAL_ON_COST_INCREASE="${REQUIRE_MANUAL_ON_COST_INCREASE:-true}"
REQUIRE_MANUAL_ON_INFRASTRUCTURE_CHANGE="${REQUIRE_MANUAL_ON_INFRASTRUCTURE_CHANGE:-true}"
NOTIFY_SLACK="${NOTIFY_SLACK:-false}"
SLACK_WEBHOOK="${SLACK_WEBHOOK:-}"
LOG_FILE="artifacts/auto-approval-engine.log"

mkdir -p artifacts

# Helper functions
log_decision() {
  local level="$1"
  local message="$2"
  local timestamp
  timestamp=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  echo "[$timestamp] [$level] $message" | tee -a "$LOG_FILE"
}

notify_slack() {
  local message="$1"
  if [[ "$NOTIFY_SLACK" == "true" && -n "$SLACK_WEBHOOK" ]]; then
    curl -X POST "$SLACK_WEBHOOK" \
      -H 'Content-Type: application/json' \
      -d "{\"text\": \"🤖 Auto-Approval Engine: $message\"}" \
      2>/dev/null || log_decision "WARN" "Failed to send Slack notification"
  fi
}

# ═══════════════════════════════════════════════════════════════════
# Step 1: Load Recommendation from Previous Stage
# ═══════════════════════════════════════════════════════════════════
echo ""
echo "▶ Loading production recommendation..."

if [[ ! -f artifacts/prod-recommendation.json ]]; then
  log_decision "ERROR" "Production recommendation artifact not found"
  notify_slack "⛔ Auto-approval failed: missing prod-recommendation.json"
  exit 1
fi

RECOMMENDATION=$(jq -r '.recommendation // "unknown"' artifacts/prod-recommendation.json)
CONFIDENCE=$(jq -r '.confidence // 0' artifacts/prod-recommendation.json)
BLOCKERS=$(jq '.blockers // []' artifacts/prod-recommendation.json)
BLOCKER_COUNT=$(echo "$BLOCKERS" | jq 'length')

log_decision "INFO" "Recommendation: $RECOMMENDATION (confidence: $CONFIDENCE)"
log_decision "INFO" "Blockers detected: $BLOCKER_COUNT"

# ═══════════════════════════════════════════════════════════════════
# Step 2: Check Auto-Approval Enablement
# ═══════════════════════════════════════════════════════════════════
echo "▶ Checking auto-approval policy..."

if [[ "$AUTO_APPROVAL_ENABLED" != "true" ]]; then
  log_decision "WARN" "Auto-approval is DISABLED. Requiring manual review."
  cat > artifacts/auto-approval-decision.json << EOF
{
  "timestamp": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "decision": "MANUAL_APPROVAL_REQUIRED",
  "reason": "Auto-approval feature is disabled",
  "policy_enabled": false,
  "confidence": $CONFIDENCE
}
EOF
  echo "⏸️  Auto-approval feature is disabled. Manual review required."
  exit 0
fi

log_decision "INFO" "Auto-approval feature is ENABLED"

# ═══════════════════════════════════════════════════════════════════
# Step 3: Analyze Commit/Change Type
# ═══════════════════════════════════════════════════════════════════
echo "▶ Analyzing change type..."

COMMIT_MSG=$(git log -1 --pretty=format:"%s" 2>/dev/null || echo "")
log_decision "INFO" "Last commit: $COMMIT_MSG"

IS_PATCH=false
IS_ADDON_UPDATE=false
IS_SECURITY_FIX=false
IS_INFRASTRUCTURE_CHANGE=false
IS_COST_INCREASE=false

if [[ "$COMMIT_MSG" =~ [Pp]atch|[Ff]ix\(|bump ]]; then
  IS_PATCH=true
  log_decision "INFO" "Change type: PATCH (low risk)"
fi

if [[ "$COMMIT_MSG" =~ [Aa]ddon|[Hh]elm|addon-|plugin ]]; then
  IS_ADDON_UPDATE=true
  log_decision "INFO" "Change type: ADDON_UPDATE (medium risk)"
fi

if [[ "$COMMIT_MSG" =~ [Ss]ecurity|CVE|[Ss]ec-fix|tfsec|checkov ]]; then
  IS_SECURITY_FIX=true
  log_decision "INFO" "Change type: SECURITY_FIX (elevated risk, high priority)"
fi

# Only block for changes to CRITICAL infrastructure modules.
# App-level modules (ecr, app, addons) and tfvars are auto-approvable.
CRITICAL_TF_MODULES="${CRITICAL_TF_MODULES:-vpc eks iam github_oidc}"
CHANGED_TF=$(git diff --name-only HEAD~1 HEAD 2>/dev/null | grep '^terraform/' || true)
if [[ -n "$CHANGED_TF" ]]; then
  while IFS= read -r changed_file; do
    for mod in $CRITICAL_TF_MODULES; do
      if [[ "$changed_file" == "terraform/modules/${mod}/"* ]]; then
        IS_INFRASTRUCTURE_CHANGE=true
        log_decision "INFO" "Change type: CRITICAL_INFRASTRUCTURE_CHANGE — $changed_file"
        break 2
      fi
    done
  done <<< "$CHANGED_TF"
  if [[ "$IS_INFRASTRUCTURE_CHANGE" == "false" ]]; then
    log_decision "INFO" "Terraform changes are in non-critical modules (ecr/app/addons/tfvars) — auto-approvable"
  fi
fi

# Check cost impact
if [[ -f artifacts/cost-impact.json ]]; then
  COST_DELTA=$(jq '.cost_analysis.monthly_delta_usd // 0' artifacts/cost-impact.json)
  if (( $(echo "$COST_DELTA > 500" | bc -l 2>/dev/null || echo "0") )); then
    IS_COST_INCREASE=true
    log_decision "INFO" "Change type: COST_INCREASE (\$$COST_DELTA)"
  fi
fi

# ═══════════════════════════════════════════════════════════════════
# Step 4: Make Auto-Approval Decision
# ═══════════════════════════════════════════════════════════════════
echo "▶ Making auto-approval decision..."

AUTO_APPROVE=false
DECISION_REASON=""

# Blocker check (immediate failure)
if [[ $BLOCKER_COUNT -gt 0 ]]; then
  DECISION_REASON="Blockers detected ($BLOCKER_COUNT issues) - manual review required"
  log_decision "WARN" "$DECISION_REASON"
elif [[ "$RECOMMENDATION" != "AUTO_APPROVE" ]]; then
  DECISION_REASON="Recommendation: $RECOMMENDATION - manual review required"
  log_decision "WARN" "$DECISION_REASON"
elif (( $(echo "$CONFIDENCE < $MIN_CONFIDENCE_FOR_AUTO" | bc -l 2>/dev/null || echo "0") )); then
  DECISION_REASON="Confidence ($CONFIDENCE) below threshold ($MIN_CONFIDENCE_FOR_AUTO)"
  log_decision "WARN" "$DECISION_REASON"
else
  # Confidence and recommendation are good - check change type policies
  
  if [[ "$IS_INFRASTRUCTURE_CHANGE" == "true" ]] && [[ "$REQUIRE_MANUAL_ON_INFRASTRUCTURE_CHANGE" == "true" ]]; then
    DECISION_REASON="Infrastructure change requiring manual approval (policy)"
    log_decision "WARN" "$DECISION_REASON"
  elif [[ "$IS_COST_INCREASE" == "true" ]] && [[ "$REQUIRE_MANUAL_ON_COST_INCREASE" == "true" ]]; then
    DECISION_REASON="Cost increase requiring manual approval (policy)"
    log_decision "WARN" "$DECISION_REASON"
  elif [[ "$IS_PATCH" == "true" ]] && [[ "$AUTO_APPROVE_ON_PATCH" == "true" ]]; then
    AUTO_APPROVE=true
    DECISION_REASON="Patch release - auto-approved"
    log_decision "INFO" "✅ $DECISION_REASON"
  elif [[ "$IS_ADDON_UPDATE" == "true" ]] && [[ "$AUTO_APPROVE_ON_ADDON_UPDATE" == "true" ]]; then
    AUTO_APPROVE=true
    DECISION_REASON="Add-on update - auto-approved"
    log_decision "INFO" "✅ $DECISION_REASON"
  elif [[ "$IS_SECURITY_FIX" == "true" ]] && [[ "$AUTO_APPROVE_ON_SECURITY_FIX" == "true" ]]; then
    AUTO_APPROVE=true
    DECISION_REASON="Security fix - auto-approved (high priority)"
    log_decision "INFO" "✅ $DECISION_REASON"
  elif [[ "$CONFIDENCE" == "1" ]] || (( $(echo "$CONFIDENCE > 0.95" | bc -l 2>/dev/null || echo "0") )); then
    AUTO_APPROVE=true
    DECISION_REASON="Perfect confidence score - auto-approved"
    log_decision "INFO" "✅ $DECISION_REASON"
  else
    DECISION_REASON="Does not match auto-approval criteria - manual review required"
    log_decision "WARN" "$DECISION_REASON"
  fi
fi

# ═══════════════════════════════════════════════════════════════════
# Step 5: Output Decision Artifact
# ═══════════════════════════════════════════════════════════════════

DECISION=$([ "$AUTO_APPROVE" == "true" ] && echo "AUTO_APPROVED" || echo "MANUAL_APPROVAL_REQUIRED")

cat > artifacts/auto-approval-decision.json << EOF
{
  "timestamp": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "decision": "$DECISION",
  "auto_approve": $AUTO_APPROVE,
  "reason": "$DECISION_REASON",
  "confidence": $CONFIDENCE,
  "confidence_threshold": $MIN_CONFIDENCE_FOR_AUTO,
  "blockers": $BLOCKER_COUNT,
  "change_analysis": {
    "is_patch": $IS_PATCH,
    "is_addon_update": $IS_ADDON_UPDATE,
    "is_security_fix": $IS_SECURITY_FIX,
    "is_infrastructure_change": $IS_INFRASTRUCTURE_CHANGE,
    "is_cost_increase": $IS_COST_INCREASE
  },
  "policy_config": {
    "auto_approval_enabled": $([[ "$AUTO_APPROVAL_ENABLED" == "true" ]] && echo "true" || echo "false"),
    "auto_approve_on_patch": $([[ "$AUTO_APPROVE_ON_PATCH" == "true" ]] && echo "true" || echo "false"),
    "auto_approve_on_addon_update": $([[ "$AUTO_APPROVE_ON_ADDON_UPDATE" == "true" ]] && echo "true" || echo "false"),
    "auto_approve_on_security_fix": $([[ "$AUTO_APPROVE_ON_SECURITY_FIX" == "true" ]] && echo "true" || echo "false")
  },
  "auto_approval_engine_version": "1.0"
}
EOF

# ═══════════════════════════════════════════════════════════════════
# Step 6: Output Summary
# ═══════════════════════════════════════════════════════════════════

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "Auto-Approval Decision"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "Decision:              $DECISION"
echo "Reason:               $DECISION_REASON"
echo "Confidence:           $CONFIDENCE / $MIN_CONFIDENCE_FOR_AUTO"
echo ""
echo "Change Analysis:"
echo "  Patch:              $IS_PATCH"
echo "  Addon Update:       $IS_ADDON_UPDATE"
echo "  Security Fix:       $IS_SECURITY_FIX"
echo "  Infrastructure:     $IS_INFRASTRUCTURE_CHANGE"
echo "  Cost Increase:      $IS_COST_INCREASE"
echo ""

if [[ "$AUTO_APPROVE" == "true" ]]; then
  echo "✅ APPROVED: Proceeding to production deployment"
  notify_slack "✅ Production deployment auto-approved ($DECISION_REASON)"
  exit 0
else
  echo "⏸️  MANUAL REVIEW REQUIRED: $DECISION_REASON"
  notify_slack "⏸️  Manual review required: $DECISION_REASON"
  exit 1
fi
