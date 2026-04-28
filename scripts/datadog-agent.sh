#!/usr/bin/env bash
# Autonomous Datadog configuration agent.
# Validates API connectivity, waits for DaemonSet readiness and metric ingestion,
# then idempotently creates 7 monitors and 1 EKS Overview dashboard.
# Designed for zero human intervention inside the CI/CD pipeline.
#
# Usage: scripts/datadog-agent.sh <cluster-name> <aws-region> <environment>
#
# Required env vars:
#   DD_API_KEY  — Datadog API key (exits loudly if missing)
#   DD_APP_KEY  — Datadog App key (monitor/dashboard creation skipped if absent)
# Optional env vars:
#   DD_SITE     — Datadog intake site (default: datadoghq.com)
set -euo pipefail

# ──────────────────────────────────────────────
# Args & environment
# ──────────────────────────────────────────────
CLUSTER_NAME="${1:?Usage: $0 <cluster-name> <aws-region> <environment>}"
AWS_REGION="${2:?Usage: $0 <cluster-name> <aws-region> <environment>}"
ENVIRONMENT="${3:?Usage: $0 <cluster-name> <aws-region> <environment>}"

DD_API_KEY="${DD_API_KEY:-}"
DD_APP_KEY="${DD_APP_KEY:-}"
DD_SITE="${DD_SITE:-datadoghq.com}"

ARTIFACT_DIR="${ARTIFACT_DIR:-artifacts}"
ARTIFACT_FILE="${ARTIFACT_DIR}/datadog-agent.json"

DAEMONSET_WAIT_SECONDS="${DAEMONSET_WAIT_SECONDS:-300}"
METRICS_WAIT_SECONDS="${METRICS_WAIT_SECONDS:-600}"
METRICS_POLL_INTERVAL="${METRICS_POLL_INTERVAL:-30}"

START_TIME=$(date +%s)
TIMEOUT_SECONDS=900

# ──────────────────────────────────────────────
# Colour / logging  (matches existing pipeline agents)
# ──────────────────────────────────────────────
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info()  { echo -e "${GREEN}[AGENT]${NC}  $(date -u +%T) $*"; }
log_warn()  { echo -e "${YELLOW}[AGENT]${NC}  $(date -u +%T) $*"; }
log_error() { echo -e "${RED}[AGENT]${NC}  $(date -u +%T) $*"; }
log_phase() { echo -e "\n${BLUE}[PHASE]${NC}  ═══ $* ═══"; }

# ──────────────────────────────────────────────
# Result accumulators
# ──────────────────────────────────────────────
PHASE_API_VALIDATION="skipped"
PHASE_DAEMONSET_WAIT="skipped"
PHASE_METRICS_WAIT="skipped"
PHASE_MONITORS="skipped"
PHASE_DASHBOARD="skipped"

MONITORS_CREATED=0
MONITORS_UPDATED=0
MONITORS_SKIPPED=0
DASHBOARD_ACTION="skipped"
DASHBOARD_ID=""

# ──────────────────────────────────────────────
# Helpers
# ──────────────────────────────────────────────
check_timeout() {
  local elapsed=$(( $(date +%s) - START_TIME ))
  if [[ $elapsed -gt $TIMEOUT_SECONDS ]]; then
    log_error "Agent timed out after ${TIMEOUT_SECONDS}s"
    emit_artifact "failure" "Agent timed out after ${TIMEOUT_SECONDS}s"
    exit 1
  fi
}

assert_command() {
  command -v "$1" &>/dev/null || {
    log_error "Required command not found: $1"
    emit_artifact "failure" "Missing required command: $1"
    exit 1
  }
}

# dd_api <METHOD> <PATH> [extra curl args...]
# Injects DD-API-KEY; adds DD-APPLICATION-KEY only when DD_APP_KEY is set.
dd_api() {
  local method="$1"; shift
  local path="$1";   shift
  local url="https://api.${DD_SITE}${path}"

  local -a headers=( -H "DD-API-KEY: ${DD_API_KEY}" )
  if [[ -n "${DD_APP_KEY}" ]]; then
    headers+=( -H "DD-APPLICATION-KEY: ${DD_APP_KEY}" )
  fi

  curl --silent --fail --show-error \
    --max-time 30 \
    -X "${method}" "${url}" \
    "${headers[@]}" \
    "$@"
}

