#!/bin/bash
#
# changelog-agent.sh
# Generates structured changelog from git commits
# Outputs: artifacts/CHANGELOG.md and artifacts/changelog.json
#
# Usage: ./changelog-agent.sh [from_ref] [to_ref]
#

set -e

# Default to last 10 commits if no refs provided
FROM_REF="${1:-HEAD~10}"
TO_REF="${2:-HEAD}"

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "Changelog Generator Agent"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

mkdir -p artifacts

# Ensure we're in a git repository
if [[ ! -d .git ]]; then
  echo "ERROR: Not in a git repository"
  exit 1
fi

# Get commit range
COMMIT_COUNT=$(git rev-list --count "$FROM_REF..$TO_REF" 2>/dev/null || git rev-list --count "$TO_REF" 2>/dev/null || echo "0")
echo "Analyzing $COMMIT_COUNT commits from $FROM_REF to $TO_REF"
echo ""

# Get git log in structured format
git log "$FROM_REF..$TO_REF" --pretty=format:"%h|%an|%ae|%ad|%s" --date=short 2>/dev/null > /tmp/changelog_raw.txt || {
  git log "$TO_REF" -10 --pretty=format:"%h|%an|%ae|%ad|%s" --date=short > /tmp/changelog_raw.txt
}

# Build markdown changelog
{
  echo "# Changelog"
  echo ""
  echo "Generated: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo ""
  echo "## Infrastructure Changes"
  echo ""
  
  # Group by category
  declare -A categories
  while IFS='|' read -r hash author _email date subject; do
    if [[ -z "$hash" ]]; then continue; fi
    
    if [[ "$subject" =~ terraform|tfvar|tf_ ]]; then
      cat="Infrastructure"
    elif [[ "$subject" =~ script|sh ]]; then
      cat="Scripts"
    elif [[ "$subject" =~ security|tfsec|checkov|CVE ]]; then
      cat="Security"
    elif [[ "$subject" =~ test|validation|health ]]; then
      cat="Testing"
    elif [[ "$subject" =~ [Hh]elmchart|addon|k8s|kubernetes ]]; then
      cat="Kubernetes"
    elif [[ "$subject" =~ doc|readme|README ]]; then
      cat="Documentation"
    else
      cat="Other"
    fi
    
    categories["$cat"]+="- [$hash]($subject) by $author ($date)
"
  done < /tmp/changelog_raw.txt
  
  # Output by category
  for category in Infrastructure Security Kubernetes Testing Scripts Documentation Other; do
    if [[ -n "${categories[$category]}" ]]; then
      echo "### $category"
      echo ""
      echo "${categories[$category]}"
      echo ""
    fi
  done
  
} > artifacts/CHANGELOG.md

# Generate JSON artifact
ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
{
  echo "{"
  echo "  \"timestamp\": \"${ts}\","
  echo "  \"commit_range\": \"${FROM_REF}..${TO_REF}\","
  echo "  \"total_commits\": ${COMMIT_COUNT},"
  echo '  "commits": ['
  
  first=true
  while IFS='|' read -r hash author _email date subject; do
    if [[ -z "$hash" ]]; then continue; fi
    
    if [[ "$first" == true ]]; then
      first=false
    else
      echo ","
    fi
    
    echo -n "    {\"commit\": \"${hash}\", \"author\": \"${author}\", \"date\": \"${date}\", \"subject\": \"${subject}\"}"
  done < /tmp/changelog_raw.txt
  
  echo ""
  echo "  ]"
  echo "}"
} > artifacts/changelog.json

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "Changelog Summary"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "Total commits:  $COMMIT_COUNT"
echo "Artifacts:"
echo "  - artifacts/CHANGELOG.md"
echo "  - artifacts/changelog.json"
echo ""

# Display first few entries
echo "Recent changes:"
head -20 artifacts/CHANGELOG.md | tail -10

echo ""
echo "✅ Changelog generated successfully."
exit 0
