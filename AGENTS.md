# Pipeline Agents & Auto-Approval Framework

This document describes the new autonomous agents and the production approval decision engine integrated into the EKS Platform CI/CD pipeline.

---

## Overview

The pipeline now includes **four new agents** that dramatically reduce manual work:

| Agent | Stage | Purpose | Blocking | Output |
|-------|-------|---------|----------|--------|
| **Cost Impact Agent** | test, staging | Analyzes Terraform plan for cost changes | No (warning only) | `cost-impact.json` |
| **Changelog Agent** | staging | Generates structured changelog from commits | No (informational) | `CHANGELOG.md`, `changelog.json` |
| **Production Recommendation Agent** | prod | Aggregates all signals for approval decision | Yes (if blockers) | `prod-recommendation.json` |
| **Auto-Approval Engine** | prod | Makes autonomous approval decision | No (policy-driven) | `auto-approval-decision.json` |

---

## Agent 1: Cost Impact Agent

**File:** `scripts/cost-impact-agent.sh`  
**Triggers:** After `terraform plan` in test and staging environments  
**Purpose:** Analyze infrastructure cost implications before deployment

### What It Does
- Parses Terraform plan to detect resource changes (create/update/delete)
- Estimates monthly cost delta using resource unit pricing
- Compares against environment-specific thresholds
- Outputs structured artifact with cost analysis

### Configuration
Cost thresholds are defined in `.github/auto-approval-config.env`:
```bash
COST_THRESHOLD_TEST_USD=100
COST_THRESHOLD_STAGING_USD=500
COST_THRESHOLD_PROD_USD=1000
```

### Output Artifact: `artifacts/cost-impact.json`
```json
{
  "stage": "staging",
  "cost_analysis": {
    "monthly_delta_usd": 125.50,
    "created_cost_usd": 175.00,
    "deleted_cost_usd": 49.50,
    "threshold_usd": 500
  },
  "resource_changes": {
    "created": 2,
    "deleted": 1,
    "modified": 0
  },
  "status": "success",
  "blocking": false,
  "reason": "Cost impact within acceptable range"
}
```

### Example Output
```
Cost Analysis Summary
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
Stage:                    staging
Estimated Monthly Delta:  $125.50
Environment Threshold:    $500.00
Status:                   success
Blocking:                 false

  + aws_instance: 2 × $25.00 = $50.00/month
  - aws_ebs_volume: 1 × $10.00 = $10.00/month

✅ Cost impact within acceptable range.
```

---

## Agent 2: Changelog Generator Agent

**File:** `scripts/changelog-agent.sh`  
**Triggers:** In staging environment (after health checks)  
**Purpose:** Automatically document infrastructure changes for releases

### What It Does
- Parses git commit history between specified refs
- Categorizes commits by type (Infrastructure, Security, Kubernetes, etc.)
- Generates both human-readable Markdown and machine-readable JSON
- Useful for release notes and change tracking

### Invocation
```bash
./scripts/changelog-agent.sh [from_ref] [to_ref]

# Examples:
./scripts/changelog-agent.sh HEAD~10 HEAD      # Last 10 commits
./scripts/changelog-agent.sh v1.0.0 HEAD       # Tag to HEAD
./scripts/changelog-agent.sh                   # Default: HEAD~10 to HEAD
```

### Output Artifacts

**`artifacts/CHANGELOG.md`** (Human-readable)
```markdown
# Changelog

Generated: 2026-04-22T14:32:15Z

## Infrastructure Changes

### Security
- [a1b2c3d](security: add KMS encryption to RDS) by alice (2026-04-22)

### Kubernetes  
- [d4e5f6g](feat(addon): upgrade cluster-autoscaler) by bob (2026-04-21)

### Scripts
- [h7i8j9k](chore: update k8s-healthcheck.sh) by charlie (2026-04-21)
```

**`artifacts/changelog.json`** (Machine-readable)
```json
{
  "timestamp": "2026-04-22T14:32:15Z",
  "total_commits": 5,
  "commits": [
    {
      "commit": "a1b2c3d",
      "author": "alice",
      "date": "2026-04-22",
      "subject": "security: add KMS encryption to RDS"
    }
  ]
}
```

---

## Agent 3: Production Recommendation Agent

**File:** `scripts/prod-recommendation-agent.sh`  
**Triggers:** In production environment (before Terraform apply)  
**Purpose:** Aggregate all deployment signals and recommend approval/rejection

### What It Analyzes

The agent scores 6 key signals:

1. **Staging Gate** (0-100)
   - Did staging deployment succeed?
   - Is staging validation artifact available?

2. **Security Scans** (0-100)
   - tfsec: Zero CRITICAL/HIGH issues required
   - checkov: ≤10 policy violations acceptable
   - Scoring: -20 per violation

