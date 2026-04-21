#!/usr/bin/env bash
# Autonomous pipeline validation agent — orchestrates stage handoffs and emits
# structured JSON status artifacts for the next stage to consume.
set -euo pipefail

STAGE="${1:?Usage: $0 <stage>  (test|staging|prod)}"
ARTIFACT_DIR="${ARTIFACT_DIR:-artifacts}"
AGENT_OUTPUT="${ARTIFACT_DIR}/agent-output.json"
TIMEOUT_SECONDS=300
START_TIME=$(date +%s)

GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info()  { echo -e "${GREEN}[AGENT]${NC}  $(date -u +%T) $*"; }
log_warn()  { echo -e "${YELLOW}[AGENT]${NC}  $(date -u +%T) $*"; }
log_error() { echo -e "${RED}[AGENT]${NC}  $(date -u +%T) $*"; }
log_stage() { echo -e "\n${BLUE}[STAGE]${NC}  ═══ $* ═══"; }

# ──────────────────────────────────────────────
# Helpers
# ──────────────────────────────────────────────
check_timeout() {
  local elapsed=$(( $(date +%s) - START_TIME ))
  if [[ $elapsed -gt $TIMEOUT_SECONDS ]]; then
    emit_status "failure" "Agent timed out after ${TIMEOUT_SECONDS}s"
    exit 1
  fi
}

emit_status() {
  local status="$1"
  local reason="$2"
  local elapsed=$(( $(date +%s) - START_TIME ))

  mkdir -p "$ARTIFACT_DIR"
  cat > "$AGENT_OUTPUT" << EOF
{
  "stage": "$STAGE",
  "status": "$status",
  "reason": "$reason",
  "timestamp": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "elapsed_seconds": $elapsed,
  "commit": "${GITHUB_SHA:-local}",
  "run_id": "${GITHUB_RUN_ID:-local}",
  "actor": "${GITHUB_ACTOR:-local}"
}
EOF

  log_info "Status artifact written to $AGENT_OUTPUT"
  cat "$AGENT_OUTPUT"
}

assert_command() {
  command -v "$1" &>/dev/null || {
    log_error "Required command not found: $1"
    emit_status "failure" "Missing required command: $1"
    exit 1
  }
}

# ──────────────────────────────────────────────
# Pre-flight checks
# ──────────────────────────────────────────────
log_stage "Pre-flight checks for stage: $STAGE"

assert_command kubectl
assert_command jq
assert_command aws

log_info "kubectl version: $(kubectl version --client -o json | jq -r '.clientVersion.gitVersion')"
log_info "AWS CLI version: $(aws --version)"

# ──────────────────────────────────────────────
# Parse Terraform apply output (if present)
# ──────────────────────────────────────────────
log_stage "Parsing Terraform apply output"
check_timeout

if [[ -f apply_output.txt ]]; then
  APPLY_RESOURCES=$(grep -c "^  +" apply_output.txt 2>/dev/null || echo "0")
  APPLY_CHANGED=$(grep -c "Apply complete" apply_output.txt 2>/dev/null || echo "0")
  APPLY_ERRORS=$(grep -c "Error:" apply_output.txt 2>/dev/null || echo "0")

  if [[ "$APPLY_ERRORS" -gt 0 ]]; then
    log_error "Terraform apply contained $APPLY_ERRORS error(s)"
    grep "Error:" apply_output.txt | head -20
    emit_status "failure" "Terraform apply errors: $APPLY_ERRORS"
    exit 1
  fi

  log_info "Terraform apply: $APPLY_RESOURCES resource(s) changed, $APPLY_ERRORS error(s)"
else
  log_warn "No apply_output.txt found — skipping Terraform output parse"
fi

# ──────────────────────────────────────────────
# Security scan result validation
# ──────────────────────────────────────────────
log_stage "Validating security scan results"
check_timeout

if [[ -f tfsec-results.json ]]; then
  CRITICAL=$(jq '[.results[] | select(.severity == "CRITICAL")] | length' tfsec-results.json 2>/dev/null || echo "0")
  HIGH=$(jq '[.results[] | select(.severity == "HIGH")] | length' tfsec-results.json 2>/dev/null || echo "0")

  if [[ "$CRITICAL" -gt 0 ]] || [[ "$HIGH" -gt 0 ]]; then
    log_error "tfsec: $CRITICAL CRITICAL and $HIGH HIGH findings"
    emit_status "failure" "Security gate: tfsec CRITICAL=$CRITICAL HIGH=$HIGH"
    exit 1
  fi
  log_info "tfsec: No CRITICAL or HIGH findings"
else
  log_warn "tfsec-results.json not found — skipping tfsec validation"
fi

if [[ -f checkov-results.json ]]; then
  FAILED=$(jq '.summary.failed // 0' checkov-results.json 2>/dev/null || echo "0")
  if [[ "$FAILED" -gt 10 ]]; then
    log_error "Checkov: $FAILED policy violations (threshold: 10)"
    emit_status "failure" "Security gate: checkov violations=$FAILED"
    exit 1
  fi
  log_info "Checkov: $FAILED violation(s) (within threshold)"
else
  log_warn "checkov-results.json not found — skipping checkov validation"
fi

