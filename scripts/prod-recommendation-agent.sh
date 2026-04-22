#!/bin/bash
#
# prod-recommendation-agent.sh
# Aggregates all deployment signals to recommend production approval
# Outputs: artifacts/prod-recommendation.json
#
# This is the foundation for auto-approval decision engine
# Analyzes: cost impact, security scans, health checks, drift, staging status, compliance
#
# Usage: ./prod-recommendation-agent.sh
#

set -e

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "Production Recommendation Agent"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

mkdir -p artifacts

# Initialize recommendation scores (0-100)
declare -A scores
declare -a signals
declare -a warnings
declare -a blockers

# Configuration thresholds
ACCEPTABLE_SECURITY_CRITICAL=0
ACCEPTABLE_SECURITY_HIGH=3
ACCEPTABLE_DRIFT_RESOURCES=0
MIN_CONFIDENCE=0.80

echo ""
echo "Analyzing deployment signals..."
echo ""

# ═══════════════════════════════════════════════════════════════════
# SIGNAL 1: Staging Gate Status
# ═══════════════════════════════════════════════════════════════════
echo "▶ Signal 1: Staging Environment Status"
if [[ -f staging-artifacts/agent-output.json ]]; then
  STAGING_STATUS=$(jq -r '.status // "unknown"' staging-artifacts/agent-output.json 2>/dev/null || echo "unknown")
  if [[ "$STAGING_STATUS" == "success" ]]; then
    scores[staging_gate]="100"
    signals+=("✅ Staging gate: PASSED")
    echo "   Status: PASSED"
  else
    scores[staging_gate]="0"
    blockers+=("Staging gate failed - cannot promote to production")
    echo "   Status: FAILED"
  fi
else
  scores[staging_gate]="0"
  blockers+=("Staging gate artifact missing - cannot verify staging status")
  echo "   Status: MISSING ARTIFACT"
fi

# ═══════════════════════════════════════════════════════════════════
# SIGNAL 2: Security Scan Results
# ═══════════════════════════════════════════════════════════════════
echo "▶ Signal 2: Security Scan Results"
SECURITY_SCORE=100
CRITICAL_FOUND=0
HIGH_FOUND=0

if [[ -f tfsec-results.json ]]; then
  CRITICAL_FOUND=$(jq '[.results[] | select(.severity == "CRITICAL")] | length' tfsec-results.json 2>/dev/null || echo "0")
  HIGH_FOUND=$(jq '[.results[] | select(.severity == "HIGH")] | length' tfsec-results.json 2>/dev/null || echo "0")
  
  if [[ "$CRITICAL_FOUND" -gt "$ACCEPTABLE_SECURITY_CRITICAL" ]]; then
    SECURITY_SCORE=0
    blockers+=("Found $CRITICAL_FOUND CRITICAL security issues (unacceptable)")
    echo "   tfsec: ⛔ $CRITICAL_FOUND CRITICAL findings"
  elif [[ "$HIGH_FOUND" -gt "$ACCEPTABLE_SECURITY_HIGH" ]]; then
    SECURITY_SCORE=$((100 - (HIGH_FOUND * 20)))
    warnings+=("Found $HIGH_FOUND HIGH severity issues (review recommended)")
    echo "   tfsec: ⚠️  $HIGH_FOUND HIGH findings"
  else
    signals+=("✅ Security scan: PASSED (tfsec clean)")
    echo "   tfsec: OK ($HIGH_FOUND HIGH, $CRITICAL_FOUND CRITICAL)"
  fi
else
  warnings+=("tfsec results not found - cannot verify security")
  SECURITY_SCORE=50
  echo "   tfsec: MISSING"
fi

if [[ -f checkov-results.json ]]; then
  CHECKOV_FAILED=$(jq '.summary.failed // 0' checkov-results.json 2>/dev/null || echo "0")
  if [[ "$CHECKOV_FAILED" -gt 10 ]]; then
    warnings+=("Checkov found $CHECKOV_FAILED policy violations")
    SECURITY_SCORE=$((SECURITY_SCORE - 20))
    echo "   checkov: ⚠️  $CHECKOV_FAILED violations"
  else
    echo "   checkov: OK ($CHECKOV_FAILED violations)"
  fi
fi

scores[security]="$SECURITY_SCORE"

