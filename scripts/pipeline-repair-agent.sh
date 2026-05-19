#!/bin/bash
#
# pipeline-repair-agent.sh
# Autonomous CI/CD failure analysis and code repair using Claude API.
# Reads a failure-context artifact, generates a fix, commits, and pushes.
# A new push triggers a fresh pipeline run — no human needed.
#
# Loop guard: if the last 3 consecutive commits are all auto-repairs, abort.
#
# Usage: ./pipeline-repair-agent.sh [failure-context.json]
# Env:   ANTHROPIC_API_KEY (required for complex fixes)
#        GITHUB_REPOSITORY, GIT_USER_EMAIL, GIT_USER_NAME
#        MAX_CONSECUTIVE_REPAIRS (default: 3)
#

set -euo pipefail

CONTEXT_FILE="${1:-artifacts/failure-context.json}"
REPORT_FILE="artifacts/repair-report.json"
LOG_FILE="artifacts/pipeline-repair-agent.log"
MAX_REPAIRS="${MAX_CONSECUTIVE_REPAIRS:-3}"
ANTHROPIC_API_KEY="${ANTHROPIC_API_KEY:-}"

mkdir -p artifacts

log() {
  local ts
  ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  echo "[$ts] $*" | tee -a "$LOG_FILE"
}

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "Pipeline Repair Agent"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

# ── Loop guard ────────────────────────────────────────────────────────────────
CONSECUTIVE_REPAIRS=$(git log --oneline -"$MAX_REPAIRS" 2>/dev/null | \
  grep -c 'fix(auto-repair):' || echo 0)

if [[ "$CONSECUTIVE_REPAIRS" -ge "$MAX_REPAIRS" ]]; then
  log "LOOP GUARD: $CONSECUTIVE_REPAIRS consecutive auto-repair commits detected. Stopping to prevent infinite loop."
  cat > "$REPORT_FILE" << EOF
{
  "timestamp": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "outcome": "LOOP_GUARD_TRIGGERED",
  "consecutive_repairs": $CONSECUTIVE_REPAIRS,
  "max_allowed": $MAX_REPAIRS,
  "message": "Repair halted — manual review required"
}
EOF
  exit 1
fi

log "Loop guard: $CONSECUTIVE_REPAIRS/$MAX_REPAIRS consecutive auto-repairs so far"

# ── Load failure context ──────────────────────────────────────────────────────
if [[ ! -f "$CONTEXT_FILE" ]]; then
  log "ERROR: Failure context file not found: $CONTEXT_FILE"
  exit 1
fi

STAGE=$(jq -r '.stage // "unknown"' "$CONTEXT_FILE")
FAILURE_TYPE=$(jq -r '.failure_type // "UNKNOWN"' "$CONTEXT_FILE")
FAILED_STEP=$(jq -r '.failed_step // "unknown"' "$CONTEXT_FILE")
COMMIT_SHA=$(jq -r '.commit_sha // ""' "$CONTEXT_FILE")
# error_output and files_affected may be used by future fix strategies
# shellcheck disable=SC2034
ERROR_OUTPUT=$(jq -r '.error_output // ""' "$CONTEXT_FILE")
# shellcheck disable=SC2034
FILES_AFFECTED=$(jq -r '.files_affected // [] | .[]' "$CONTEXT_FILE" 2>/dev/null || echo "")

log "Context: stage=$STAGE type=$FAILURE_TYPE step=$FAILED_STEP"

# ── Configure git ──────────────────────────────────────────────────────────────
git config user.email "${GIT_USER_EMAIL:-pipeline-repair@eks-platform.local}"
git config user.name "${GIT_USER_NAME:-Pipeline Repair Agent}"

FIXED=false
FIX_DESCRIPTION=""

