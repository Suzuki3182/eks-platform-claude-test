#!/bin/bash
#
# cluster-selfheal-agent.sh
# Reactive Kubernetes self-healing agent. Runs every 15 minutes via GitHub Actions.
#
# SAFETY CONSTRAINTS:
#   - Max 1 pod restart per deployment per 30-minute window (cooldown)
#   - Cordons but NEVER drains nodes (draining reduces capacity)
#   - Only restarts deployments, never StatefulSets or DaemonSets autonomously
#   - Minimum healthy pod floor: never act if ready_pods < min_replicas/2
#
# Usage: ./cluster-selfheal-agent.sh [CLUSTER_NAME] [AWS_REGION]
# Env:   KUBECONFIG (must already be configured), SELFHEAL_DRY_RUN (default: false)
#

set -euo pipefail

CLUSTER_NAME="${1:-${CLUSTER_NAME:-}}"
AWS_REGION="${2:-${AWS_REGION:-us-east-1}}"
DRY_RUN="${SELFHEAL_DRY_RUN:-false}"
COOLDOWN_DIR="/tmp/selfheal-cooldown"
COOLDOWN_WINDOW=1800  # 30 minutes in seconds
REPORT_FILE="artifacts/selfheal-report.json"
LOG_FILE="artifacts/selfheal-agent.log"

mkdir -p artifacts "$COOLDOWN_DIR"

log() {
  local ts
  ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  echo "[$ts] $*" | tee -a "$LOG_FILE"
}

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "Cluster Self-Heal Agent"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
log "cluster=${CLUSTER_NAME} region=${AWS_REGION} dry_run=${DRY_RUN}"

# ── Verify kubectl is available ───────────────────────────────────────────────
if ! command -v kubectl &>/dev/null; then
  log "ERROR: kubectl not found"
  exit 1
fi

if ! kubectl cluster-info &>/dev/null 2>&1; then
  log "ERROR: kubectl cannot reach cluster API. Check KUBECONFIG."
  exit 1
fi

ACTIONS=()
NODES_CORDONED=()
PODS_RESTARTED=()
ADDONS_RECOVERED=()

record_action() {
  ACTIONS+=("{\"type\":\"$1\",\"target\":\"$2\",\"namespace\":\"${3:-}\",\"reason\":\"$4\",\"applied\":$5}")
}

# ── Helper: cooldown check ────────────────────────────────────────────────────
is_on_cooldown() {
  local key="$1"
  local safe_key
  safe_key=$(echo "$key" | tr '/' '_' | tr ' ' '_')
  local cooldown_file="$COOLDOWN_DIR/$safe_key"

  if [[ -f "$cooldown_file" ]]; then
    local last_action
    last_action=$(cat "$cooldown_file")
    local now
    now=$(date +%s)
    local elapsed=$(( now - last_action ))
    if [[ "$elapsed" -lt "$COOLDOWN_WINDOW" ]]; then
      log "COOLDOWN: $key (${elapsed}s ago, window=${COOLDOWN_WINDOW}s)"
      return 0
    fi
  fi
  return 1
}

mark_cooldown() {
  local key="$1"
  local safe_key
  safe_key=$(echo "$key" | tr '/' '_' | tr ' ' '_')
  date +%s > "$COOLDOWN_DIR/$safe_key"
}

# ── 1. Node health: cordon NotReady nodes ─────────────────────────────────────
log "Checking node health..."