# ═══════════════════════════════════════════════════════════════════
# SIGNAL 3: Cost Impact Analysis
# ═══════════════════════════════════════════════════════════════════
echo "▶ Signal 3: Cost Impact Analysis"
COST_SCORE=100
if [[ -f artifacts/cost-impact.json ]]; then
  COST_DELTA=$(jq '.cost_analysis.monthly_delta_usd // 0' artifacts/cost-impact.json 2>/dev/null || echo "0")
  COST_THRESHOLD=$(jq '.cost_analysis.threshold_usd // 5000' artifacts/cost-impact.json 2>/dev/null || echo "5000")
  
  if (( $(echo "$COST_DELTA > $COST_THRESHOLD" | bc -l 2>/dev/null || echo "0") )); then
    warnings+=("Monthly cost increase \$$COST_DELTA exceeds threshold \$$COST_THRESHOLD")
    COST_SCORE=$((100 - ((${COST_DELTA%.*} - ${COST_THRESHOLD%.*}) / 100)))
    [[ $COST_SCORE -lt 0 ]] && COST_SCORE=0
    echo "   ⚠️  Monthly delta: \$$COST_DELTA (threshold: \$$COST_THRESHOLD)"
  else
    signals+=("✅ Cost impact acceptable: \$$COST_DELTA")
    echo "   Monthly delta: \$$COST_DELTA (within threshold)"
  fi
else
  warnings+=("Cost impact artifact not found - cannot verify cost implications")
  COST_SCORE=75
  echo "   MISSING cost artifact"
fi
scores[cost_impact]="$COST_SCORE"

# ═══════════════════════════════════════════════════════════════════
# SIGNAL 4: Infrastructure Drift Detection
# ═══════════════════════════════════════════════════════════════════
echo "▶ Signal 4: Infrastructure Drift"
DRIFT_SCORE=100
# Check if terraform plan shows unexpected changes
if [[ -f /tmp/plan.json ]]; then
  DRIFT_CHANGES=$(jq '.resource_changes | length' /tmp/plan.json 2>/dev/null || echo "0")
  if [[ "$DRIFT_CHANGES" -gt "$ACCEPTABLE_DRIFT_RESOURCES" ]]; then
    warnings+=("Detected $DRIFT_CHANGES unexpected resource changes (manual drift?)")
    DRIFT_SCORE=$((100 - (DRIFT_CHANGES * 10)))
    [[ $DRIFT_SCORE -lt 0 ]] && DRIFT_SCORE=0
    echo "   ⚠️  Unexpected changes: $DRIFT_CHANGES resources"
  else
    signals+=("✅ No infrastructure drift detected")
    echo "   OK - no unexpected drift"
  fi
else
  echo "   Plan not available (may be normal)"
fi
scores[drift]="$DRIFT_SCORE"

# ═══════════════════════════════════════════════════════════════════
# SIGNAL 5: Cluster Health Check
# ═══════════════════════════════════════════════════════════════════
echo "▶ Signal 5: Cluster Health"
HEALTH_SCORE=100
if [[ -f healthcheck_output.txt ]]; then
  HEALTH_CHECKS=$(grep -c "✅ PASSED" healthcheck_output.txt 2>/dev/null || echo "0")
  HEALTH_FAILURES=$(grep -c "❌ FAILED" healthcheck_output.txt 2>/dev/null || echo "0")
  
  if [[ "$HEALTH_FAILURES" -gt 0 ]]; then
    blockers+=("Cluster health check failed - $HEALTH_FAILURES issues detected")
    HEALTH_SCORE=0
    echo "   ⛔ $HEALTH_FAILURES failures"
  else
    signals+=("✅ All cluster health checks passed ($HEALTH_CHECKS checks)")
    echo "   OK - $HEALTH_CHECKS checks passed"
  fi
else
  warnings+=("Health check output not found")
  HEALTH_SCORE=75
  echo "   MISSING health check"
fi
scores[cluster_health]="$HEALTH_SCORE"

# ═══════════════════════════════════════════════════════════════════
# SIGNAL 6: Timeline & Change Volume
# ═══════════════════════════════════════════════════════════════════
echo "▶ Signal 6: Change Volume & Risk"
CHANGE_SCORE=100
if [[ -f /tmp/changelog_raw.txt ]]; then
  COMMIT_COUNT=$(wc -l < /tmp/changelog_raw.txt 2>/dev/null || echo "1")
  if [[ $COMMIT_COUNT -gt 20 ]]; then
    warnings+=("High change volume ($COMMIT_COUNT commits) - increased risk")
    CHANGE_SCORE=$((100 - (COMMIT_COUNT / 5)))
    [[ $CHANGE_SCORE -lt 50 ]] && CHANGE_SCORE=50
    echo "   ⚠️  High commit volume: $COMMIT_COUNT commits"
  else
    signals+=("✅ Moderate change volume: $COMMIT_COUNT commits")
    echo "   OK - $COMMIT_COUNT commits"
  fi
else
  echo "   Changelog not available"
fi
scores[change_volume]="$CHANGE_SCORE"

