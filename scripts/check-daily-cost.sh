#!/usr/bin/env bash
set -euo pipefail

START=$(date -u +%Y-%m-%d)
END=$(date -u -d "tomorrow" +%Y-%m-%d)
OUT_DIR="artifacts"
mkdir -p "$OUT_DIR"
OUT_FILE="$OUT_DIR/cost-daily-${START}.txt"

aws ce get-cost-and-usage \
  --time-period Start="$START",End="$END" \
  --granularity DAILY \
  --metrics UnblendedCost \
  --group-by Type=DIMENSION,Key=SERVICE \
  --query "ResultsByTime[0].Groups[?Metrics.UnblendedCost.Amount!='0'].[Keys[0],Metrics.UnblendedCost.Amount,Metrics.UnblendedCost.Unit]" \
  --output table | tee "$OUT_FILE"

echo "Saved: $OUT_FILE"
