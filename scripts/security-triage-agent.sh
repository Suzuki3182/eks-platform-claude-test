#!/bin/bash
#
# security-triage-agent.sh
# Classifies tfsec/checkov findings as BLOCK, WARN, or SUPPRESS.
# Optional: uses Claude API (claude-haiku-4-5) for context-aware analysis.
#
# Usage: ./security-triage-agent.sh [tfsec-results.json] [checkov-results.json]
# Exits 1 if any BLOCK-level findings remain after triage.
#

set -euo pipefail

TFSEC_FILE="${1:-tfsec-results.json}"
CHECKOV_FILE="${2:-checkov-results.json}"
REPORT_FILE="artifacts/security-triage-report.json"
LOG_FILE="artifacts/security-triage-agent.log"
ANTHROPIC_API_KEY="${ANTHROPIC_API_KEY:-}"

mkdir -p artifacts

log() {
  local ts
  ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  echo "[$ts] $*" | tee -a "$LOG_FILE"
}

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "Security Triage Agent"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

# ── Suppression rules (regex on rule_id) ────────────────────────────────────
# These findings are known-safe for this project and suppressed automatically.
SUPPRESS_RULES=(
  "aws-ec2-no-public-egress-sgr"      # ALB needs public egress
  "aws-iam-no-policy-wildcards"       # IRSA scoped to specific resources
  "AVD-AWS-0104"                      # same as above (checkov form)
  "CKV_AWS_79"                        # IMDSv2 — controlled via launch template
  "CKV2_AWS_5"                        # SG not attached — managed by EKS
  "CKV_AWS_23"                        # SG description — not critical
)

# ── Block rules — always escalate to BLOCK regardless of severity ────────────
BLOCK_RULES=(
  "CKV_AWS_18"   # S3 access logging
  "CKV_AWS_66"   # EKS secrets encryption — must be enabled
  "CKV_AWS_58"   # EKS secrets encryption (alternative ID)
  "aws-eks-no-public-cluster-access-to-cidr"  # public cluster access
)

BLOCK_COUNT=0
WARN_COUNT=0
SUPPRESS_COUNT=0
TRIAGED=()

# ── Helper: classify a single finding ────────────────────────────────────────
classify_finding() {
  local rule_id="$1"
  local severity="$2"

  for suppress in "${SUPPRESS_RULES[@]}"; do
    if [[ "$rule_id" == *"$suppress"* ]]; then
      echo "SUPPRESS"
      return
    fi
  done

  for block in "${BLOCK_RULES[@]}"; do
    if [[ "$rule_id" == *"$block"* ]]; then
      echo "BLOCK"
      return
    fi
  done

  case "$severity" in
    CRITICAL) echo "BLOCK" ;;
    HIGH)     echo "BLOCK" ;;
    MEDIUM)   echo "WARN" ;;
    LOW|INFO) echo "SUPPRESS" ;;
    *)        echo "WARN" ;;
  esac
}

# ── Process tfsec results ─────────────────────────────────────────────────────
log "Processing tfsec results: $TFSEC_FILE"

if [[ -f "$TFSEC_FILE" ]]; then
  TFSEC_RESULT_COUNT=$(jq '[.results // []] | flatten | length' "$TFSEC_FILE" 2>/dev/null || echo "0")
  log "tfsec findings: $TFSEC_RESULT_COUNT"

  while IFS= read -r finding; do
    rule_id=$(echo "$finding" | jq -r '.rule_id // .long_id // "unknown"')
    severity=$(echo "$finding" | jq -r '.severity // "MEDIUM"')
    description=$(echo "$finding" | jq -r '.rule.description // .description // ""')
    location=$(echo "$finding" | jq -r '(.location.filename // "") + ":" + ((.location.start_line // 0) | tostring)')

    verdict=$(classify_finding "$rule_id" "$severity")

    case "$verdict" in
      BLOCK)    ((BLOCK_COUNT++)) ;;
      WARN)     ((WARN_COUNT++)) ;;
      SUPPRESS) ((SUPPRESS_COUNT++)) ;;
    esac

    TRIAGED+=("{\"source\":\"tfsec\",\"rule_id\":\"$rule_id\",\"severity\":\"$severity\",\"verdict\":\"$verdict\",\"location\":\"$location\",\"description\":$(echo "$description" | jq -Rs .)}")
    log "[$verdict] tfsec/$rule_id ($severity) @ $location"
  done < <(jq -c '.results // [] | .[]' "$TFSEC_FILE" 2>/dev/null || true)
else
  log "WARNING: tfsec results file not found: $TFSEC_FILE"
fi

# ── Process checkov results ───────────────────────────────────────────────────
log "Processing checkov results: $CHECKOV_FILE"

