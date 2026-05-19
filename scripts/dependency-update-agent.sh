#!/bin/bash
#
# dependency-update-agent.sh
# Checks for outdated dependencies across EKS addons, Helm charts, npm packages,
# and Docker base images. Creates a GitHub PR when updates are found.
#
# Usage: ./dependency-update-agent.sh [--dry-run]
# Env:   GH_TOKEN, AWS_REGION, CLUSTER_NAME (optional; skips live addon check if absent)
#        GITHUB_REPOSITORY (e.g. org/repo), GITHUB_OUTPUT
#

set -euo pipefail

DRY_RUN=false
[[ "${1:-}" == "--dry-run" ]] && DRY_RUN=true

REPORT_FILE="artifacts/dependency-update-report.json"
LOG_FILE="artifacts/dependency-update-agent.log"
AWS_REGION="${AWS_REGION:-us-east-1}"
GITHUB_REPOSITORY="${GITHUB_REPOSITORY:-}"
GH_TOKEN="${GH_TOKEN:-}"

mkdir -p artifacts

log() {
  local ts
  ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  echo "[$ts] $*" | tee -a "$LOG_FILE"
}

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "Dependency Update Agent"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

UPDATES=()
HAS_UPDATES=false

# ── Helper: add update entry ──────────────────────────────────────────────────
add_update() {
  local component="$1" category="$2" current="$3" latest="$4" file="$5"
  UPDATES+=("{\"component\":\"$component\",\"category\":\"$category\",\"current\":\"$current\",\"latest\":\"$latest\",\"file\":\"$file\"}")
  log "UPDATE: $component ($category) $current → $latest in $file"
  HAS_UPDATES=true
}

# ── 1. EKS Managed Add-ons ────────────────────────────────────────────────────
log "Checking EKS managed add-ons..."

# Read current versions from Terraform addons module
ADDONS_TF="terraform/modules/addons/main.tf"
if [[ -f "$ADDONS_TF" ]]; then
  for addon_name in vpc-cni coredns kube-proxy aws-ebs-csi-driver; do
    current_ver=$(grep -A5 "\"$addon_name\"" "$ADDONS_TF" 2>/dev/null | \
      grep 'addon_version' | head -1 | \
      sed 's/.*= *"\(.*\)".*/\1/' | tr -d ' ' || echo "")

    if [[ -z "$current_ver" ]]; then
      log "SKIP: $addon_name version not pinned in $ADDONS_TF"
      continue
    fi

    # Query AWS for latest default version (requires live AWS credentials)
    if command -v aws &>/dev/null && aws sts get-caller-identity &>/dev/null 2>&1; then
      CLUSTER_VERSION=$(aws eks list-clusters --region "$AWS_REGION" --output text 2>/dev/null | head -1 || echo "")
      if [[ -n "$CLUSTER_VERSION" ]]; then
        # shellcheck disable=SC2016
        latest_ver=$(aws eks describe-addon-versions \
          --region "$AWS_REGION" \
          --addon-name "$addon_name" \
          --query 'addons[0].addonVersions[?compatibilities[?defaultVersion==`true`]].addonVersion | [0]' \
          --output text 2>/dev/null || echo "")

        if [[ -n "$latest_ver" && "$latest_ver" != "None" && "$latest_ver" != "$current_ver" ]]; then
          add_update "$addon_name" "eks-addon" "$current_ver" "$latest_ver" "$ADDONS_TF"
        else
          log "OK: $addon_name ($current_ver) is current"
        fi
      fi
    else
      log "SKIP: No AWS credentials for live add-on version check"
    fi
  done
else
  log "SKIP: $ADDONS_TF not found"
fi

# ── 2. Helm Charts ────────────────────────────────────────────────────────────
log "Checking Helm chart versions..."