while IFS= read -r line; do
  node_name=$(echo "$line" | awk '{print $1}')
  node_status=$(echo "$line" | awk '{print $2}')

  if [[ "$node_status" == "NotReady" ]]; then
    log "NODE NotReady: $node_name"

    # Don't re-cordon already cordoned nodes
    already_cordoned=$(kubectl get node "$node_name" -o jsonpath='{.spec.unschedulable}' 2>/dev/null || echo "false")
    if [[ "$already_cordoned" == "true" ]]; then
      log "SKIP: $node_name already cordoned"
      continue
    fi

    if is_on_cooldown "node/$node_name"; then
      record_action "cordon" "$node_name" "" "NotReady" "false"
      continue
    fi

    if [[ "$DRY_RUN" == "true" ]]; then
      log "DRY-RUN: Would cordon $node_name"
      record_action "cordon" "$node_name" "" "NotReady (dry-run)" "false"
    else
      log "CORDONING: $node_name (NotReady)"
      kubectl cordon "$node_name" 2>&1 | tee -a "$LOG_FILE" || true
      mark_cooldown "node/$node_name"
      NODES_CORDONED+=("$node_name")
      record_action "cordon" "$node_name" "" "NotReady" "true"
    fi
  fi
done < <(kubectl get nodes --no-headers 2>/dev/null | awk '{print $1, $2}' || true)

# ── 2. Pod self-healing: restart CrashLoopBackOff deployments ─────────────────
log "Checking pod health across namespaces..."

NAMESPACES=$(kubectl get namespaces -o jsonpath='{.items[*].metadata.name}' 2>/dev/null || echo "")

for ns in $NAMESPACES; do
  # Skip system namespaces that should not be auto-healed
  if [[ "$ns" =~ ^(kube-node-lease|cert-manager)$ ]]; then
    continue
  fi

  while IFS= read -r pod_line; do
    pod_name=$(echo "$pod_line" | awk '{print $1}')
    pod_status=$(echo "$pod_line" | awk '{print $3}')
    restart_count=$(echo "$pod_line" | awk '{print $4}')

    if [[ "$pod_status" == "CrashLoopBackOff" ]] || \
       [[ "$pod_status" == "OOMKilled" ]] || \
       { [[ "$pod_status" == "Error" ]] && [[ "$restart_count" -gt 5 ]]; }; then

      log "UNHEALTHY POD: $ns/$pod_name (status=$pod_status restarts=$restart_count)"

      # Find owning deployment
      owner=$(kubectl get pod "$pod_name" -n "$ns" \
        -o jsonpath='{.metadata.ownerReferences[0].kind}:{.metadata.ownerReferences[0].name}' \
        2>/dev/null || echo "")
      owner_kind=$(echo "$owner" | cut -d: -f1)
      owner_name=$(echo "$owner" | cut -d: -f2)

      # Only auto-restart Deployment-owned pods
      if [[ "$owner_kind" != "ReplicaSet" ]]; then
        log "SKIP: $pod_name owned by $owner_kind (only Deployments are auto-healed)"
        record_action "skip_restart" "$pod_name" "$ns" "non-deployment owner: $owner_kind" "false"
        continue
      fi

      # Resolve deployment name from ReplicaSet
      deploy_name=$(kubectl get replicaset "$owner_name" -n "$ns" \
        -o jsonpath='{.metadata.ownerReferences[0].name}' \
        2>/dev/null || echo "$owner_name")

      if is_on_cooldown "deploy/$ns/$deploy_name"; then
        record_action "skip_restart" "$pod_name" "$ns" "on cooldown" "false"
        continue
      fi

      # Safety floor: ensure deployment won't go below half of minReplicas
      desired=$(kubectl get deployment "$deploy_name" -n "$ns" \
        -o jsonpath='{.spec.replicas}' 2>/dev/null || echo "1")
      ready=$(kubectl get deployment "$deploy_name" -n "$ns" \
        -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "0")
      floor=$(( desired / 2 ))

      if [[ "$ready" -le "$floor" ]]; then
        log "SKIP: $deploy_name in $ns has only $ready/$desired ready pods (floor=$floor). Not safe to restart."
        record_action "skip_restart" "$pod_name" "$ns" "below safety floor" "false"
        continue
      fi

      if [[ "$DRY_RUN" == "true" ]]; then
        log "DRY-RUN: Would delete pod $pod_name in $ns to trigger restart"
        record_action "restart_pod" "$pod_name" "$ns" "$pod_status (dry-run)" "false"
      else
        log "RESTARTING: Deleting $pod_name in $ns to trigger rollout..."
        kubectl delete pod "$pod_name" -n "$ns" --grace-period=10 2>&1 | tee -a "$LOG_FILE" || true
        mark_cooldown "deploy/$ns/$deploy_name"
        PODS_RESTARTED+=("$ns/$pod_name")
        record_action "restart_pod" "$pod_name" "$ns" "$pod_status restarts=$restart_count" "true"
      fi
    fi
  done < <(kubectl get pods -n "$ns" --no-headers 2>/dev/null | \
    awk '{print $1, $2, $3, $4}' || true)