# ── Claude API helper ─────────────────────────────────────────────────────────
ask_claude() {
  local prompt="$1"
  local max_tokens="${2:-4096}"

  if [[ -z "$ANTHROPIC_API_KEY" ]]; then
    log "WARNING: ANTHROPIC_API_KEY not set; Claude-based fix unavailable"
    echo ""
    return
  fi

  curl -s -X POST "https://api.anthropic.com/v1/messages" \
    -H "x-api-key: $ANTHROPIC_API_KEY" \
    -H "anthropic-version: 2023-06-01" \
    -H "content-type: application/json" \
    -d "{\"model\":\"claude-haiku-4-5-20251001\",\"max_tokens\":$max_tokens,\"messages\":[{\"role\":\"user\",\"content\":$(echo "$prompt" | jq -Rs .)}]}" \
    2>/dev/null | jq -r '.content[0].text // ""' 2>/dev/null || echo ""
}

# ── Fix: Terraform Format ─────────────────────────────────────────────────────
fix_tf_format() {
  log "Fix: Running terraform fmt -recursive..."
  terraform fmt -recursive terraform/ 2>/dev/null || true

  if ! git diff --quiet terraform/ 2>/dev/null; then
    git add terraform/
    FIXED=true
    FIX_DESCRIPTION="terraform fmt auto-correction"
    log "Fixed: terraform formatting corrected"
  else
    log "Nothing changed after terraform fmt — may be a different format issue"
  fi
}