# ──────────────────────────────────────────────
# Stage-specific validation logic
# ──────────────────────────────────────────────
case "$STAGE" in

  test)
    log_stage "Test stage validation"
    check_timeout

    # Verify cluster is reachable
    if ! kubectl cluster-info &>/dev/null; then
      emit_status "failure" "Cannot reach cluster API server"
      exit 1
    fi
    log_info "Cluster API server reachable"

    # Verify minimum nodes
    READY_NODES=$(kubectl get nodes --no-headers 2>/dev/null | grep -c " Ready " || echo 0)
    if [[ "$READY_NODES" -lt 1 ]]; then
      emit_status "failure" "No ready nodes in test cluster"
      exit 1
    fi
    log_info "Ready nodes: $READY_NODES"

    # Verify kube-system healthy
    PENDING_PODS=$(kubectl get pods -n kube-system --field-selector=status.phase=Pending \
      --no-headers 2>/dev/null | wc -l || echo 0)
    if [[ "$PENDING_PODS" -gt 5 ]]; then
      emit_status "failure" "Too many pending pods in kube-system: $PENDING_PODS"
      exit 1
    fi

    emit_status "success" "Test stage validation passed — nodes=$READY_NODES, pending_pods=$PENDING_PODS"
    ;;

  staging)
    log_stage "Staging stage validation"
    check_timeout

    if ! kubectl cluster-info &>/dev/null; then
      emit_status "failure" "Cannot reach cluster API server"
      exit 1
    fi

    READY_NODES=$(kubectl get nodes --no-headers 2>/dev/null | grep -c " Ready " || echo 0)
    log_info "Ready nodes: $READY_NODES"

    # Verify cluster autoscaler is operational
    CA_STATUS=$(kubectl get deployment cluster-autoscaler -n kube-system \
      -o jsonpath='{.status.conditions[?(@.type=="Available")].status}' 2>/dev/null || echo "Unknown")
    if [[ "$CA_STATUS" != "True" ]]; then
      log_warn "Cluster autoscaler not Available — status: $CA_STATUS"
    else
      log_info "Cluster autoscaler: Available"
    fi

    # Verify LBC webhook
    LBC_WEBHOOK=$(kubectl get validatingwebhookconfiguration \
      aws-load-balancer-webhook -o name 2>/dev/null || echo "")
    if [[ -n "$LBC_WEBHOOK" ]]; then
      log_info "LBC validating webhook registered"
    else
      log_warn "LBC validating webhook not found"
    fi

    # Check for any namespace stuck in Terminating
    TERMINATING=$(kubectl get namespaces --no-headers 2>/dev/null \
      | grep -c "Terminating" || echo 0)
    if [[ "$TERMINATING" -gt 0 ]]; then
      emit_status "failure" "Namespaces stuck in Terminating: $TERMINATING"
      exit 1
    fi

    emit_status "success" "Staging stage validation passed — nodes=$READY_NODES, ca=$CA_STATUS"
    ;;

  prod)
    log_stage "Production stage validation"
    check_timeout

    if ! kubectl cluster-info &>/dev/null; then
      emit_status "failure" "Cannot reach cluster API server"
      exit 1
    fi

    READY_NODES=$(kubectl get nodes --no-headers 2>/dev/null | grep -c " Ready " || echo 0)
    log_info "Ready nodes: $READY_NODES"

    if [[ "$READY_NODES" -lt 3 ]]; then
      emit_status "failure" "Production requires minimum 3 ready nodes, got $READY_NODES"
      exit 1
    fi

    # Verify all system deployments are available
    UNAVAILABLE=0
    while IFS= read -r line; do
      DEPLOY_NAME=$(echo "$line" | awk '{print $1}')
      DESIRED=$(echo "$line" | awk '{print $2}')
      READY=$(echo "$line" | awk '{print $4}')
      if [[ "$READY" != "$DESIRED" ]]; then
        log_warn "Deployment $DEPLOY_NAME: $READY/$DESIRED ready"
        UNAVAILABLE=$((UNAVAILABLE + 1))
      fi
    done < <(kubectl get deployments -n kube-system --no-headers 2>/dev/null)

    if [[ "$UNAVAILABLE" -gt 0 ]]; then
      emit_status "failure" "Production has $UNAVAILABLE unavailable system deployment(s)"
      exit 1
    fi

    # Final node health taint check
    TAINTED_NODES=$(kubectl get nodes -o json 2>/dev/null \
      | jq '[.items[] | select(.spec.taints != null) | select(.spec.taints[].effect == "NoSchedule")] | length' \
      || echo 0)
    log_info "Nodes with NoSchedule taint: $TAINTED_NODES"

    # Verify EBS CSI is healthy for prod storage
    EBS_READY=$(kubectl get deployment ebs-csi-controller -n kube-system \
      -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "0")
    if [[ "${EBS_READY:-0}" -lt 2 ]]; then
      emit_status "failure" "EBS CSI requires 2 ready replicas in prod, got $EBS_READY"
      exit 1
    fi

    emit_status "success" "Production stage validation passed — nodes=$READY_NODES, unavailable_deployments=$UNAVAILABLE, ebs_csi=$EBS_READY"
    ;;

  *)
    log_error "Unknown stage: $STAGE (must be test|staging|prod)"
    emit_status "failure" "Unknown stage: $STAGE"
    exit 1
    ;;
esac

ELAPSED=$(( $(date +%s) - START_TIME ))
log_info "Agent completed in ${ELAPSED}s"
exit 0