done

# ── 3. Add-on recovery: restart system deployments with 0 ready replicas ─────
log "Checking critical add-on health..."

CRITICAL_ADDONS=(
  "kube-system:aws-load-balancer-controller"
  "kube-system:cluster-autoscaler"
  "kube-system:coredns"
  "kube-system:metrics-server"
)

for addon_ref in "${CRITICAL_ADDONS[@]}"; do
  addon_ns=$(echo "$addon_ref" | cut -d: -f1)
  addon_name=$(echo "$addon_ref" | cut -d: -f2)

  ready=$(kubectl get deployment "$addon_name" -n "$addon_ns" \
    -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "-1")
  desired=$(kubectl get deployment "$addon_name" -n "$addon_ns" \
    -o jsonpath='{.spec.replicas}' 2>/dev/null || echo "1")

  if [[ "$ready" == "-1" ]]; then
    log "NOT FOUND: $addon_ns/$addon_name (may not be deployed)"
    continue
  fi

  if [[ "$ready" -eq 0 ]]; then
    log "CRITICAL ADDON DOWN: $addon_ns/$addon_name (ready=0 desired=$desired)"

    if is_on_cooldown "addon/$addon_ns/$addon_name"; then
      record_action "skip_addon_recovery" "$addon_name" "$addon_ns" "on cooldown" "false"
      continue
    fi

    if [[ "$DRY_RUN" == "true" ]]; then
      log "DRY-RUN: Would rollout restart $addon_name in $addon_ns"
      record_action "addon_recovery" "$addon_name" "$addon_ns" "0 ready replicas (dry-run)" "false"
    else
      log "RECOVERING: kubectl rollout restart deployment/$addon_name -n $addon_ns"
      kubectl rollout restart "deployment/$addon_name" -n "$addon_ns" 2>&1 | tee -a "$LOG_FILE" || true
      mark_cooldown "addon/$addon_ns/$addon_name"
      ADDONS_RECOVERED+=("$addon_ns/$addon_name")
      record_action "addon_recovery" "$addon_name" "$addon_ns" "0 ready replicas" "true"
    fi
  else
    log "OK: $addon_ns/$addon_name ($ready/$desired ready)"
  fi
done

# ── Write report ──────────────────────────────────────────────────────────────
ACTIONS_JSON=$(printf '%s\n' "${ACTIONS[@]:-}" | jq -s '.' 2>/dev/null || echo "[]")
APPLIED_COUNT=$(printf '%s\n' "${ACTIONS[@]:-}" | jq -s '[.[] | select(.applied==true)] | length' 2>/dev/null || echo "0")

cat > "$REPORT_FILE" << EOF
{
  "timestamp": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "cluster": "${CLUSTER_NAME:-unknown}",
  "dry_run": $DRY_RUN,
  "actions_taken": $APPLIED_COUNT,
  "nodes_cordoned": ${#NODES_CORDONED[@]},
  "pods_restarted": ${#PODS_RESTARTED[@]},
  "addons_recovered": ${#ADDONS_RECOVERED[@]},
  "actions": $ACTIONS_JSON,
  "agent_version": "1.0"
}
EOF

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "Self-Heal Summary"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "Nodes cordoned:    ${#NODES_CORDONED[@]}"
echo "Pods restarted:    ${#PODS_RESTARTED[@]}"
echo "Add-ons recovered: ${#ADDONS_RECOVERED[@]}"
echo "Total actions:     $APPLIED_COUNT"
echo ""
echo "Report: $REPORT_FILE"
exit 0
