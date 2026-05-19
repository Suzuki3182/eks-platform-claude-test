#!/usr/bin/env bash
# K8s cluster health check for CI/CD pipeline validation agents.
set -euo pipefail

CLUSTER_NAME="${1:?Usage: $0 <cluster-name> <aws-region>}"
AWS_REGION="${2:?Usage: $0 <cluster-name> <aws-region>}"
export AWS_REGION  # Used externally by kubectl context selection
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

safe_count() {
  local cmd="$1"
  local out
  if out=$(eval "$cmd" 2>/dev/null); then
    echo "$out" | tr -d '[:space:]'
  else
    echo "0"
  fi
}

kctl() {
  kubectl --request-timeout=10s "$@"
}

aws_fallback_healthcheck() {
  log_warn "Kubernetes API endpoint is not reachable from this runner. Falling back to AWS EKS API health checks."

  # CHECK A1: Cluster status
  log_check "AWS API: Cluster Status"
  CLUSTER_STATUS=$(aws eks describe-cluster --name "$CLUSTER_NAME" --region "$AWS_REGION" --query 'cluster.status' --output text 2>/dev/null || echo "UNKNOWN")
  if [[ "$CLUSTER_STATUS" == "ACTIVE" ]]; then
    pass "Cluster status is ACTIVE"
  else
    fail "Cluster status is $CLUSTER_STATUS"
  fi

  # CHECK A2: Endpoint access posture
  log_check "AWS API: Endpoint Access Posture"
  ENDPOINT_PRIVATE=$(aws eks describe-cluster --name "$CLUSTER_NAME" --region "$AWS_REGION" --query 'cluster.resourcesVpcConfig.endpointPrivateAccess' --output text 2>/dev/null || echo "False")
  if [[ "$ENDPOINT_PRIVATE" == "True" ]]; then
    pass "Private endpoint access is enabled"
  else
    fail "Private endpoint access is not enabled"
  fi

  # CHECK A3: Node group discovery
  log_check "AWS API: Node Group Discovery"
  NODEGROUPS=$(aws eks list-nodegroups --cluster-name "$CLUSTER_NAME" --region "$AWS_REGION" --query 'nodegroups' --output text 2>/dev/null || true)
  if [[ -n "$NODEGROUPS" && "$NODEGROUPS" != "None" ]]; then
    pass "Node groups found: $NODEGROUPS"
  else
    fail "No node groups found"
  fi

  # CHECK A4/A5/A6: Node group status, desired capacity, health issues
  log_check "AWS API: Node Group Health"
  local ng_failed=0
  local total_desired=0
  if [[ -n "$NODEGROUPS" && "$NODEGROUPS" != "None" ]]; then
    for ng in $NODEGROUPS; do
      NG_STATUS=$(aws eks describe-nodegroup --cluster-name "$CLUSTER_NAME" --nodegroup-name "$ng" --region "$AWS_REGION" --query 'nodegroup.status' --output text 2>/dev/null || echo "UNKNOWN")
      NG_DESIRED=$(aws eks describe-nodegroup --cluster-name "$CLUSTER_NAME" --nodegroup-name "$ng" --region "$AWS_REGION" --query 'nodegroup.scalingConfig.desiredSize' --output text 2>/dev/null || echo "0")
      NG_ISSUES=$(aws eks describe-nodegroup --cluster-name "$CLUSTER_NAME" --nodegroup-name "$ng" --region "$AWS_REGION" --query 'length(nodegroup.health.issues)' --output text 2>/dev/null || echo "999")

      total_desired=$((total_desired + NG_DESIRED))

      if [[ "$NG_STATUS" != "ACTIVE" ]]; then
        ng_failed=$((ng_failed + 1))
        fail "Node group $ng status is $NG_STATUS"
      fi

      if [[ "$NG_ISSUES" -gt 0 ]]; then
        ng_failed=$((ng_failed + 1))
        fail "Node group $ng has $NG_ISSUES health issue(s)"
      fi
    done
  fi

  if [[ "$ng_failed" -eq 0 ]]; then
    pass "All node groups are ACTIVE with no health issues"
  fi

  if [[ "$total_desired" -gt 0 ]]; then
    pass "Total desired node count is $total_desired"
  else
    fail "Desired node count is zero"
  fi

  # CHECK A7: Core addons status
  log_check "AWS API: Core Addons"
  local addon_failures=0
  for addon in coredns kube-proxy vpc-cni aws-ebs-csi-driver; do
    if aws eks describe-addon --cluster-name "$CLUSTER_NAME" --addon-name "$addon" --region "$AWS_REGION" --query 'addon.status' --output text >/tmp/addon_status.txt 2>/dev/null; then
      ADDON_STATUS=$(cat /tmp/addon_status.txt)
      if [[ "$ADDON_STATUS" == "ACTIVE" ]]; then
        pass "Addon $addon is ACTIVE"
      else
        addon_failures=$((addon_failures + 1))
        fail "Addon $addon status is $ADDON_STATUS"
      fi
    fi
  done
  rm -f /tmp/addon_status.txt
  if [[ "$addon_failures" -eq 0 ]]; then
    pass "All detected core addons are ACTIVE"
  fi

  # CHECK A8: OIDC issuer availability
  log_check "AWS API: OIDC Issuer"
  OIDC_ISSUER=$(aws eks describe-cluster --name "$CLUSTER_NAME" --region "$AWS_REGION" --query 'cluster.identity.oidc.issuer' --output text 2>/dev/null || true)
  if [[ -n "$OIDC_ISSUER" && "$OIDC_ISSUER" != "None" ]]; then
    pass "OIDC issuer is configured"
  else
    fail "OIDC issuer is not configured"
  fi
}

