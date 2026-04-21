#!/usr/bin/env bash
# K8s cluster health check for CI/CD pipeline validation agents.
set -euo pipefail

CLUSTER_NAME="${1:?Usage: $0 <cluster-name> <aws-region>}"
AWS_REGION="${2:?Usage: $0 <cluster-name> <aws-region>}"
TIMEOUT=300
START_TIME=$(date +%s)

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

CHECKS_PASSED=0
CHECKS_FAILED=0
FAILURES=()

log_info()    { echo -e "${GREEN}[INFO]${NC}  $(date -u +%T) $*"; }
log_warn()    { echo -e "${YELLOW}[WARN]${NC}  $(date -u +%T) $*"; }
log_error()   { echo -e "${RED}[ERROR]${NC} $(date -u +%T) $*"; }
log_check()   { echo -e "\n${GREEN}[CHECK]${NC} $*"; }

pass() {
  log_info "PASS: $1"
  CHECKS_PASSED=$((CHECKS_PASSED + 1))
}

fail() {
  log_error "FAIL: $1"
  CHECKS_FAILED=$((CHECKS_FAILED + 1))
  FAILURES+=("$1")
}

check_timeout() {
  local elapsed=$(( $(date +%s) - START_TIME ))
  if [[ $elapsed -gt $TIMEOUT ]]; then
    log_error "Health check timed out after ${TIMEOUT}s"
    exit 1
  fi
}

wait_for_condition() {
  local resource="$1"
  local condition="$2"
  local namespace="$3"
  local timeout="${4:-120}"

  kubectl wait "$resource" \
    --for="condition=$condition" \
    -n "$namespace" \
    --timeout="${timeout}s" 2>&1
}

# ──────────────────────────────────────────────
# CHECK 1: Node Readiness
# ──────────────────────────────────────────────
log_check "Node Readiness"
check_timeout

TOTAL_NODES=$(kubectl get nodes --no-headers 2>/dev/null | wc -l || echo 0)
READY_NODES=$(kubectl get nodes --no-headers 2>/dev/null | grep -c " Ready " || echo 0)
NOT_READY=$(kubectl get nodes --no-headers 2>/dev/null | grep -c "NotReady" || echo 0)

if [[ "$TOTAL_NODES" -eq 0 ]]; then
  fail "No nodes found in cluster"
elif [[ "$NOT_READY" -gt 0 ]]; then
  fail "$NOT_READY/$TOTAL_NODES nodes are NotReady"
  kubectl get nodes --no-headers | grep NotReady
else
  pass "All $READY_NODES/$TOTAL_NODES nodes are Ready"
fi

# ──────────────────────────────────────────────
# CHECK 2: System Pod Readiness
# ──────────────────────────────────────────────
log_check "System Pod Readiness (kube-system)"
check_timeout

CRITICAL_DEPLOYMENTS=(
  "coredns"
  "aws-load-balancer-controller"
  "cluster-autoscaler"
  "metrics-server"
)

for deploy in "${CRITICAL_DEPLOYMENTS[@]}"; do
  if kubectl get deployment "$deploy" -n kube-system &>/dev/null; then
    DESIRED=$(kubectl get deployment "$deploy" -n kube-system -o jsonpath='{.spec.replicas}')
    READY=$(kubectl get deployment "$deploy" -n kube-system -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo 0)
    if [[ "${READY:-0}" -ge "${DESIRED:-1}" ]]; then
      pass "Deployment $deploy: $READY/$DESIRED ready"
    else
      fail "Deployment $deploy: only $READY/$DESIRED ready"
    fi
  else
    log_warn "Deployment $deploy not found (may be expected)"
  fi
done

# Check DaemonSets
CRITICAL_DAEMONSETS=("aws-node" "kube-proxy")
for ds in "${CRITICAL_DAEMONSETS[@]}"; do
  if kubectl get daemonset "$ds" -n kube-system &>/dev/null; then
    DESIRED=$(kubectl get daemonset "$ds" -n kube-system -o jsonpath='{.status.desiredNumberScheduled}')
    READY=$(kubectl get daemonset "$ds" -n kube-system -o jsonpath='{.status.numberReady}' 2>/dev/null || echo 0)
    if [[ "${READY:-0}" -ge "${DESIRED:-1}" ]]; then
      pass "DaemonSet $ds: $READY/$DESIRED ready"
    else
      fail "DaemonSet $ds: only $READY/$DESIRED ready"
    fi
  fi
done

# ──────────────────────────────────────────────
# CHECK 3: DNS Resolution
# ──────────────────────────────────────────────
log_check "DNS Resolution"
check_timeout

DNS_TEST_POD="dns-test-$$"
DNS_RESULT=$(kubectl run "$DNS_TEST_POD" \
  --image=busybox:1.28 \
  --restart=Never \
  --rm \
  -i \
  --timeout=60s \
  -- nslookup kubernetes.default.svc.cluster.local 2>&1) && DNS_EXIT=0 || DNS_EXIT=$?

