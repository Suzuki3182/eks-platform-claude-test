#!/bin/bash
#
# rollback-decision-agent.sh
# Post-deploy rollout monitoring with autonomous rollback decision.
# Monitors for 10 minutes after deploy, scoring health signals every 60 seconds.
#
# SAFETY CONSTRAINTS:
#   - Only uses `kubectl rollout undo` — never Terraform state revert
#   - Rolls back the app deployment only (never kube-system)
#   - Requires ROLLBACK_AUTO_ENABLED=true to execute (default: assess only)
#
# Usage: ./rollback-decision-agent.sh [ENVIRONMENT] [CLUSTER_NAME]
# Env:   ROLLBACK_AUTO_ENABLED (default: false), ROLLBACK_NAMESPACE (default: app)
#        ROLLBACK_DEPLOYMENT (default: typescript-app)
#        ROLLBACK_MONITOR_SECONDS (default: 600), ROLLBACK_POLL_INTERVAL (default: 60)
#

set -euo pipefail

ENVIRONMENT="${1:-prod}"
CLUSTER_NAME="${2:-${CLUSTER_NAME:-}}"
ROLLBACK_AUTO_ENABLED="${ROLLBACK_AUTO_ENABLED:-false}"
ROLLBACK_NAMESPACE="${ROLLBACK_NAMESPACE:-app}"
ROLLBACK_DEPLOYMENT="${ROLLBACK_DEPLOYMENT:-typescript-app}"
MONITOR_SECONDS="${ROLLBACK_MONITOR_SECONDS:-600}"
POLL_INTERVAL="${ROLLBACK_POLL_INTERVAL:-60}"
ROLLBACK_THRESHOLD="${ROLLBACK_THRESHOLD:-0.35}"  # confidence below this = rollback

REPORT_FILE="artifacts/rollback-decision-report.json"
LOG_FILE="artifacts/rollback-decision-agent.log"

mkdir -p artifacts

log() {
  local ts
  ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  echo "[$ts] $*" | tee -a "$LOG_FILE"
}

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "Rollback Decision Agent"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
log "environment=$ENVIRONMENT deployment=$ROLLBACK_NAMESPACE/$ROLLBACK_DEPLOYMENT"
log "monitor=${MONITOR_SECONDS}s poll=${POLL_INTERVAL}s auto_rollback=$ROLLBACK_AUTO_ENABLED"

if ! command -v kubectl &>/dev/null || ! kubectl cluster-info &>/dev/null 2>&1; then
  log "ERROR: kubectl not available or cluster unreachable"
  cat > "$REPORT_FILE" << EOF
{
  "timestamp": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "environment": "$ENVIRONMENT",
  "decision": "SKIP",
  "reason": "kubectl unavailable",
  "agent_version": "1.0"
}
EOF
  exit 0
fi

# ── Baseline: record deployment state at start ────────────────────────────────
DEPLOY_EXISTS=$(kubectl get deployment "$ROLLBACK_DEPLOYMENT" -n "$ROLLBACK_NAMESPACE" \
  --ignore-not-found -o name 2>/dev/null || echo "")

if [[ -z "$DEPLOY_EXISTS" ]]; then
  log "Deployment $ROLLBACK_NAMESPACE/$ROLLBACK_DEPLOYMENT not found. Skipping monitoring."
  cat > "$REPORT_FILE" << EOF
{
  "timestamp": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "environment": "$ENVIRONMENT",
  "decision": "SKIP",
  "reason": "deployment not found",
  "agent_version": "1.0"
}
EOF
  exit 0
fi

get_restart_count() {
  kubectl get pods -n "$ROLLBACK_NAMESPACE" -l "app=$ROLLBACK_DEPLOYMENT" \
    -o jsonpath='{range .items[*]}{.status.containerStatuses[0].restartCount}{"\n"}{end}' \
    2>/dev/null | awk '{s+=$1} END {print s+0}'
}

get_ready_count() {
  kubectl get deployment "$ROLLBACK_DEPLOYMENT" -n "$ROLLBACK_NAMESPACE" \
    -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "0"
}