if command -v helm &>/dev/null; then
  helm repo add eks https://aws.github.io/eks-charts 2>/dev/null || true
  helm repo update 2>/dev/null || true

  declare -A HELM_CHARTS=(
    ["aws-load-balancer-controller"]="eks/aws-load-balancer-controller"
    ["cluster-autoscaler"]="autoscaler/cluster-autoscaler"
    ["metrics-server"]="metrics-server/metrics-server"
  )

  if ! helm repo list 2>/dev/null | grep -q autoscaler; then
    helm repo add autoscaler https://kubernetes.github.io/autoscaler 2>/dev/null || true
  fi
  if ! helm repo list 2>/dev/null | grep -q metrics-server; then
    helm repo add metrics-server https://kubernetes-sigs.github.io/metrics-server/ 2>/dev/null || true
  fi
  helm repo update 2>/dev/null || true

  ADDONS_TF="terraform/modules/addons/main.tf"
  for chart_name in "${!HELM_CHARTS[@]}"; do
    chart_ref="${HELM_CHARTS[$chart_name]}"
    current_ver=$(grep -A10 "\"$chart_name\"" "$ADDONS_TF" 2>/dev/null | \
      grep 'chart_version\|version' | head -1 | \
      sed 's/.*= *"\(.*\)".*/\1/' | tr -d ' ' || echo "")

    if [[ -z "$current_ver" ]]; then
      log "SKIP: $chart_name version not found in $ADDONS_TF"
      continue
    fi

    latest_ver=$(helm search repo "$chart_ref" --output json 2>/dev/null | \
      jq -r '.[0].version // ""' || echo "")

    if [[ -n "$latest_ver" && "$latest_ver" != "$current_ver" ]]; then
      add_update "$chart_name" "helm-chart" "$current_ver" "$latest_ver" "$ADDONS_TF"
    else
      log "OK: $chart_name ($current_ver) is current"
    fi
  done
else
  log "SKIP: helm not installed"
fi

# ── 3. npm packages ───────────────────────────────────────────────────────────
log "Checking npm package versions..."

if [[ -f "app/package.json" ]] && command -v npm &>/dev/null; then
  cd app
  npm install --silent 2>/dev/null || true

  while IFS= read -r line; do
    pkg_name=$(echo "$line" | awk '{print $1}')
    current_ver=$(echo "$line" | awk '{print $2}' | sed 's/[^0-9.]//g')
    latest_ver=$(echo "$line" | awk '{print $4}' | sed 's/[^0-9.]//g')

    if [[ -n "$latest_ver" && "$latest_ver" != "" && "$current_ver" != "$latest_ver" ]]; then
      add_update "$pkg_name" "npm" "$current_ver" "$latest_ver" "app/package.json"
    fi
  done < <(npm outdated --parseable 2>/dev/null | tail -n +2 | \
    awk -F: '{print $4 " " $3 " vs " $2}' || true)

  cd - > /dev/null
else
  log "SKIP: app/package.json not found or npm not installed"
fi

# ── 4. Docker base image ──────────────────────────────────────────────────────
log "Checking Docker base image..."

DOCKERFILE="app/Dockerfile"
if [[ -f "$DOCKERFILE" ]]; then
  # Extract current node version from FROM line
  current_node=$(grep '^FROM node:' "$DOCKERFILE" | head -1 | sed 's/FROM node:\([0-9]*\).*/\1/' || echo "")

  if [[ -n "$current_node" ]]; then
    # Check Docker Hub for latest LTS (even-numbered major)
    latest_node=$(curl -s "https://registry.hub.docker.com/v2/repositories/library/node/tags/?page_size=50&name=lts-alpine" \
      2>/dev/null | \
      jq -r '.results[].name' 2>/dev/null | \
      grep '^[0-9]*-alpine$' | \
      awk -F'-' '{print $1}' | \
      sort -rn | head -1 || echo "")

    if [[ -n "$latest_node" && "$latest_node" != "$current_node" ]]; then
      add_update "node" "docker-base" "${current_node}-alpine" "${latest_node}-alpine" "$DOCKERFILE"
    else
      log "OK: node:${current_node}-alpine is current"
    fi
  fi
else
  log "SKIP: $DOCKERFILE not found"
fi

# ── 5. Terraform version ──────────────────────────────────────────────────────
log "Checking Terraform version..."

if [[ -f ".github/workflows/ci-cd-pipeline.yml" ]]; then
  current_tf=$(grep 'TF_VERSION:' .github/workflows/ci-cd-pipeline.yml | head -1 | \
    sed "s/.*: *'\(.*\)'.*/\1/" | tr -d "' " || echo "")

  if [[ -n "$current_tf" ]]; then
    latest_tf=$(curl -s https://api.github.com/repos/hashicorp/terraform/releases/latest \
      2>/dev/null | jq -r '.tag_name // ""' | sed 's/^v//' || echo "")

    if [[ -n "$latest_tf" && "$latest_tf" != "$current_tf" ]]; then
      add_update "terraform" "tool-version" "$current_tf" "$latest_tf" ".github/workflows/ci-cd-pipeline.yml"
    else
      log "OK: terraform $current_tf is current"
    fi
  fi