3. **Cost Impact** (0-100)
   - Monthly cost delta checks
   - Threshold: $5000 (configurable)
   - Scoring: Linear decrease with cost increase

4. **Infrastructure Drift** (0-100)
   - Unexpected resource changes detected?
   - Threshold: 0 drift resources accepted
   - Scoring: -10 per unexpected resource

5. **Cluster Health** (0-100)
   - All health checks passed?
   - Includes DNS, nodes, addons, metrics

6. **Change Volume & Risk** (0-100)
   - Number of commits in change set
   - >20 commits = elevated risk
   - Scoring: Decreases with high commit volume

### Confidence Calculation
```
Confidence = Average(all_signal_scores) / 100.0
```

### Decision Logic
```
IF blockers > 0
  THEN recommendation = "MANUAL_REVIEW" (BLOCKED)
ELSE IF confidence < min_threshold (0.80)
  THEN recommendation = "MANUAL_REVIEW"
ELSE
  THEN recommendation = "AUTO_APPROVE"
```

### Output Artifact: `artifacts/prod-recommendation.json`
```json
{
  "timestamp": "2026-04-22T14:35:22Z",
  "stage": "production",
  "recommendation": "AUTO_APPROVE",
  "auto_approve": true,
  "confidence": 0.94,
  "confidence_threshold": 0.90,
  "confidence_scores": {
    "staging_gate": 100,
    "security": 95,
    "cost_impact": 90,
    "drift": 100,
    "cluster_health": 100,
    "change_volume": 85
  },
  "signals": [
    "✅ Staging gate: PASSED",
    "✅ Security scan: PASSED (tfsec clean)",
    "✅ Cost impact acceptable: $125.50"
  ],
  "warnings": [
    "⚠️  Found 1 HIGH severity tfsec issues (review recommended)"
  ],
  "blockers": []
}
```

### Example Output
```
Production Recommendation Agent
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

Analyzing deployment signals...

▶ Signal 1: Staging Environment Status
   Status: PASSED

▶ Signal 2: Security Scan Results
   tfsec: OK (0 HIGH, 0 CRITICAL)
   checkov: OK (3 violations)

▶ Signal 3: Cost Impact Analysis
   Monthly delta: $125.50 (within threshold)

▶ Signal 4: Infrastructure Drift
   OK - no unexpected drift

▶ Signal 5: Cluster Health
   OK - 8 checks passed

▶ Signal 6: Change Volume & Risk
   OK - 7 commits (moderate)

Signal Analysis
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
Confidence Scores:
  staging_gate         100/100
  security             95/100
  cost_impact          90/100
  drift               100/100
  cluster_health      100/100
  change_volume        85/100

Overall Confidence: 0.94 (target: 0.90)
Recommendation:     AUTO_APPROVE

Positive Signals (3):
  ✅ Staging gate: PASSED
  ✅ Security scan: PASSED
  ✅ Cost impact acceptable: $125.50

Warnings (1):
  ⚠️  Found 1 HIGH issues (review recommended)

✅ RECOMMENDATION: SAFE TO DEPLOY
   Auto-approval eligible if policy enabled
```

---

## Agent 4: Auto-Approval Engine

**File:** `scripts/auto-approval-engine.sh`  
**Configuration:** `.github/auto-approval-config.env`  
**Triggers:** In production environment (after prod-recommendation-agent)  
**Purpose:** Make autonomous approval decisions based on policies and confidence

### How It Works

The engine is a **policy-driven decision framework**:

```
1. Load prod-recommendation from previous stage
   ├─ Extract confidence score
   ├─ Extract blocker count
   └─ Check recommendation status

2. Verify auto-approval is enabled
   └─ If disabled → MANUAL_APPROVAL_REQUIRED

3. Analyze change type
   ├─ Is it a patch? (low risk)
   ├─ Is it an addon update? (medium risk)
   ├─ Is it a security fix? (elevated risk, high priority)
   ├─ Is it infrastructure change? (high risk - usually blocked)
   └─ Is there a cost increase? (budget risk - usually blocked)

4. Make decision
   └─ Apply change-type policies
   └─ Check confidence threshold
   └─ Generate decision artifact

5. Output decision
   ├─ AUTO_APPROVED (deployment can proceed)
   └─ MANUAL_APPROVAL_REQUIRED (wait for human)
```

### Configuration: `.github/auto-approval-config.env`

**Feature Toggles:**
```bash
# Master switch - disable to always require manual approval
AUTO_APPROVAL_ENABLED=false

# Minimum confidence for auto-approval (0.0 - 1.0)
MIN_CONFIDENCE_FOR_AUTO=0.90
```

