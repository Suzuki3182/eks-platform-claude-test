#!/bin/bash
#
# cost-impact-agent.sh
# Analyzes terraform plan to estimate cost impact changes
# Outputs: artifacts/cost-impact.json
#
# Usage: ./cost-impact-agent.sh <environment> <plan_file> <stage>
#

set -e

ENVIRONMENT="${1:?Environment required (test/staging/prod)}"
PLAN_FILE="${2:?Plan file required}"
STAGE="${3:$ENVIRONMENT}"

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "Cost Impact Analysis Agent — $ENVIRONMENT ($STAGE)"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

mkdir -p artifacts

# Convert binary plan to JSON for analysis
if [[ ! -f "$PLAN_FILE" ]]; then
  echo "ERROR: Plan file not found: $PLAN_FILE"
  exit 1
fi

terraform show -json "$PLAN_FILE" > /tmp/plan.json 2>/dev/null || {
  echo "WARNING: Could not convert plan to JSON. Proceeding with heuristic analysis."
  terraform show "$PLAN_FILE" > /tmp/plan.txt 2>/dev/null
}

# Function to estimate cost change for resource type
estimate_resource_cost() {
  local resource_type="$1"
  local action="$2"  # create, update, delete
  
  case "$resource_type" in
    aws_eks_cluster)
      [[ "$action" == "create" ]] && echo "0.10" || echo "0"
      ;;
    aws_eks_node_group)
      [[ "$action" == "create" ]] && echo "0.05" || echo "0"
      ;;
    aws_instance)
      [[ "$action" == "create" ]] && echo "25.00" || echo "0"
      ;;
    aws_rds_cluster)
      [[ "$action" == "create" ]] && echo "1.50" || echo "0"
      ;;
    aws_elasticache_cluster)
      [[ "$action" == "create" ]] && echo "0.30" || echo "0"
      ;;
    aws_ebs_volume)
      [[ "$action" == "create" ]] && echo "0.10" || echo "0"
      ;;
    aws_eip)
      [[ "$action" == "create" ]] && echo "0.005" || echo "0"
      ;;
    *)
      echo "0"
      ;;
  esac
}

# Extract resource changes from plan
if [[ -f /tmp/plan.json ]]; then
  CREATED=$(jq -r '.resource_changes[]? | select(.change.actions[] == "create") | .type' /tmp/plan.json 2>/dev/null | sort | uniq -c | sort -rn || echo "")
  DELETED=$(jq -r '.resource_changes[]? | select(.change.actions[] == "delete") | .type' /tmp/plan.json 2>/dev/null | sort | uniq -c | sort -rn || echo "")
  MODIFIED=$(jq -r '.resource_changes[]? | select(.change.actions[] == "update") | .type' /tmp/plan.json 2>/dev/null | sort | uniq -c | sort -rn || echo "")
else
  # Fallback: parse text output
  CREATED=$(grep "# aws_" /tmp/plan.txt 2>/dev/null | grep "will be created" | sed 's/.*# //' | sed 's/ .*//' | sort | uniq -c || echo "")
  DELETED=$(grep "# aws_" /tmp/plan.txt 2>/dev/null | grep "will be destroyed" | sed 's/.*# //' | sed 's/ .*//' | sort | uniq -c || echo "")
  MODIFIED=$(grep "# aws_" /tmp/plan.txt 2>/dev/null | grep "will be updated" | sed 's/.*# //' | sed 's/ .*//' | sort | uniq -c || echo "")
fi

# Calculate total cost impact
TOTAL_MONTHLY_DELTA=0
CREATED_COST=0
DELETED_COST=0

while read -r count resource_type; do
  if [[ -n "$count" && "$count" != "0" ]]; then
    unit_cost=$(estimate_resource_cost "$resource_type" "create")
    resource_total=$(echo "$count * $unit_cost" | bc 2>/dev/null || echo "0")
    CREATED_COST=$(echo "$CREATED_COST + $resource_total" | bc)
    echo "  + $resource_type: $count × \$$unit_cost = \$$resource_total/month"
  fi
done < <(echo "$CREATED")

while read -r count resource_type; do
  if [[ -n "$count" && "$count" != "0" ]]; then
    unit_cost=$(estimate_resource_cost "$resource_type" "delete")
    resource_total=$(echo "$count * $unit_cost" | bc 2>/dev/null || echo "0")
    DELETED_COST=$(echo "$DELETED_COST + $resource_total" | bc)
    echo "  - $resource_type: $count × \$$unit_cost = \$$resource_total/month"
  fi
done < <(echo "$DELETED")

TOTAL_MONTHLY_DELTA=$(echo "$CREATED_COST - $DELETED_COST" | bc 2>/dev/null || echo "0")

# Load thresholds
COST_THRESHOLD_TEST=$(grep "COST_THRESHOLD_TEST" /dev/null 2>/dev/null || echo "500")
COST_THRESHOLD_STAGING=$(grep "COST_THRESHOLD_STAGING" /dev/null 2>/dev/null || echo "2000")
COST_THRESHOLD_PROD=$(grep "COST_THRESHOLD_PROD" /dev/null 2>/dev/null || echo "5000")

case "$STAGE" in
  test) THRESHOLD=$COST_THRESHOLD_TEST ;;
  staging) THRESHOLD=$COST_THRESHOLD_STAGING ;;
  prod) THRESHOLD=$COST_THRESHOLD_PROD ;;
  *) THRESHOLD="0" ;;
esac

if (( $(echo "$TOTAL_MONTHLY_DELTA > $THRESHOLD" | bc -l) )); then
  STATUS="warning"
  BLOCKING=true
  REASON="Monthly cost increase (\$$TOTAL_MONTHLY_DELTA) exceeds threshold (\$$THRESHOLD)"
else
  STATUS="success"
  BLOCKING=false
  REASON="Cost impact within acceptable range"
fi

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "Cost Analysis Summary"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "Stage:                    $STAGE"
echo "Estimated Monthly Delta:  \$$TOTAL_MONTHLY_DELTA"
echo "Environment Threshold:    \$$THRESHOLD"
echo "Status:                   $STATUS"
echo "Blocking:                 $BLOCKING"
echo ""

# Output artifact
cat > artifacts/cost-impact.json << EOF
{
  "stage": "$STAGE",
  "timestamp": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "cost_analysis": {
    "monthly_delta_usd": $TOTAL_MONTHLY_DELTA,
    "created_cost_usd": $CREATED_COST,
    "deleted_cost_usd": $DELETED_COST,
    "threshold_usd": $THRESHOLD
  },
  "resource_changes": {
    "created": $([[ -n "$CREATED" ]] && echo "$CREATED" | wc -l || echo "0"),
    "deleted": $([[ -n "$DELETED" ]] && echo "$DELETED" | wc -l || echo "0"),
    "modified": $([[ -n "$MODIFIED" ]] && echo "$MODIFIED" | wc -l || echo "0")
  },
  "status": "$STATUS",
  "blocking": $BLOCKING,
  "reason": "$REASON"
}
EOF

echo "Artifact written to: artifacts/cost-impact.json"
echo ""

if [[ "$BLOCKING" == "true" ]]; then
  echo "⚠️  COST IMPACT WARNING: Change exceeds threshold. Manual review required."
  exit 1
else
  echo "✅ Cost impact within acceptable range."
  exit 0
fi