# dd_api_json — like dd_api but adds Content-Type: application/json
dd_api_json() {
  local method="$1"; shift
  local path="$1";   shift
  dd_api "${method}" "${path}" \
    -H "Content-Type: application/json" \
    "$@"
}

emit_artifact() {
  local status="$1"
  local reason="$2"
  local elapsed=$(( $(date +%s) - START_TIME ))

  mkdir -p "${ARTIFACT_DIR}"
  cat > "${ARTIFACT_FILE}" << ARTIFACT_EOF
{
  "agent": "datadog-agent",
  "cluster_name": "${CLUSTER_NAME}",
  "environment": "${ENVIRONMENT}",
  "aws_region": "${AWS_REGION}",
  "dd_site": "${DD_SITE}",
  "status": "${status}",
  "reason": "${reason}",
  "timestamp": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "elapsed_seconds": ${elapsed},
  "commit": "${GITHUB_SHA:-local}",
  "run_id": "${GITHUB_RUN_ID:-local}",
  "actor": "${GITHUB_ACTOR:-local}",
  "phases": {
    "api_validation": "${PHASE_API_VALIDATION}",
    "daemonset_wait": "${PHASE_DAEMONSET_WAIT}",
    "metrics_wait":   "${PHASE_METRICS_WAIT}",
    "monitors":       "${PHASE_MONITORS}",
    "dashboard":      "${PHASE_DASHBOARD}"
  },
  "resources": {
    "monitors_created": ${MONITORS_CREATED},
    "monitors_updated": ${MONITORS_UPDATED},
    "monitors_skipped": ${MONITORS_SKIPPED},
    "dashboard_action": "${DASHBOARD_ACTION}",
    "dashboard_id":     "${DASHBOARD_ID}"
  }
}
ARTIFACT_EOF

  log_info "Artifact written → ${ARTIFACT_FILE}"
  cat "${ARTIFACT_FILE}"
}

# ══════════════════════════════════════════════════════════════════════
# PRE-FLIGHT
# ══════════════════════════════════════════════════════════════════════
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  Datadog Configuration Agent"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
log_phase "Pre-flight — cluster=${CLUSTER_NAME} env=${ENVIRONMENT} site=${DD_SITE}"

assert_command curl
assert_command jq
assert_command kubectl
assert_command aws

if [[ -z "${DD_API_KEY}" ]]; then
  log_error "DD_API_KEY is not set. Cannot proceed."
  emit_artifact "failure" "DD_API_KEY env var is required but not set"
  exit 1
fi

SKIP_RESOURCE_CREATION=false
if [[ -z "${DD_APP_KEY}" ]]; then
  log_warn "DD_APP_KEY is not set. Monitor and dashboard creation will be skipped."
  SKIP_RESOURCE_CREATION=true
fi

mkdir -p "${ARTIFACT_DIR}"
log_info "cluster=${CLUSTER_NAME}  region=${AWS_REGION}  env=${ENVIRONMENT}  site=${DD_SITE}"
log_info "curl: $(curl --version | head -1 | awk '{print $2}')"
log_info "jq:   $(jq --version)"

# ══════════════════════════════════════════════════════════════════════
# PHASE 1 — Validate Datadog API Key
# ══════════════════════════════════════════════════════════════════════
log_phase "Phase 1 — API key validation"
check_timeout

log_info "Calling GET https://api.${DD_SITE}/api/v1/validate ..."

VALIDATE_RESPONSE=$(dd_api GET /api/v1/validate 2>&1) || {
  log_error "API validation request failed. Check DD_SITE='${DD_SITE}' and network connectivity."
  log_error "Response: ${VALIDATE_RESPONSE}"
  PHASE_API_VALIDATION="failed"
  emit_artifact "failure" "Datadog API validation request failed — check DD_SITE and connectivity"
  exit 1
}