# ═══════════════════════════════════════════════════════════════════
# CALCULATE OVERALL RECOMMENDATION
# ═══════════════════════════════════════════════════════════════════
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "Signal Analysis"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

# Calculate weighted confidence
TOTAL_SCORE=0
WEIGHT_COUNT=0

for score_name in "${!scores[@]}"; do
  score_value=${scores[$score_name]}
  TOTAL_SCORE=$((TOTAL_SCORE + score_value))
  WEIGHT_COUNT=$((WEIGHT_COUNT + 1))
done

if [[ $WEIGHT_COUNT -gt 0 ]]; then
  CONFIDENCE=$(echo "scale=2; $TOTAL_SCORE / $WEIGHT_COUNT / 100" | bc -l 2>/dev/null || echo "0.00")
else
  CONFIDENCE="0.00"
fi

# Determine recommendation
AUTO_APPROVE=false
if [[ ${#blockers[@]} -eq 0 ]] && (( $(echo "$CONFIDENCE > $MIN_CONFIDENCE" | bc -l 2>/dev/null || echo "0") )); then
  AUTO_APPROVE=true
  RECOMMENDATION="AUTO_APPROVE"
  REASON="All signals green, confidence $CONFIDENCE exceeds threshold"
else
  RECOMMENDATION="MANUAL_REVIEW"
  if [[ ${#blockers[@]} -gt 0 ]]; then
    REASON="Blockers detected (${#blockers[@]} issues)"
  else
    REASON="Confidence $CONFIDENCE below threshold $MIN_CONFIDENCE"
  fi
fi

# Display analysis
echo "Confidence Scores:"
for score_name in "${!scores[@]}"; do
  printf "  %-20s %3d/100\n" "$score_name:" "${scores[$score_name]}"
done
echo ""
echo "Overall Confidence: $CONFIDENCE (target: $MIN_CONFIDENCE)"
echo "Recommendation:     $RECOMMENDATION"
echo ""

if [[ ${#signals[@]} -gt 0 ]]; then
  echo "Positive Signals (${#signals[@]}):"
  for signal in "${signals[@]}"; do
    echo "  $signal"
  done
  echo ""
fi

if [[ ${#warnings[@]} -gt 0 ]]; then
  echo "Warnings (${#warnings[@]}):"
  for warning in "${warnings[@]}"; do
    echo "  ⚠️  $warning"
  done
  echo ""
fi

if [[ ${#blockers[@]} -gt 0 ]]; then
  echo "Blockers (${#blockers[@]}):"
  for blocker in "${blockers[@]}"; do
    echo "  ⛔ $blocker"
  done
  echo ""
fi

# ═══════════════════════════════════════════════════════════════════
# OUTPUT ARTIFACT
# ═══════════════════════════════════════════════════════════════════

# Prepare JSON arrays
SIGNALS_JSON=$(printf '%s\n' "${signals[@]}" | jq -R -s -c 'split("\n") | map(select(length > 0))')
WARNINGS_JSON=$(printf '%s\n' "${warnings[@]}" | jq -R -s -c 'split("\n") | map(select(length > 0))')
BLOCKERS_JSON=$(printf '%s\n' "${blockers[@]}" | jq -R -s -c 'split("\n") | map(select(length > 0))')

cat > artifacts/prod-recommendation.json << EOF
{
  "timestamp": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "stage": "production",
  "recommendation": "$RECOMMENDATION",
  "auto_approve": $AUTO_APPROVE,
  "reason": "$REASON",
  "confidence": $CONFIDENCE,
  "confidence_threshold": $MIN_CONFIDENCE,
  "confidence_scores": {
    "staging_gate": ${scores[staging_gate]:-0},
    "security": ${scores[security]:-0},
    "cost_impact": ${scores[cost_impact]:-0},
    "drift": ${scores[drift]:-0},
    "cluster_health": ${scores[cluster_health]:-0},
    "change_volume": ${scores[change_volume]:-0}
  },
  "signals": $SIGNALS_JSON,
  "warnings": $WARNINGS_JSON,
  "blockers": $BLOCKERS_JSON,
  "decision_engine_version": "1.0"
}
EOF

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "Recommendation artifact written to: artifacts/prod-recommendation.json"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

if [[ ${#blockers[@]} -gt 0 ]]; then
  echo "⛔ RECOMMENDATION: MANUAL REVIEW REQUIRED"
  exit 1
else
  echo "✅ RECOMMENDATION: SAFE TO DEPLOY"
  if [[ "$AUTO_APPROVE" == "true" ]]; then
    echo "   Auto-approval eligible if policy enabled"
  fi
  exit 0
fi