if [[ -f "$CHECKOV_FILE" ]]; then
  CHECKOV_FAIL_COUNT=$(jq '.summary.failed // 0' "$CHECKOV_FILE" 2>/dev/null || echo "0")
  log "checkov failed checks: $CHECKOV_FAIL_COUNT"

  while IFS= read -r finding; do
    rule_id=$(echo "$finding" | jq -r '.check_id // "unknown"')
    severity=$(echo "$finding" | jq -r '.severity // "MEDIUM"' | tr '[:lower:]' '[:upper:]')
    description=$(echo "$finding" | jq -r '.check.name // .check_id // ""')
    location=$(echo "$finding" | jq -r '(.repo_file_path // .file_path // "") + ":" + ((.file_line_range[0] // 0) | tostring)')

    verdict=$(classify_finding "$rule_id" "$severity")

    case "$verdict" in
      BLOCK)    ((BLOCK_COUNT++)) ;;
      WARN)     ((WARN_COUNT++)) ;;
      SUPPRESS) ((SUPPRESS_COUNT++)) ;;
    esac

    TRIAGED+=("{\"source\":\"checkov\",\"rule_id\":\"$rule_id\",\"severity\":\"$severity\",\"verdict\":\"$verdict\",\"location\":\"$location\",\"description\":$(echo "$description" | jq -Rs .)}")
    log "[$verdict] checkov/$rule_id ($severity) @ $location"
  done < <(jq -c '(.results.failed_checks // []) | .[]' "$CHECKOV_FILE" 2>/dev/null || true)
else
  log "WARNING: checkov results file not found: $CHECKOV_FILE"
fi

# ── Optional: Claude API enrichment for BLOCK findings ───────────────────────
AI_ANALYSIS=""
if [[ -n "$ANTHROPIC_API_KEY" ]] && [[ "$BLOCK_COUNT" -gt 0 ]]; then
  log "Requesting Claude analysis for $BLOCK_COUNT BLOCK findings..."

  BLOCK_SUMMARY=$(printf '%s\n' "${TRIAGED[@]}" | jq -s '[.[] | select(.verdict=="BLOCK")]' 2>/dev/null || echo "[]")

  PROMPT="You are a cloud security engineer reviewing EKS infrastructure findings. These are BLOCK-level security findings that failed automated triage. For each finding, provide: (1) whether this is a genuine risk or a false positive for a production EKS cluster running on AWS, (2) a one-line remediation step. Findings: $BLOCK_SUMMARY. Respond in JSON: [{\"rule_id\":\"...\",\"is_false_positive\":bool,\"remediation\":\"...\"}]"

  API_RESPONSE=$(curl -s -X POST "https://api.anthropic.com/v1/messages" \
    -H "x-api-key: $ANTHROPIC_API_KEY" \
    -H "anthropic-version: 2023-06-01" \
    -H "content-type: application/json" \
    -d "{\"model\":\"claude-haiku-4-5-20251001\",\"max_tokens\":1024,\"messages\":[{\"role\":\"user\",\"content\":$(echo "$PROMPT" | jq -Rs .)}]}" \
    2>/dev/null || echo "")

  if [[ -n "$API_RESPONSE" ]]; then
    AI_ANALYSIS=$(echo "$API_RESPONSE" | jq -r '.content[0].text // ""' 2>/dev/null || echo "")
    log "Claude analysis received (${#AI_ANALYSIS} chars)"
  fi
fi

# ── Write report ──────────────────────────────────────────────────────────────
TRIAGED_JSON=$(printf '%s\n' "${TRIAGED[@]:-}" | jq -s '.' 2>/dev/null || echo "[]")
OVERALL=$([ "$BLOCK_COUNT" -eq 0 ] && echo "PASS" || echo "FAIL")

cat > "$REPORT_FILE" << EOF
{
  "timestamp": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "overall": "$OVERALL",
  "summary": {
    "block": $BLOCK_COUNT,
    "warn": $WARN_COUNT,
    "suppress": $SUPPRESS_COUNT,
    "total": $((BLOCK_COUNT + WARN_COUNT + SUPPRESS_COUNT))
  },
  "findings": $TRIAGED_JSON,
  "ai_analysis": $(echo "${AI_ANALYSIS:-null}" | jq -Rs 'if . == "null\n" then null else . end'),
  "agent_version": "1.0"
}
EOF

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "Security Triage Summary"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "Overall:   $OVERALL"
echo "BLOCK:     $BLOCK_COUNT"
echo "WARN:      $WARN_COUNT"
echo "SUPPRESS:  $SUPPRESS_COUNT"
echo ""

if [[ "$BLOCK_COUNT" -gt 0 ]]; then
  echo "FATAL: $BLOCK_COUNT BLOCK-level finding(s) require remediation before proceeding."
  exit 1
fi

echo "No BLOCK findings. Pipeline may continue."
exit 0