if [[ $DNS_EXIT -eq 0 ]]; then
  pass "DNS resolution: kubernetes.default.svc.cluster.local resolved"
else
  fail "DNS resolution failed: $DNS_RESULT"
fi

# Cleanup stale pod if any
kubectl delete pod "$DNS_TEST_POD" --ignore-not-found &>/dev/null || true

# ──────────────────────────────────────────────
# CHECK 4: Ingress Connectivity
# ──────────────────────────────────────────────
log_check "Ingress Controller (AWS LBC)"
check_timeout

LBC_ENDPOINT=$(kubectl get deployment aws-load-balancer-controller \
  -n kube-system \
  -o jsonpath='{.status.conditions[?(@.type=="Available")].status}' 2>/dev/null || echo "False")

if [[ "$LBC_ENDPOINT" == "True" ]]; then
  pass "AWS Load Balancer Controller is Available"
else
  fail "AWS Load Balancer Controller is not Available (status: $LBC_ENDPOINT)"
fi

# ──────────────────────────────────────────────
# CHECK 5: EBS CSI Driver
# ──────────────────────────────────────────────
log_check "EBS CSI Driver"
check_timeout

EBS_CSI=$(kubectl get deployment ebs-csi-controller -n kube-system \
  -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "0")

if [[ "${EBS_CSI:-0}" -ge 1 ]]; then
  pass "EBS CSI controller ready ($EBS_CSI replicas)"
else
  fail "EBS CSI controller not ready"
fi

# ──────────────────────────────────────────────
# CHECK 6: Node-to-Node Connectivity (via pod scheduling)
# ──────────────────────────────────────────────
log_check "Pod Scheduling Across Nodes"
check_timeout

SCHEDULABLE=$(kubectl get nodes --no-headers | grep -v "SchedulingDisabled" | wc -l)
if [[ "$SCHEDULABLE" -gt 1 ]]; then
  pass "Multiple nodes schedulable: $SCHEDULABLE"
else
  log_warn "Only $SCHEDULABLE schedulable node(s) — single-node or draining in progress"
fi

# ──────────────────────────────────────────────
# CHECK 7: VPC CNI (aws-node)
# ──────────────────────────────────────────────
log_check "VPC CNI Health"
check_timeout

CNI_DESIRED=$(kubectl get daemonset aws-node -n kube-system \
  -o jsonpath='{.status.desiredNumberScheduled}' 2>/dev/null || echo "0")
CNI_READY=$(kubectl get daemonset aws-node -n kube-system \
  -o jsonpath='{.status.numberReady}' 2>/dev/null || echo "0")

if [[ "${CNI_READY:-0}" -eq "${CNI_DESIRED:-0}" ]] && [[ "${CNI_DESIRED:-0}" -gt 0 ]]; then
  pass "VPC CNI ready: $CNI_READY/$CNI_DESIRED"
else
  fail "VPC CNI not fully ready: $CNI_READY/$CNI_DESIRED"
fi

# ──────────────────────────────────────────────
# CHECK 8: No CrashLoopBackOff pods in kube-system
# ──────────────────────────────────────────────
log_check "No CrashLoopBackOff Pods"
check_timeout

CRASHLOOP_PODS=$(kubectl get pods -n kube-system \
  --field-selector=status.phase!=Succeeded \
  -o jsonpath='{range .items[*]}{.metadata.name}{" "}{range .status.containerStatuses[*]}{.state.waiting.reason}{"\n"}{end}{end}' 2>/dev/null \
  | grep -c "CrashLoopBackOff" || echo 0)

if [[ "$CRASHLOOP_PODS" -eq 0 ]]; then
  pass "No CrashLoopBackOff pods in kube-system"
else
  fail "$CRASHLOOP_PODS pod(s) in CrashLoopBackOff in kube-system"
  kubectl get pods -n kube-system | grep CrashLoopBackOff || true
fi

# ──────────────────────────────────────────────
# Final Summary
# ──────────────────────────────────────────────
TOTAL=$((CHECKS_PASSED + CHECKS_FAILED))
ELAPSED=$(( $(date +%s) - START_TIME ))

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  Health Check Summary — Cluster: $CLUSTER_NAME"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  Total:  $TOTAL checks"
echo "  Passed: $CHECKS_PASSED"
echo "  Failed: $CHECKS_FAILED"
echo "  Elapsed: ${ELAPSED}s"

if [[ ${#FAILURES[@]} -gt 0 ]]; then
  echo ""
  echo "  Failed checks:"
  for f in "${FAILURES[@]}"; do
    echo "    - $f"
  done
fi

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

if [[ "$CHECKS_FAILED" -gt 0 ]]; then
  log_error "Health check FAILED with $CHECKS_FAILED failure(s)"
  exit 1
fi

log_info "All health checks PASSED"
exit 0