VALID=$(echo "${VALIDATE_RESPONSE}" | jq -r '.valid // false' 2>/dev/null || echo "false")
if [[ "${VALID}" != "true" ]]; then
  log_error "Datadog API key rejected. Response: ${VALIDATE_RESPONSE}"
  PHASE_API_VALIDATION="failed"
  emit_artifact "failure" "Datadog API key is invalid — set the correct DD_API_KEY secret"
  exit 1
fi

log_info "API key is valid."
PHASE_API_VALIDATION="success"

# ══════════════════════════════════════════════════════════════════════
# PHASE 2 — Wait for Datadog Agent DaemonSet readiness
# ══════════════════════════════════════════════════════════════════════
log_phase "Phase 2 — DaemonSet readiness wait (timeout=${DAEMONSET_WAIT_SECONDS}s)"
check_timeout

DD_DS_READY=false
PHASE2_DEADLINE=$(( $(date +%s) + DAEMONSET_WAIT_SECONDS ))

if kubectl --request-timeout=10s get --raw='/readyz' &>/dev/null 2>&1; then
  log_info "Kubernetes API reachable — watching DaemonSet via kubectl."

  while [[ $(date +%s) -lt ${PHASE2_DEADLINE} ]]; do
    check_timeout

    DS_DESIRED=$(kubectl --request-timeout=10s get daemonset datadog \
      -n datadog -o jsonpath='{.status.desiredNumberScheduled}' 2>/dev/null || echo "0")
    DS_READY=$(kubectl --request-timeout=10s get daemonset datadog \
      -n datadog -o jsonpath='{.status.numberReady}' 2>/dev/null || echo "0")

    if [[ "${DS_DESIRED:-0}" -gt 0 ]] && [[ "${DS_READY:-0}" -ge "${DS_DESIRED}" ]]; then
      log_info "DaemonSet ready: ${DS_READY}/${DS_DESIRED} nodes."
      DD_DS_READY=true
      break
    fi

    log_info "DaemonSet: ${DS_READY:-0}/${DS_DESIRED:-0} — waiting 15s..."
    sleep 15
  done

else
  log_warn "Kubernetes API not reachable from runner. Falling back to AWS EKS API."

  CLUSTER_STATUS=$(aws eks describe-cluster \
    --name "${CLUSTER_NAME}" \
    --region "${AWS_REGION}" \
    --query 'cluster.status' \
    --output text 2>/dev/null || echo "UNKNOWN")

  if [[ "${CLUSTER_STATUS}" == "ACTIVE" ]]; then
    log_info "Cluster is ACTIVE via AWS API — assuming DaemonSet is ready."
    DD_DS_READY=true
  else
    log_warn "Cluster status: ${CLUSTER_STATUS}. DaemonSet readiness cannot be confirmed."
  fi
fi

if [[ "${DD_DS_READY}" != "true" ]]; then
  log_warn "DaemonSet did not become ready within ${DAEMONSET_WAIT_SECONDS}s. Continuing."
  PHASE_DAEMONSET_WAIT="timeout"
else
  PHASE_DAEMONSET_WAIT="success"
fi

# ══════════════════════════════════════════════════════════════════════
# PHASE 3 — Wait for kubernetes.cpu.usage.total to arrive in Datadog
# ══════════════════════════════════════════════════════════════════════
log_phase "Phase 3 — Metric ingestion wait (timeout=${METRICS_WAIT_SECONDS}s)"
check_timeout

METRICS_FOUND=false
PHASE3_START=$(date +%s)
PHASE3_DEADLINE=$(( PHASE3_START + METRICS_WAIT_SECONDS ))
ENCODED_CLUSTER=$(python3 -c "import urllib.parse; print(urllib.parse.quote('cluster_name:${CLUSTER_NAME}'))" 2>/dev/null \
  || echo "cluster_name%3A${CLUSTER_NAME}")