get_desired_count() {
  kubectl get deployment "$ROLLBACK_DEPLOYMENT" -n "$ROLLBACK_NAMESPACE" \
    -o jsonpath='{.spec.replicas}' 2>/dev/null || echo "1"
}

get_crashloop_count() {
  kubectl get pods -n "$ROLLBACK_NAMESPACE" -l "app=$ROLLBACK_DEPLOYMENT" \
    --no-headers 2>/dev/null | grep -c "CrashLoopBackOff\|OOMKilled\|Error" || echo "0"
}

BASELINE_RESTARTS=$(get_restart_count)
DESIRED=$(get_desired_count)
log "Baseline: desired=$DESIRED baseline_restarts=$BASELINE_RESTARTS"

# ── Polling loop ──────────────────────────────────────────────────────────────
ITERATIONS=$(( MONITOR_SECONDS / POLL_INTERVAL ))
HEALTH_SCORES=()
OBSERVATIONS=()
ROLLBACK_TRIGGERED=false

for i in $(seq 1 "$ITERATIONS"); do
  sleep "$POLL_INTERVAL"

  READY=$(get_ready_count)
  CURRENT_RESTARTS=$(get_restart_count)
  CRASHLOOPS=$(get_crashloop_count)
  NEW_RESTARTS=$(( CURRENT_RESTARTS - BASELINE_RESTARTS ))
  ELAPSED=$(( i * POLL_INTERVAL ))

  log "Poll $i/$ITERATIONS (${ELAPSED}s): ready=$READY/$DESIRED restarts_delta=$NEW_RESTARTS crashloops=$CRASHLOOPS"

  # ── Score this observation (0.0 - 1.0) ──────────────────────────────────
  SCORE=1.0

  # Availability signal: penalize hard if ready < desired
  if [[ "$DESIRED" -gt 0 ]]; then
    AVAILABILITY=$(echo "scale=2; $READY / $DESIRED" | bc -l 2>/dev/null || echo "1")
    if (( $(echo "$AVAILABILITY < 0.5" | bc -l 2>/dev/null || echo 0) )); then
      SCORE=$(echo "scale=2; $SCORE * 0.3" | bc -l)
      log "SIGNAL: availability $READY/$DESIRED (score penalty -70%)"
    elif (( $(echo "$AVAILABILITY < 1.0" | bc -l 2>/dev/null || echo 0) )); then
      SCORE=$(echo "scale=2; $SCORE * 0.7" | bc -l)
      log "SIGNAL: partial availability $READY/$DESIRED (score penalty -30%)"
    fi
  fi

  # Restart storm signal
  if [[ "$NEW_RESTARTS" -gt 10 ]]; then
    SCORE=$(echo "scale=2; $SCORE * 0.1" | bc -l)
    log "SIGNAL: restart storm ($NEW_RESTARTS new restarts)"
  elif [[ "$NEW_RESTARTS" -gt 5 ]]; then
    SCORE=$(echo "scale=2; $SCORE * 0.4" | bc -l)
    log "SIGNAL: elevated restarts ($NEW_RESTARTS)"
  elif [[ "$NEW_RESTARTS" -gt 2 ]]; then
    SCORE=$(echo "scale=2; $SCORE * 0.7" | bc -l)
    log "SIGNAL: moderate restarts ($NEW_RESTARTS)"
  fi

  # CrashLoopBackOff signal
  if [[ "$CRASHLOOPS" -gt 0 ]]; then
    SCORE=$(echo "scale=2; $SCORE * 0.2" | bc -l)
    log "SIGNAL: $CRASHLOOPS pod(s) in CrashLoopBackOff"
  fi

  HEALTH_SCORES+=("$SCORE")
  OBSERVATIONS+=("{\"iteration\":$i,\"elapsed_seconds\":$ELAPSED,\"ready\":$READY,\"desired\":$DESIRED,\"restarts_delta\":$NEW_RESTARTS,\"crashloops\":$CRASHLOOPS,\"score\":$SCORE}")

  # Early rollback trigger: if score is catastrophically low and we're past first poll
  if [[ "$i" -ge 2 ]]; then
    AVG_SCORE=$(printf '%s\n' "${HEALTH_SCORES[@]}" | \
      awk '{s+=$1; c++} END {printf "%.2f", s/c}')

    if (( $(echo "$AVG_SCORE < $ROLLBACK_THRESHOLD" | bc -l 2>/dev/null || echo 0) )); then
      log "ROLLBACK SIGNAL: avg_score=$AVG_SCORE below threshold=$ROLLBACK_THRESHOLD (early exit at poll $i)"
      break
    fi
  fi