**Change-Type Policies:**
```bash
# Auto-approve patch releases (bug fixes, version bumps)
AUTO_APPROVE_ON_PATCH=true

# Auto-approve addon updates (Helm charts)
AUTO_APPROVE_ON_ADDON_UPDATE=true

# Auto-approve security fixes (CVE patches, tfsec remediation)
AUTO_APPROVE_ON_SECURITY_FIX=true
```

**Blocking Policies:**
```bash
# Infrastructure changes ALWAYS require manual approval (high risk)
REQUIRE_MANUAL_ON_INFRASTRUCTURE_CHANGE=true

# Cost increases ALWAYS require manual approval (budget safety)
REQUIRE_MANUAL_ON_COST_INCREASE=true
```

**Notifications:**
```bash
# Send Slack notifications for deployment decisions
NOTIFY_SLACK=true
SLACK_WEBHOOK_URL="https://hooks.slack.com/services/..."
```

### Output Artifact: `artifacts/auto-approval-decision.json`
```json
{
  "timestamp": "2026-04-22T14:36:10Z",
  "decision": "AUTO_APPROVED",
  "auto_approve": true,
  "reason": "Patch release - auto-approved",
  "confidence": 0.94,
  "confidence_threshold": 0.90,
  "blockers": 0,
  "change_analysis": {
    "is_patch": true,
    "is_addon_update": false,
    "is_security_fix": false,
    "is_infrastructure_change": false,
    "is_cost_increase": false
  },
  "policy_config": {
    "auto_approval_enabled": true,
    "auto_approve_on_patch": true,
    "auto_approve_on_addon_update": true,
    "auto_approve_on_security_fix": true
  },
  "auto_approval_engine_version": "1.0"
}
```

### Decision Scenarios

**Scenario 1: Patch Release (Auto-Approved)** ✅
```
Commit: fix(cluster): resolve health check timeout
Confidence: 0.94
Changes: patch-only, no infrastructure changes, no cost increase
Decision: AUTO_APPROVED → Deployment proceeds automatically
```

**Scenario 2: Infrastructure Change (Manual Gate)**  ⏸️
```
Commit: feat(vpc): add new subnet for ingress
Confidence: 0.92
Changes: terraform vpc module modified
Policy: REQUIRE_MANUAL_ON_INFRASTRUCTURE_CHANGE=true
Decision: MANUAL_APPROVAL_REQUIRED → Awaits GitHub approval
```

**Scenario 3: Cost Increase (Manual Gate)** ⏸️
```
Commit: feat(compute): upgrade node instance type
Confidence: 0.91
Cost delta: +$450/month
Policy: REQUIRE_MANUAL_ON_COST_INCREASE=true
Decision: MANUAL_APPROVAL_REQUIRED → Cost review needed
```

**Scenario 4: Security Fix (Auto-Approved)** ✅
```
Commit: security: fix CVE-2024-1234 in EBS CSI
Confidence: 0.89
Changes: security fix only
Policy: AUTO_APPROVE_ON_SECURITY_FIX=true
Decision: AUTO_APPROVED → Deployment proceeds immediately
```

---

## Enabling Auto-Approval

### Step 1: Configure Policies

Edit `.github/auto-approval-config.env`:
```bash
AUTO_APPROVAL_ENABLED=true
MIN_CONFIDENCE_FOR_AUTO=0.90
AUTO_APPROVE_ON_PATCH=true
AUTO_APPROVE_ON_SECURITY_FIX=true
REQUIRE_MANUAL_ON_INFRASTRUCTURE_CHANGE=true
REQUIRE_MANUAL_ON_COST_INCREASE=true
```

### Step 2: Set Slack Notifications (Optional)

Add GitHub repository secret:
```
Settings → Secrets → New repository secret
Name: SLACK_WEBHOOK_URL
Value: https://hooks.slack.com/services/...
```

### Step 3: Commit and Push
```bash
git add .github/auto-approval-config.env
git commit -m "feat: enable auto-approval for patch releases"
git push origin main
```

---

## Monitoring & Auditing

All decisions are logged to `artifacts/auto-approval-engine.log`:
```
[2026-04-22T14:36:10Z] [INFO] Loaded configuration from .github/auto-approval-config.env
[2026-04-22T14:36:11Z] [INFO] Auto-approval feature is ENABLED
[2026-04-22T14:36:12Z] [INFO] Last commit: fix(cluster): resolve timeout
[2026-04-22T14:36:12Z] [INFO] Change type: PATCH (low risk)
[2026-04-22T14:36:13Z] [INFO] Confidence (0.94) exceeds threshold (0.90)
[2026-04-22T14:36:13Z] [INFO] ✅ Patch release - auto-approved
```