while [[ $(date +%s) -lt ${PHASE3_DEADLINE} ]]; do
  check_timeout

  NOW_TS=$(date +%s)
  FROM_TS=$(( NOW_TS - 600 ))
  ENCODED_QUERY=$(python3 -c "import urllib.parse; print(urllib.parse.quote('avg:kubernetes.cpu.usage.total{cluster_name:${CLUSTER_NAME}}'))" 2>/dev/null \
    || echo "avg%3Akubernetes.cpu.usage.total%7Bcluster_name%3A${CLUSTER_NAME}%7D")

  METRIC_RESPONSE=$(dd_api GET \
    "/api/v1/query?from=${FROM_TS}&to=${NOW_TS}&query=${ENCODED_QUERY}" \
    2>/dev/null || echo '{}')

  SERIES_LEN=$(echo "${METRIC_RESPONSE}" | jq '.series | length' 2>/dev/null || echo "0")

  if [[ "${SERIES_LEN:-0}" -gt 0 ]]; then
    POINT_COUNT=$(echo "${METRIC_RESPONSE}" | jq '.series[0].pointlist | length' 2>/dev/null || echo "0")
    if [[ "${POINT_COUNT:-0}" -gt 0 ]]; then
      log_info "Metric kubernetes.cpu.usage.total confirmed for ${CLUSTER_NAME} (${POINT_COUNT} data points)."
      METRICS_FOUND=true
      break
    fi
  fi

  ELAPSED_P3=$(( $(date +%s) - PHASE3_START ))
  log_info "No metric data yet (${ELAPSED_P3}s / ${METRICS_WAIT_SECONDS}s). Retrying in ${METRICS_POLL_INTERVAL}s..."
  sleep "${METRICS_POLL_INTERVAL}"
done

if [[ "${METRICS_FOUND}" != "true" ]]; then
  log_warn "No metric data found after ${METRICS_WAIT_SECONDS}s (expected on first run). Continuing."
  PHASE_METRICS_WAIT="timeout"
else
  PHASE_METRICS_WAIT="success"
fi

# ══════════════════════════════════════════════════════════════════════
# PHASE 4 — Idempotent monitor creation (7 monitors)
# ══════════════════════════════════════════════════════════════════════
log_phase "Phase 4 — Monitor management (idempotent)"
check_timeout

MANAGED_TAG="managed-by:eks-platform-datadog-agent"

if [[ "${SKIP_RESOURCE_CREATION}" == "true" ]]; then
  log_warn "Skipping monitor creation — DD_APP_KEY not set."
  PHASE_MONITORS="skipped"