# Helper function for future use — currently invoked via healthcheck procedures
# shellcheck disable=SC2317
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

if ! kctl get --raw='/readyz' >/dev/null 2>&1; then
  aws_fallback_healthcheck
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

  log_info "All health checks PASSED (AWS API fallback mode)"
  exit 0
fi

TOTAL_NODES=$(safe_count "kctl get nodes --no-headers | wc -l")
READY_NODES=$(safe_count "kctl get nodes --no-headers | grep -c ' Ready '")
NOT_READY=$(safe_count "kctl get nodes --no-headers | grep -c 'NotReady'")

if [[ "$TOTAL_NODES" -eq 0 ]]; then
  fail "No nodes found in cluster"
elif [[ "$NOT_READY" -gt 0 ]]; then
  fail "$NOT_READY/$TOTAL_NODES nodes are NotReady"
  kctl get nodes --no-headers | grep NotReady
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
  if kctl get deployment "$deploy" -n kube-system &>/dev/null; then
    DESIRED=$(kctl get deployment "$deploy" -n kube-system -o jsonpath='{.spec.replicas}')
    READY=$(kctl get deployment "$deploy" -n kube-system -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo 0)
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
  if kctl get daemonset "$ds" -n kube-system &>/dev/null; then
    DESIRED=$(kctl get daemonset "$ds" -n kube-system -o jsonpath='{.status.desiredNumberScheduled}')
    READY=$(kctl get daemonset "$ds" -n kube-system -o jsonpath='{.status.numberReady}' 2>/dev/null || echo 0)
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
DNS_RESULT=$(kctl run "$DNS_TEST_POD" \
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
kctl delete pod "$DNS_TEST_POD" --ignore-not-found &>/dev/null || true

# ──────────────────────────────────────────────
# CHECK 4: Ingress Connectivity
# ──────────────────────────────────────────────
log_check "Ingress Controller (AWS LBC)"
check_timeout

LBC_ENDPOINT=$(kctl get deployment aws-load-balancer-controller \
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

EBS_CSI=$(kctl get deployment ebs-csi-controller -n kube-system \
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

SCHEDULABLE=$(kctl get nodes --no-headers | grep -vc "SchedulingDisabled")
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

CNI_DESIRED=$(kctl get daemonset aws-node -n kube-system \
  -o jsonpath='{.status.desiredNumberScheduled}' 2>/dev/null || echo "0")
CNI_READY=$(kctl get daemonset aws-node -n kube-system \
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

CRASHLOOP_PODS=$(kctl get pods -n kube-system \
  --field-selector=status.phase!=Succeeded \
  -o jsonpath='{range .items[*]}{.metadata.name}{" "}{range .status.containerStatuses[*]}{.state.waiting.reason}{"\n"}{end}{end}' 2>/dev/null \
  | grep -c "CrashLoopBackOff" || echo 0)

if [[ "$CRASHLOOP_PODS" -eq 0 ]]; then
  pass "No CrashLoopBackOff pods in kube-system"
else
  fail "$CRASHLOOP_PODS pod(s) in CrashLoopBackOff in kube-system"
  kctl get pods -n kube-system | grep CrashLoopBackOff || true
fi

# ──────────────────────────────────────────────
# CHECK 9: TypeScript Application
# Hard failure when namespace exists; warn-only when not yet deployed.
# ──────────────────────────────────────────────
log_check "TypeScript Application"
check_timeout

if kctl get namespace app &>/dev/null; then
  # Deployment ready
  APP_DESIRED=$(kctl get deployment typescript-app -n app \
    -o jsonpath='{.spec.replicas}' 2>/dev/null || echo "0")
  APP_READY=$(kctl get deployment typescript-app -n app \
    -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "0")
  if [[ "${APP_DESIRED:-0}" -gt 0 ]]; then
    if [[ "${APP_READY:-0}" -ge "${APP_DESIRED}" ]]; then
      pass "TypeScript App Deployment: $APP_READY/$APP_DESIRED ready"
    else
      fail "TypeScript App Deployment: only $APP_READY/$APP_DESIRED ready"
    fi
  else
    fail "TypeScript App Deployment: desired replicas is 0 or Deployment not found"
  fi

  # No CrashLoopBackOff in app namespace
  APP_CRASHLOOP=$(kctl get pods -n app \
    --field-selector=status.phase!=Succeeded \
    -o jsonpath='{range .items[*]}{.metadata.name}{" "}{range .status.containerStatuses[*]}{.state.waiting.reason}{"\n"}{end}{end}' 2>/dev/null \
    | grep -c "CrashLoopBackOff" || echo 0)
  if [[ "$APP_CRASHLOOP" -eq 0 ]]; then
    pass "No CrashLoopBackOff pods in app namespace"
  else
    fail "$APP_CRASHLOOP app pod(s) in CrashLoopBackOff"
    kctl get pods -n app | grep CrashLoopBackOff || true
  fi
else
  log_warn "app namespace not found — skipping TypeScript app health checks (not yet deployed)"
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