fi

# ── Write report ──────────────────────────────────────────────────────────────
UPDATES_JSON=$(printf '%s\n' "${UPDATES[@]:-}" | jq -s '.' 2>/dev/null || echo "[]")
UPDATE_COUNT=${#UPDATES[@]}

cat > "$REPORT_FILE" << EOF
{
  "timestamp": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "has_updates": $HAS_UPDATES,
  "update_count": $UPDATE_COUNT,
  "updates": $UPDATES_JSON,
  "dry_run": $DRY_RUN,
  "agent_version": "1.0"
}
EOF

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "Dependency Update Summary: $UPDATE_COUNT update(s) found"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

if [[ "$UPDATE_COUNT" -eq 0 ]]; then
  echo "All dependencies are up to date."
  exit 0
fi

for u in "${UPDATES[@]}"; do
  component=$(echo "$u" | jq -r '.component')
  current=$(echo "$u" | jq -r '.current')
  latest=$(echo "$u" | jq -r '.latest')
  echo "  • $component: $current → $latest"
done

# ── Create GitHub PR if not dry-run ──────────────────────────────────────────
if [[ "$DRY_RUN" == "true" ]]; then
  echo ""
  echo "Dry-run mode: skipping PR creation."
  exit 0
fi

if [[ -z "$GH_TOKEN" ]] || [[ -z "$GITHUB_REPOSITORY" ]]; then
  log "SKIP: GH_TOKEN or GITHUB_REPOSITORY not set; skipping PR creation"
  exit 0
fi

BRANCH="deps/auto-update-$(date +%Y%m%d-%H%M)"
git config user.email "deps-agent@eks-platform.local"
git config user.name "Dependency Update Agent"
git checkout -b "$BRANCH"

# Apply updates to files
for u in "${UPDATES[@]}"; do
  component=$(echo "$u" | jq -r '.component')
  category=$(echo "$u" | jq -r '.category')
  current=$(echo "$u" | jq -r '.current')
  latest=$(echo "$u" | jq -r '.latest')
  file=$(echo "$u" | jq -r '.file')

  if [[ -f "$file" ]]; then
    case "$category" in
      npm)
        # Update package.json version constraints
        sed -i "s/\"$component\": *\"[^\"]*\"/\"$component\": \"^${latest}\"/" "$file" || true
        ;;
      docker-base)
        sed -i "s|FROM node:${current}|FROM node:${latest}|g" "$file" || true
        ;;
      tool-version)
        # Terraform version in workflow
        sed -i "s/TF_VERSION: *'${current}'/TF_VERSION: '${latest}'/" "$file" || true
        ;;
      helm-chart|eks-addon)
        sed -i "s/\"${current}\"/\"${latest}\"/" "$file" || true
        ;;
    esac
    log "Applied $component $current → $latest in $file"
  fi
done

git add -A
git diff --staged --quiet || git commit -m "chore(deps): auto-update $(date +%Y-%m-%d)

$(printf '%s\n' "${UPDATES[@]}" | jq -r '"- \(.component): \(.current) → \(.latest)"' | head -20)"

git push origin "$BRANCH"

# Create PR via GitHub API
PR_BODY=$(cat << EOF
## Automated Dependency Updates

Generated by dependency-update-agent on $(date -u +%Y-%m-%d).

### Updates

$(printf '%s\n' "${UPDATES[@]}" | jq -r '"| \(.component) | \(.category) | \(.current) | \(.latest) |"' | \
  { echo "| Component | Category | Current | Latest |"; echo "|-----------|----------|---------|--------|"; cat; })

### Review checklist
- [ ] Verify no breaking changes in release notes
- [ ] Check test environment passes after merge
- [ ] Confirm HPA and autoscaler behavior unchanged

🤖 Auto-generated by dependency-update-agent
EOF
)

curl -s -X POST \
  -H "Authorization: token $GH_TOKEN" \
  -H "Content-Type: application/json" \
  "https://api.github.com/repos/${GITHUB_REPOSITORY}/pulls" \
  -d "{
    \"title\": \"chore(deps): auto-update $(date +%Y-%m-%d)\",
    \"head\": \"$BRANCH\",
    \"base\": \"main\",
    \"body\": $(echo "$PR_BODY" | jq -Rs .),
    \"labels\": [\"dependencies\", \"automated\"]
  }" | jq -r '"PR created: \(.html_url // "unknown")"'

log "PR creation complete"
exit 0