# ── Fix: Shellcheck ────────────────────────────────────────────────────────────
fix_shellcheck() {
  log "Fix: Analyzing shellcheck errors with Claude API..."

  # Collect all shellcheck errors
  SHELLCHECK_ERRORS=""
  while IFS= read -r script; do
    if [[ -f "$script" ]]; then
      SCRIPT_ERRORS=$(shellcheck "$script" 2>&1 || true)
      if [[ -n "$SCRIPT_ERRORS" ]]; then
        SHELLCHECK_ERRORS+="=== $script ===\n$SCRIPT_ERRORS\n\n"
        log "Shellcheck errors in $script"
      fi
    fi
  done < <(find scripts/ -name "*.sh" 2>/dev/null)

  if [[ -z "$SHELLCHECK_ERRORS" ]]; then
    log "No shellcheck errors found on re-scan — may already be fixed"
    return
  fi

  # Fix each failing script via Claude
  FIXED_ANY=false
  while IFS= read -r script; do
    if [[ ! -f "$script" ]]; then continue; fi

    SCRIPT_ERRORS=$(shellcheck "$script" 2>&1 || true)
    if [[ -z "$SCRIPT_ERRORS" ]]; then continue; fi

    FILE_CONTENT=$(cat "$script")
    PROMPT="You are a shell script expert. Fix ALL shellcheck warnings and errors in this bash script.

Shellcheck errors:
${SCRIPT_ERRORS}

Current script content:
${FILE_CONTENT}

Rules:
- Fix every shellcheck warning/error listed above
- Do NOT change the script's logic or behavior
- Do NOT add comments explaining changes
- Return ONLY the corrected script content — no markdown, no explanation, no code blocks"

    FIXED_CONTENT=$(ask_claude "$PROMPT" 4096)

    if [[ -n "$FIXED_CONTENT" ]] && [[ ${#FIXED_CONTENT} -gt 10 ]]; then
      echo "$FIXED_CONTENT" > "$script"
      log "Applied Claude fix to $script"
      FIXED_ANY=true
    fi
  done < <(find scripts/ -name "*.sh" 2>/dev/null)

  if [[ "$FIXED_ANY" == "true" ]]; then
    git add scripts/
    FIXED=true
    FIX_DESCRIPTION="shellcheck auto-repair via Claude"
  fi
}

# ── Fix: Terraform Validate ────────────────────────────────────────────────────
fix_tf_validate() {
  log "Fix: Analyzing terraform validate errors with Claude API..."

  for env_dir in terraform/environments/*/; do
    VALIDATE_ERRORS=$(terraform -chdir="$env_dir" validate -no-color 2>&1 || true)
    if echo "$VALIDATE_ERRORS" | grep -q "Error:"; then
      log "Validate errors in $env_dir"

      # Find the referenced file from the error
      PROBLEM_FILE=$(echo "$VALIDATE_ERRORS" | grep -oP '(?<=on )[\w./]+\.tf' | head -1 || true)
      if [[ -z "$PROBLEM_FILE" ]]; then
        PROBLEM_FILE="${env_dir}main.tf"
      fi

      if [[ -f "$PROBLEM_FILE" ]]; then
        FILE_CONTENT=$(cat "$PROBLEM_FILE")
        PROMPT="You are a Terraform expert. Fix the validation error in this Terraform file.

Validation errors:
${VALIDATE_ERRORS}

Current file (${PROBLEM_FILE}):
${FILE_CONTENT}

Rules:
- Fix only the specific error — do not refactor
- Return ONLY the corrected file content — no markdown, no explanation, no code blocks"

        FIXED_CONTENT=$(ask_claude "$PROMPT" 4096)
        if [[ -n "$FIXED_CONTENT" ]] && [[ ${#FIXED_CONTENT} -gt 10 ]]; then
          echo "$FIXED_CONTENT" > "$PROBLEM_FILE"
          git add "$PROBLEM_FILE"
          FIXED=true
          FIX_DESCRIPTION="terraform validate auto-repair via Claude"
          log "Applied Claude fix to $PROBLEM_FILE"
        fi
      fi
    fi
  done
}

# ── Fix: npm / TypeScript build ────────────────────────────────────────────────
fix_npm_build() {
  log "Fix: Analyzing TypeScript build error with Claude API..."

  BUILD_ERRORS=$(cd app && { npm run build 2>&1 || true; })
  if ! echo "$BUILD_ERRORS" | grep -q "error TS"; then
    log "No TypeScript errors found on re-build — may already be fixed"
    return
  fi

  # Parse error to find affected file
  PROBLEM_FILE=$(echo "$BUILD_ERRORS" | grep "error TS" | head -1 | \
    grep -oP 'src/[\w./]+\.ts' | head -1 || true)
  PROBLEM_FILE="app/${PROBLEM_FILE:-src/index.ts}"

  if [[ -f "$PROBLEM_FILE" ]]; then
    FILE_CONTENT=$(cat "$PROBLEM_FILE")
    PROMPT="You are a TypeScript expert. Fix the TypeScript compilation error.

Build errors:
${BUILD_ERRORS}

Current file (${PROBLEM_FILE}):
${FILE_CONTENT}

Rules:
- Fix only the compilation errors — do not refactor
- Return ONLY the corrected file content — no markdown, no explanation, no code blocks"

    FIXED_CONTENT=$(ask_claude "$PROMPT" 4096)
    if [[ -n "$FIXED_CONTENT" ]] && [[ ${#FIXED_CONTENT} -gt 10 ]]; then
      echo "$FIXED_CONTENT" > "$PROBLEM_FILE"
      git add "$PROBLEM_FILE"
      FIXED=true
      FIX_DESCRIPTION="TypeScript build error auto-repair via Claude"
      log "Applied Claude fix to $PROBLEM_FILE"
    fi
  fi
}

# ── Fix: TFLint ────────────────────────────────────────────────────────────────
fix_tflint() {
  log "Fix: Analyzing tflint errors with Claude API..."

  for env_dir in terraform/environments/*/; do
    LINT_ERRORS=$(tflint --chdir="$env_dir" --format=compact 2>&1 || true)
    if [[ -z "$LINT_ERRORS" ]] || echo "$LINT_ERRORS" | grep -q "^0 issue"; then
      continue
    fi

    log "TFLint errors in $env_dir: $LINT_ERRORS"

    PROBLEM_FILE=$(echo "$LINT_ERRORS" | grep -oP '[\w./]+\.tf:\d+' | head -1 | cut -d: -f1 || true)
    if [[ -z "$PROBLEM_FILE" ]]; then continue; fi
    PROBLEM_FILE="${env_dir}${PROBLEM_FILE}"
    if [[ ! -f "$PROBLEM_FILE" ]]; then
      PROBLEM_FILE=$(find "$env_dir" -name "*.tf" | head -1)
    fi

    if [[ -f "$PROBLEM_FILE" ]]; then
      FILE_CONTENT=$(cat "$PROBLEM_FILE")
      PROMPT="You are a Terraform expert. Fix the tflint issues in this Terraform file.

TFLint errors:
${LINT_ERRORS}

Current file (${PROBLEM_FILE}):
${FILE_CONTENT}

Rules:
- Fix the tflint warnings/errors — add tflint-ignore directives for style issues
- Do NOT change logic
- Return ONLY the corrected file content — no markdown, no explanation, no code blocks"

      FIXED_CONTENT=$(ask_claude "$PROMPT" 4096)
      if [[ -n "$FIXED_CONTENT" ]] && [[ ${#FIXED_CONTENT} -gt 10 ]]; then
        echo "$FIXED_CONTENT" > "$PROBLEM_FILE"
        git add "$PROBLEM_FILE"
        FIXED=true
        FIX_DESCRIPTION="tflint auto-repair via Claude"
        log "Applied Claude fix to $PROBLEM_FILE"
      fi
    fi
  done
}

# ── Fix: Security BLOCK findings ──────────────────────────────────────────────
fix_security_block() {
  log "Fix: Analyzing security BLOCK findings with Claude API..."

  TRIAGE_REPORT="artifacts/security-triage-report.json"
  if [[ ! -f "$TRIAGE_REPORT" ]]; then
    log "No triage report found — running security triage scan..."
    tfsec terraform/ --format json --out tfsec-results.json \
      --exclude aws-ec2-no-public-egress-sgr,aws-iam-no-policy-wildcards \
      --minimum-severity HIGH --no-color 2>/dev/null || true
    chmod +x scripts/security-triage-agent.sh
    scripts/security-triage-agent.sh tfsec-results.json 2>/dev/null || true
  fi

  if [[ ! -f "$TRIAGE_REPORT" ]]; then
    log "Cannot find security findings to fix"
    return
  fi

  BLOCK_FINDINGS=$(jq '[.findings[] | select(.verdict=="BLOCK")]' "$TRIAGE_REPORT" 2>/dev/null || echo "[]")
  BLOCK_COUNT=$(echo "$BLOCK_FINDINGS" | jq 'length' 2>/dev/null || echo 0)

  if [[ "$BLOCK_COUNT" -eq 0 ]]; then
    log "No BLOCK findings found on re-scan"
    return
  fi

  log "Attempting to fix $BLOCK_COUNT BLOCK finding(s) via Claude..."

  # Process each unique file with BLOCK findings
  declare -A FIXED_FILES
  while IFS= read -r finding; do
    location=$(echo "$finding" | jq -r '.location // ""')
    tf_file=$(echo "$location" | cut -d: -f1)
    rule_id=$(echo "$finding" | jq -r '.rule_id // ""')
    description=$(echo "$finding" | jq -r '.description // ""')

    if [[ -z "$tf_file" ]] || [[ ! -f "$tf_file" ]]; then continue; fi
    if [[ -n "${FIXED_FILES[$tf_file]+_}" ]]; then continue; fi

    FILE_CONTENT=$(cat "$tf_file")
    ALL_BLOCK_FOR_FILE=$(echo "$BLOCK_FINDINGS" | \
      jq -r --arg f "$tf_file" '[.[] | select(.location | startswith($f))] | .[] | "- \(.rule_id): \(.description)"' 2>/dev/null || echo "- $rule_id: $description")

    PROMPT="You are a cloud security engineer. Fix the security findings in this Terraform file.

Security issues to fix:
${ALL_BLOCK_FOR_FILE}

Current file (${tf_file}):
${FILE_CONTENT}

Rules:
- Fix the specific security issues listed above
- Common fixes: add encryption, restrict CIDR ranges, enable logging, add resource policies
- Do NOT remove functionality
- Return ONLY the corrected Terraform file content — no markdown, no explanation, no code blocks"

    FIXED_CONTENT=$(ask_claude "$PROMPT" 4096)
    if [[ -n "$FIXED_CONTENT" ]] && [[ ${#FIXED_CONTENT} -gt 10 ]]; then
      echo "$FIXED_CONTENT" > "$tf_file"
      git add "$tf_file"
      FIXED=true
      FIX_DESCRIPTION="security BLOCK findings auto-remediation via Claude"
      FIXED_FILES[$tf_file]=1
      log "Applied security fix to $tf_file"
    fi
  done < <(echo "$BLOCK_FINDINGS" | jq -c '.[]' 2>/dev/null || true)
}

# ── Dispatch to appropriate fix ────────────────────────────────────────────────
log "Dispatching fix for failure type: $FAILURE_TYPE"

case "$FAILURE_TYPE" in
  TF_FORMAT)       fix_tf_format ;;
  SHELLCHECK)      fix_shellcheck ;;
  TF_VALIDATE)     fix_tf_validate ;;
  TF_LINT)         fix_tflint ;;
  NPM_BUILD|TS_BUILD) fix_npm_build ;;
  SECURITY_BLOCK)  fix_security_block ;;
  TF_FORMAT,SHELLCHECK|SHELLCHECK,TF_FORMAT)
    fix_tf_format
    fix_shellcheck
    ;;
  *)
    log "WARNING: No automated fix available for failure type: $FAILURE_TYPE"
    cat > "$REPORT_FILE" << EOF
{
  "timestamp": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "outcome": "NO_FIX_AVAILABLE",
  "failure_type": "$FAILURE_TYPE",
  "failed_step": "$FAILED_STEP",
  "message": "Failure type does not have an automated repair strategy"
}
EOF
    exit 0
    ;;
esac

# ── Commit and push if fixed ──────────────────────────────────────────────────
if [[ "$FIXED" == "true" ]]; then
  COMMIT_MSG="fix(auto-repair): ${FIX_DESCRIPTION}

Triggered by: pipeline failure in ${STAGE}/${FAILED_STEP}
Original commit: ${COMMIT_SHA:-unknown}
Repair attempt: $((CONSECUTIVE_REPAIRS + 1))/${MAX_REPAIRS}

Co-Authored-By: Pipeline Repair Agent <noreply@anthropic.com>"

  git commit -m "$COMMIT_MSG"
  git push origin HEAD

  log "Fix committed and pushed. New pipeline run will start automatically."

  cat > "$REPORT_FILE" << EOF
{
  "timestamp": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "outcome": "FIXED_AND_PUSHED",
  "failure_type": "$FAILURE_TYPE",
  "failed_step": "$FAILED_STEP",
  "fix_description": "$FIX_DESCRIPTION",
  "repair_attempt": $((CONSECUTIVE_REPAIRS + 1)),
  "max_repairs": $MAX_REPAIRS
}
EOF
  echo ""
  echo "✅ Fix applied: $FIX_DESCRIPTION"
  echo "   New pipeline run will start on push."
  exit 0
else
  log "No fix was generated for $FAILURE_TYPE in $FAILED_STEP"
  cat > "$REPORT_FILE" << EOF
{
  "timestamp": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "outcome": "FIX_GENERATION_FAILED",
  "failure_type": "$FAILURE_TYPE",
  "failed_step": "$FAILED_STEP",
  "message": "Claude or pattern-based fix produced no output"
}
EOF
  exit 1
fi