else
  log_info "Fetching existing managed monitors for cluster=${CLUSTER_NAME} ..."
  EXISTING_MONITORS=$(dd_api_json GET \
    "/api/v1/monitor?tags=${MANAGED_TAG},cluster:${CLUSTER_NAME}&with_downtimes=false" \
    2>/dev/null || echo '[]')

  EXISTING_COUNT=$(echo "${EXISTING_MONITORS}" | jq 'length' 2>/dev/null || echo "0")
  log_info "Found ${EXISTING_COUNT} existing managed monitor(s)."

  # Returns the numeric id of the first monitor whose name contains the pattern, or empty string
  find_monitor_id() {
    local name_pattern="$1"
    echo "${EXISTING_MONITORS}" | jq -r \
      --arg p "${name_pattern}" \
      '[.[] | select(.name | contains($p))] | first | .id // empty' 2>/dev/null || echo ""
  }

  # upsert_monitor <name_pattern> <json_payload>
  upsert_monitor() {
    local name_pattern="$1"
    local payload="$2"
    local monitor_name
    monitor_name=$(echo "${payload}" | jq -r '.name' 2>/dev/null || echo "unknown")

    local existing_id
    existing_id=$(find_monitor_id "${name_pattern}")

    if [[ -n "${existing_id}" ]]; then
      log_info "Updating monitor (id=${existing_id}): ${monitor_name}"
      dd_api_json PUT "/api/v1/monitor/${existing_id}" -d "${payload}" > /dev/null || {
        log_warn "Failed to update monitor id=${existing_id} — skipping."
        MONITORS_SKIPPED=$(( MONITORS_SKIPPED + 1 ))
        return
      }
      MONITORS_UPDATED=$(( MONITORS_UPDATED + 1 ))
    else
      log_info "Creating monitor: ${monitor_name}"
      dd_api_json POST "/api/v1/monitor" -d "${payload}" > /dev/null || {
        log_warn "Failed to create monitor '${monitor_name}' — skipping."
        MONITORS_SKIPPED=$(( MONITORS_SKIPPED + 1 ))
        return
      }
      MONITORS_CREATED=$(( MONITORS_CREATED + 1 ))
    fi
  }

  # ── Monitor 1: Node CPU > 85%
  upsert_monitor "[CPU]" "$(jq -n \
    --arg cluster "${CLUSTER_NAME}" \
    --arg env "${ENVIRONMENT}" \
    '{
      "name": ("[CPU] Node CPU > 85% — " + $cluster),
      "type": "metric alert",
      "query": ("avg(last_5m):avg:system.cpu.user{cluster_name:" + $cluster + "} by {host} + avg:system.cpu.system{cluster_name:" + $cluster + "} by {host} > 85"),
      "message": ("Node CPU exceeds 85% on {{host.name}} in cluster " + $cluster + " (" + $env + ").\n\nMonitor managed by eks-platform-datadog-agent."),
      "tags": [("managed-by:eks-platform-datadog-agent"), ("cluster:" + $cluster), ("env:" + $env)],
      "options": {
        "thresholds": {"critical": 85, "warning": 75},
        "notify_no_data": false,
        "renotify_interval": 30,
        "include_tags": true,
        "evaluation_delay": 60
      },
      "priority": 2
    }')"

  # ── Monitor 2: Node Memory > 90% (pct_usable < 10%)
  upsert_monitor "[Memory]" "$(jq -n \
    --arg cluster "${CLUSTER_NAME}" \
    --arg env "${ENVIRONMENT}" \
    '{
      "name": ("[Memory] Node memory available < 10% — " + $cluster),
      "type": "metric alert",
      "query": ("min(last_5m):avg:system.mem.pct_usable{cluster_name:" + $cluster + "} by {host} < 10"),
      "message": ("Node memory below 10% available (>90% used) on {{host.name}} in cluster " + $cluster + " (" + $env + ").\n\nMonitor managed by eks-platform-datadog-agent."),
      "tags": [("managed-by:eks-platform-datadog-agent"), ("cluster:" + $cluster), ("env:" + $env)],
      "options": {
        "thresholds": {"critical": 10, "warning": 15},
        "notify_no_data": false,
        "renotify_interval": 30,
        "include_tags": true,
        "evaluation_delay": 60
      },
      "priority": 2
    }')"

  # ── Monitor 3: Container restart spike (> 5 restarts in 5 min change)
  upsert_monitor "[Restarts]" "$(jq -n \
    --arg cluster "${CLUSTER_NAME}" \
    --arg env "${ENVIRONMENT}" \
    '{
      "name": ("[Restarts] Container restart spike — " + $cluster),
      "type": "metric alert",
      "query": ("change(sum(last_5m),last_5m):sum:kubernetes_state.container.restarts{cluster_name:" + $cluster + "} by {pod_name,kube_container_name} > 5"),
      "message": ("Container {{kube_container_name.name}} in pod {{pod_name.name}} restarted more than 5 times in 5 min in cluster " + $cluster + " (" + $env + ").\n\nMonitor managed by eks-platform-datadog-agent."),
      "tags": [("managed-by:eks-platform-datadog-agent"), ("cluster:" + $cluster), ("env:" + $env)],
      "options": {
        "thresholds": {"critical": 5, "warning": 3},
        "notify_no_data": false,
        "renotify_interval": 0,
        "include_tags": true,
        "new_group_delay": 60
      },
      "priority": 3
    }')"

  # ── Monitor 4: Node NotReady
  upsert_monitor "[NodeReady]" "$(jq -n \
    --arg cluster "${CLUSTER_NAME}" \
    --arg env "${ENVIRONMENT}" \
    '{
      "name": ("[NodeReady] Node entered NotReady — " + $cluster),
      "type": "metric alert",
      "query": ("max(last_5m):sum:kubernetes_state.node.status{cluster_name:" + $cluster + ",status:ready} by {node} < 1"),
      "message": ("Node {{node.name}} is NotReady in cluster " + $cluster + " (" + $env + ").\n\nMonitor managed by eks-platform-datadog-agent."),
      "tags": [("managed-by:eks-platform-datadog-agent"), ("cluster:" + $cluster), ("env:" + $env)],
      "options": {
        "thresholds": {"critical": 1},
        "notify_no_data": true,
        "no_data_timeframe": 10,
        "renotify_interval": 20,
        "include_tags": true
      },
      "priority": 1
    }')"

  # ── Monitor 5: Deployment unavailable replicas > 0
  upsert_monitor "[Deployment]" "$(jq -n \
    --arg cluster "${CLUSTER_NAME}" \
    --arg env "${ENVIRONMENT}" \
    '{
      "name": ("[Deployment] Unavailable replicas detected — " + $cluster),
      "type": "metric alert",
      "query": ("max(last_5m):sum:kubernetes_state.deployment.replicas_unavailable{cluster_name:" + $cluster + "} by {deployment,kube_namespace} > 0"),
      "message": ("Deployment {{deployment.name}} in namespace {{kube_namespace.name}} has unavailable replicas in cluster " + $cluster + " (" + $env + ").\n\nMonitor managed by eks-platform-datadog-agent."),
      "tags": [("managed-by:eks-platform-datadog-agent"), ("cluster:" + $cluster), ("env:" + $env)],
      "options": {
        "thresholds": {"critical": 0},
        "notify_no_data": false,
        "renotify_interval": 30,
        "include_tags": true,
        "new_group_delay": 120
      },
      "priority": 2
    }')"

  # ── Monitor 6: Node disk usage > 85%  (0.0–1.0 scale)
  upsert_monitor "[Disk]" "$(jq -n \
    --arg cluster "${CLUSTER_NAME}" \
    --arg env "${ENVIRONMENT}" \
    '{
      "name": ("[Disk] Node disk usage > 85% — " + $cluster),
      "type": "metric alert",
      "query": ("max(last_5m):max:system.disk.in_use{cluster_name:" + $cluster + "} by {host,device} > 0.85"),
      "message": ("Disk {{device.name}} on {{host.name}} exceeds 85% usage in cluster " + $cluster + " (" + $env + ").\n\nMonitor managed by eks-platform-datadog-agent."),
      "tags": [("managed-by:eks-platform-datadog-agent"), ("cluster:" + $cluster), ("env:" + $env)],
      "options": {
        "thresholds": {"critical": 0.85, "warning": 0.75},
        "notify_no_data": false,
        "renotify_interval": 60,
        "include_tags": true,
        "evaluation_delay": 60
      },
      "priority": 3
    }')"

  # ── Monitor 7: Datadog Agent heartbeat (service check)
  upsert_monitor "[Heartbeat]" "$(jq -n \
    --arg cluster "${CLUSTER_NAME}" \
    --arg env "${ENVIRONMENT}" \
    '{
      "name": ("[Heartbeat] Datadog Agent not reporting — " + $cluster),
      "type": "service check",
      "query": ("\"datadog.agent.up\".over(\"cluster_name:" + $cluster + "\").by(\"host\").last(2).count_by_status()"),
      "message": ("Datadog Agent stopped reporting from {{host.name}} in cluster " + $cluster + " (" + $env + ").\n\nMonitor managed by eks-platform-datadog-agent."),
      "tags": [("managed-by:eks-platform-datadog-agent"), ("cluster:" + $cluster), ("env:" + $env)],
      "options": {
        "thresholds": {"critical": 1, "ok": 1, "warning": 1},
        "notify_no_data": true,
        "no_data_timeframe": 10,
        "renotify_interval": 30,
        "include_tags": true
      },
      "priority": 1
    }')"

  log_info "Monitors done — created=${MONITORS_CREATED} updated=${MONITORS_UPDATED} skipped=${MONITORS_SKIPPED}"
  PHASE_MONITORS="success"