done

# ── Final decision ────────────────────────────────────────────────────────────
FINAL_AVG=$(printf '%s\n' "${HEALTH_SCORES[@]}" | \
  awk '{s+=$1; c++} END {printf "%.2f", s/c}')
FINAL_READY=$(get_ready_count)
FINAL_RESTARTS=$(( $(get_restart_count) - BASELINE_RESTARTS ))

log "Final: avg_score=$FINAL_AVG ready=$FINAL_READY/$DESIRED total_new_restarts=$FINAL_RESTARTS"

DECISION="HEALTHY"
REASON="avg_health_score=$FINAL_AVG above rollback_threshold=$ROLLBACK_THRESHOLD"

if (( $(echo "$FINAL_AVG < $ROLLBACK_THRESHOLD" | bc -l 2>/dev/null || echo 0) )); then
  DECISION="ROLLBACK"
  REASON="avg_health_score=$FINAL_AVG below rollback_threshold=$ROLLBACK_THRESHOLD"
  log "DECISION: ROLLBACK ($REASON)"

  if [[ "$ROLLBACK_AUTO_ENABLED" == "true" ]]; then
    log "AUTO-ROLLBACK: Executing kubectl rollout undo deployment/$ROLLBACK_DEPLOYMENT -n $ROLLBACK_NAMESPACE"
    kubectl rollout undo "deployment/$ROLLBACK_DEPLOYMENT" -n "$ROLLBACK_NAMESPACE" 2>&1 | tee -a "$LOG_FILE"
    ROLLBACK_TRIGGERED=true
    log "Rollback command sent. Waiting 30s for rollout to begin..."
    sleep 30
    kubectl rollout status "deployment/$ROLLBACK_DEPLOYMENT" -n "$ROLLBACK_NAMESPACE" --timeout=120s 2>&1 | tee -a "$LOG_FILE" || true
  else
    log "AUTO-ROLLBACK disabled (set ROLLBACK_AUTO_ENABLED=true to enable)"
  fi
else
  log "DECISION: HEALTHY ($REASON)"
fi

OBS_JSON=$(printf '%s\n' "${OBSERVATIONS[@]:-}" | jq -s '.' 2>/dev/null || echo "[]")

cat > "$REPORT_FILE" << EOF
{
  "timestamp": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "environment": "$ENVIRONMENT",
  "deployment": "$ROLLBACK_NAMESPACE/$ROLLBACK_DEPLOYMENT",
  "decision": "$DECISION",
  "reason": "$REASON",
  "rollback_triggered": $ROLLBACK_TRIGGERED,
  "auto_rollback_enabled": $([[ "$ROLLBACK_AUTO_ENABLED" == "true" ]] && echo "true" || echo "false"),
  "metrics": {
    "avg_health_score": $FINAL_AVG,
    "rollback_threshold": $ROLLBACK_THRESHOLD,
    "final_ready_replicas": $FINAL_READY,
    "desired_replicas": $DESIRED,
    "total_new_restarts": $FINAL_RESTARTS,
    "monitor_duration_seconds": $MONITOR_SECONDS,
    "observations_count": ${#OBSERVATIONS[@]}
  },
  "observations": $OBS_JSON,
  "agent_version": "1.0"
}
EOF

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "Rollback Decision: $DECISION"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "Avg health score:  $FINAL_AVG (threshold: $ROLLBACK_THRESHOLD)"
echo "Reason:            $REASON"
echo "Rollback executed: $ROLLBACK_TRIGGERED"
echo ""

if [[ "$DECISION" == "ROLLBACK" ]] && [[ "$ROLLBACK_TRIGGERED" == "false" ]]; then
  echo "WARNING: Rollback needed but ROLLBACK_AUTO_ENABLED is false. Manual intervention required."
  exit 1
fi

exit 0