---

## Workflow Integration

### Pipeline Execution Flow

```
┌─────────────┐
│   Build     │ ← Format, validate, lint
└──────┬──────┘
       ↓
┌─────────────────────────────────────┐
│   Test Environment (ephemeral)      │
├─────────────────────────────────────┤
│  1. terraform plan                  │
│  2. cost-impact-agent               │─→ artifacts/cost-impact.json
│  3. tfsec / checkov                 │
│  4. terraform apply                 │
│  5. k8s-healthcheck                 │
│  6. pipeline-agent-verify           │
└──────┬──────────────────────────────┘
       ↓ (if test passes)
┌─────────────────────────────────────┐
│   Staging Environment               │
├─────────────────────────────────────┤
│  1. terraform plan                  │
│  2. cost-impact-agent               │─→ artifacts/cost-impact.json
│  3. terraform apply                 │
│  4. k8s health checks               │
│  5. addon validations               │
│  6. changelog-agent                 │─→ artifacts/CHANGELOG.md
│  7. pipeline-agent-verify           │
└──────┬──────────────────────────────┘
       ↓ (if staging passes)
┌──────────────────────────────────────────────────┐
│   Production Environment                         │
├──────────────────────────────────────────────────┤
│  1. terraform plan                               │
│  2. tfsec / checkov (strict)                     │
│  3. prod-recommendation-agent                    │
│     ├─ Aggregate all signals                     │
│     └─ Output recommendation artifact            │────┐
│  4. auto-approval-engine                         │    │
│     ├─ Apply policies                            │    │ artifacts/
│     ├─ Analyze change type                       │    │ prod-recommendation.json
│     └─ Output decision artifact                  │    │ auto-approval-decision.json
│                                                  │    │
│  5a. [IF AUTO_APPROVED] terraform apply         │←───┘
│      └─ Proceeds automatically                   │
│                                                  │
│  5b. [IF MANUAL] AWAIT GitHub approval          │
│      ├─ prod environment protection rule        │
│      └─ Requires manual reviewer                │
│                                                  │
│  6. k8s rollout status verification             │
│  7. pipeline-agent-verify (final)               │
└──────────────────────────────────────────────────┘
       ↓ (deployment complete)
   ✅ Success  OR  ⛔ Rollback
```

---

## Troubleshooting

### Auto-Approval Not Triggering

**Check 1: Is auto-approval enabled?**
```bash
grep AUTO_APPROVAL_ENABLED .github/auto-approval-config.env
# Should show: AUTO_APPROVAL_ENABLED=true
```

**Check 2: Did prod-recommendation-agent succeed?**
```bash
# In GitHub Actions logs, look for:
# "Recommendation artifact written to: artifacts/prod-recommendation.json"
```

**Check 3: Is confidence above threshold?**
```bash
jq '.confidence' artifacts/prod-recommendation.json
# Should be > 0.90 (or your configured MIN_CONFIDENCE_FOR_AUTO)
```

**Check 4: Are there blockers?**
```bash
jq '.blockers | length' artifacts/prod-recommendation.json
# Should be 0 for auto-approval
```

### Cost Agent Showing Incorrect Values

The cost agent uses **heuristic estimation**. For accurate cost analysis:
- Install AWS pricing API integration (future enhancement)
- Manually review cost artifacts during migration phases
- Consider using Terraform Cloud's cost estimation + API

### Checkov/tfsec Too Strict

Adjust configuration in `.github/auto-approval-config.env`:
```bash
MAX_HIGH_ISSUES=3          # Allow up to 3 HIGH findings
MAX_POLICY_VIOLATIONS=10   # Allow up to 10 checkov violations
```

---

## Next Steps & Future Enhancements

- [ ] Integrate AWS Pricing API for accurate cost estimation
- [ ] Add deployment window checks (business hours only)
- [ ] Implement chaos/smoke tests (canary deployments)
- [ ] Add audit trail PR (auto-create PR after auto-approval)
- [ ] Support for blue-green deployments
- [ ] Advanced drift detection (state diff analysis)
- [ ] Machine learning confidence scoring (based on historical data)

---

## Summary

You now have:
- ✅ **Cost Impact Agent** — Prevents surprise bill surprises
- ✅ **Changelog Agent** — Auto-documents infrastructure changes  
- ✅ **Prod Recommendation Agent** — Intelligently analyzes all signals
- ✅ **Auto-Approval Engine** — Policy-driven autonomous approvals
- ✅ **Configuration Framework** — Fine-grained control over policies

**Result:** Manual production approvals can be eliminated for safe changes (patches, addons, security fixes) while maintaining control for risky changes (infrastructure, costs).