fi

# ══════════════════════════════════════════════════════════════════════
# PHASE 5 — Idempotent EKS Overview dashboard
# ══════════════════════════════════════════════════════════════════════
log_phase "Phase 5 — EKS Overview dashboard (idempotent)"
check_timeout

DASHBOARD_TITLE="EKS Overview — ${CLUSTER_NAME}"

if [[ "${SKIP_RESOURCE_CREATION}" == "true" ]]; then
  log_warn "Skipping dashboard creation — DD_APP_KEY not set."
  PHASE_DASHBOARD="skipped"
else
  log_info "Checking for existing dashboard: '${DASHBOARD_TITLE}'"

  ALL_DASHBOARDS=$(dd_api_json GET "/api/v1/dashboard" 2>/dev/null || echo '{"dashboards":[]}')
  EXISTING_DASH_ID=$(echo "${ALL_DASHBOARDS}" | jq -r \
    --arg title "${DASHBOARD_TITLE}" \
    '.dashboards[] | select(.title == $title) | .id' 2>/dev/null | head -1 || echo "")

  DASHBOARD_PAYLOAD=$(jq -n \
    --arg title "${DASHBOARD_TITLE}" \
    --arg cluster "${CLUSTER_NAME}" \
    --arg env "${ENVIRONMENT}" \
    '{
      "title": $title,
      "description": ("EKS cluster overview for " + $cluster + " (" + $env + "). Managed by eks-platform-datadog-agent."),
      "layout_type": "ordered",
      "tags": [("managed-by:eks-platform-datadog-agent"), ("cluster:" + $cluster), ("env:" + $env)],
      "template_variables": [
        {"name": "cluster", "prefix": "cluster_name", "default": $cluster},
        {"name": "namespace", "prefix": "kube_namespace", "default": "*"},
        {"name": "node", "prefix": "host", "default": "*"}
      ],
      "widgets": [
        {
          "definition": {
            "type": "timeseries",
            "title": "Node CPU Usage % (user + system)",
            "requests": [{"q": ("avg:system.cpu.user{cluster_name:" + $cluster + ",$node} by {host} + avg:system.cpu.system{cluster_name:" + $cluster + ",$node} by {host}"), "display_type": "line"}],
            "markers": [{"value": "y = 85", "display_type": "error dashed", "label": "85% alert"}],
            "yaxis": {"min": "0", "max": "100"}
          }
        },
        {
          "definition": {
            "type": "timeseries",
            "title": "Node Memory Available %",
            "requests": [{"q": ("avg:system.mem.pct_usable{cluster_name:" + $cluster + ",$node} by {host}"), "display_type": "line"}],
            "markers": [{"value": "y = 10", "display_type": "error dashed", "label": "10% alert"}],
            "yaxis": {"min": "0", "max": "100"}
          }
        },
        {
          "definition": {
            "type": "timeseries",
            "title": "kubernetes.cpu.usage.total by pod",
            "requests": [{"q": ("avg:kubernetes.cpu.usage.total{cluster_name:" + $cluster + "} by {pod_name}"), "display_type": "line"}]
          }
        },
        {
          "definition": {
            "type": "timeseries",
            "title": "Container Restarts by Pod",
            "requests": [{"q": ("sum:kubernetes_state.container.restarts{cluster_name:" + $cluster + "} by {pod_name,kube_container_name}"), "display_type": "bars"}]
          }
        },
        {
          "definition": {
            "type": "query_value",
            "title": "Ready Nodes",
            "requests": [{"q": ("sum:kubernetes_state.node.status{cluster_name:" + $cluster + ",status:ready}"), "aggregator": "last"}],
            "precision": 0
          }
        },
        {
          "definition": {
            "type": "timeseries",
            "title": "Deployment Unavailable Replicas",
            "requests": [{"q": ("sum:kubernetes_state.deployment.replicas_unavailable{cluster_name:" + $cluster + "} by {deployment,kube_namespace}"), "display_type": "bars"}]
          }
        },
        {
          "definition": {
            "type": "timeseries",
            "title": "Disk Usage by Device",
            "requests": [{"q": ("max:system.disk.in_use{cluster_name:" + $cluster + ",$node} by {host,device}"), "display_type": "line"}],
            "markers": [{"value": "y = 0.85", "display_type": "error dashed", "label": "85% alert"}]
          }
        },
        {
          "definition": {
            "type": "timeseries",
            "title": "Network Rx / Tx by Node",
            "requests": [
              {"q": ("sum:kubernetes.network.rx_bytes{cluster_name:" + $cluster + "} by {host}"), "display_type": "line"},
              {"q": ("sum:kubernetes.network.tx_bytes{cluster_name:" + $cluster + "} by {host}"), "display_type": "line"}
            ]
          }
        }
      ]
    }')

  if [[ -n "${EXISTING_DASH_ID}" ]]; then
    log_info "Updating dashboard id=${EXISTING_DASH_ID}"
    UPDATE_RESP=$(dd_api_json PUT "/api/v1/dashboard/${EXISTING_DASH_ID}" \
      -d "${DASHBOARD_PAYLOAD}" 2>&1) || {
      log_warn "Dashboard update failed: ${UPDATE_RESP}"
      DASHBOARD_ACTION="update_failed"
      PHASE_DASHBOARD="degraded"
    }
    if [[ "${DASHBOARD_ACTION}" != "update_failed" ]]; then
      DASHBOARD_ID="${EXISTING_DASH_ID}"
      DASHBOARD_ACTION="updated"
      log_info "Dashboard updated: id=${DASHBOARD_ID}"
    fi
  else
    log_info "Creating dashboard: ${DASHBOARD_TITLE}"
    CREATE_RESP=$(dd_api_json POST "/api/v1/dashboard" \
      -d "${DASHBOARD_PAYLOAD}" 2>&1) || {
      log_warn "Dashboard creation failed: ${CREATE_RESP}"
      DASHBOARD_ACTION="create_failed"
      PHASE_DASHBOARD="degraded"
    }
    if [[ "${DASHBOARD_ACTION}" != "create_failed" ]]; then
      DASHBOARD_ID=$(echo "${CREATE_RESP}" | jq -r '.id // empty' 2>/dev/null || echo "")
      DASHBOARD_ACTION="created"
      log_info "Dashboard created: id=${DASHBOARD_ID}"
    fi
  fi

  if [[ "${PHASE_DASHBOARD}" != "degraded" ]]; then
    PHASE_DASHBOARD="success"
  fi
fi

# ══════════════════════════════════════════════════════════════════════
# PHASE 6 — Summary and artifact
# ══════════════════════════════════════════════════════════════════════
log_phase "Phase 6 — Emit artifact"

ELAPSED=$(( $(date +%s) - START_TIME ))

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  Datadog Configuration Agent — Summary"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
printf "  %-26s %s\n" "Cluster:"        "${CLUSTER_NAME}"
printf "  %-26s %s\n" "Environment:"    "${ENVIRONMENT}"
printf "  %-26s %s\n" "DD Site:"        "${DD_SITE}"
printf "  %-26s %ss\n" "Elapsed:"       "${ELAPSED}"
echo ""
printf "  %-26s %s\n" "Phase 1 — API Validation:"   "${PHASE_API_VALIDATION}"
printf "  %-26s %s\n" "Phase 2 — DaemonSet Wait:"   "${PHASE_DAEMONSET_WAIT}"
printf "  %-26s %s\n" "Phase 3 — Metrics Wait:"     "${PHASE_METRICS_WAIT}"
printf "  %-26s %s\n" "Phase 4 — Monitors:"         "${PHASE_MONITORS}"
printf "    %-24s %s\n" "created:"  "${MONITORS_CREATED}"
printf "    %-24s %s\n" "updated:"  "${MONITORS_UPDATED}"
printf "    %-24s %s\n" "skipped:"  "${MONITORS_SKIPPED}"
printf "  %-26s %s\n" "Phase 5 — Dashboard:"        "${PHASE_DASHBOARD}"
printf "    %-24s %s\n" "action:" "${DASHBOARD_ACTION}"
printf "    %-24s %s\n" "id:"     "${DASHBOARD_ID:-n/a}"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

# API validation is the only hard gate; all other phases are best-effort.
OVERALL_STATUS="success"
if [[ "${PHASE_API_VALIDATION}" != "success" ]]; then
  OVERALL_STATUS="failure"
fi

emit_artifact "${OVERALL_STATUS}" \
  "api=${PHASE_API_VALIDATION},daemonset=${PHASE_DAEMONSET_WAIT},metrics=${PHASE_METRICS_WAIT},monitors=${PHASE_MONITORS},dashboard=${PHASE_DASHBOARD}"

log_info "Agent completed in ${ELAPSED}s — status=${OVERALL_STATUS}"
exit 0
