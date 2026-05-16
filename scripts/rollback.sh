#!/usr/bin/env bash
# =============================================================================
# rollback.sh
# =============================================================================
# Automated Route 53 DNS rollback to 100% of the ingress-nginx NLB (or to NGF,
# if the rollback is in the other direction).
#
# Designed to be used under pressure. Requires explicit --confirm.
#
# Usage:
#   ./scripts/rollback.sh --to ingress --hosted-zone-id Z123ABC --confirm
#   ./scripts/rollback.sh --to gateway --hosted-zone-id Z123ABC --confirm
#
# What it does:
#   1. Verifies the target NLB exists and is healthy.
#   2. Applies the corresponding JSON via `aws route53 change-resource-record-sets`.
#   3. Waits for the change to propagate (INSYNC status).
#   4. Runs a smoke test against the public endpoint.
#
# What it does NOT do:
#   - Uninstall the "losing" controller (that's done later, deliberately).
#   - Touch anything inside the cluster.
# =============================================================================
set -uo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log()  { echo -e "${BLUE}[rollback]${NC} $*"; }
ok()   { echo -e "${GREEN}✓${NC} $*"; }
warn() { echo -e "${YELLOW}!${NC} $*"; }
err()  { echo -e "${RED}✗${NC} $*" >&2; exit 1; }

usage() {
  cat <<EOF
Usage: $0 --to <ingress|gateway> --hosted-zone-id <Z...> --confirm

Arguments:
  --to               Rollback target: 'ingress' (back to ingress-nginx)
                     or 'gateway' (back to NGF).
  --hosted-zone-id   Route 53 hosted zone ID.
  --confirm          Required. Without this flag, the script does nothing.

Optional env vars:
  HOSTNAME           Public hostname (default: shop.example.com)
  DRY_RUN            If "1", only prints what it would do
EOF
  exit 1
}

TO=""
HOSTED_ZONE=""
CONFIRM=0
HOSTNAME="${HOSTNAME:-shop.example.com}"
DRY_RUN="${DRY_RUN:-0}"

while [ $# -gt 0 ]; do
  case "$1" in
    --to) TO="$2"; shift 2 ;;
    --hosted-zone-id) HOSTED_ZONE="$2"; shift 2 ;;
    --confirm) CONFIRM=1; shift ;;
    -h|--help) usage ;;
    *) usage ;;
  esac
done

[ -n "$TO" ] || usage
[ -n "$HOSTED_ZONE" ] || usage
[ "$TO" = "ingress" ] || [ "$TO" = "gateway" ] || usage

if [ "$CONFIRM" != "1" ]; then
  err "Missing --confirm. The rollback is destructive (changes production DNS). Re-run with --confirm if you're sure."
fi

# Preflight
command -v aws >/dev/null || err "aws CLI not installed"
command -v kubectl >/dev/null || err "kubectl not installed"
command -v jq >/dev/null || err "jq not installed"

# Locate the DNS file to apply
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"

if [ "$TO" = "ingress" ]; then
  DNS_FILE="$REPO_ROOT/manifests/04-migration/dns-rollback-100pct-ingress.json"
  TARGET_DESC="ingress-nginx"
  TARGET_NLB=$(kubectl -n ingress-nginx get svc ingress-nginx-controller \
    -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || true)
else
  DNS_FILE="$REPO_ROOT/manifests/04-migration/dns-canary-100pct.json"
  TARGET_DESC="nginx-gateway-fabric"
  TARGET_NLB=$(kubectl -n gateway-system get svc \
    -l gateway.networking.k8s.io/gateway-name=boutique-gateway \
    -o jsonpath='{.items[0].status.loadBalancer.ingress[0].hostname}' 2>/dev/null || true)
fi

[ -f "$DNS_FILE" ] || err "DNS file not found: $DNS_FILE"
[ -n "$TARGET_NLB" ] || err "Could not determine the target NLB ($TARGET_DESC)"

log "Rollback target: $TARGET_DESC"
log "Hostname:        $HOSTNAME"
log "Hosted zone:     $HOSTED_ZONE"
log "Target NLB:      $TARGET_NLB"
log "DNS file:        $DNS_FILE"
echo

# Verify placeholders in the JSON were replaced
if grep -q '<.*_NLB_' "$DNS_FILE"; then
  warn "File $DNS_FILE still has placeholders (<INGRESS_NLB_*>, <GATEWAY_NLB_*>)."
  warn "Before doing a rollback under pressure, those files must have the real values."
  warn "Edit them NOW with your real values or apply manually."
  err "Aborting: file not ready for production"
fi

# Verify the target NLB is healthy (at least resolves)
if ! dig +short "$TARGET_NLB" | grep -qE '^[0-9]+\.'; then
  warn "Target NLB ($TARGET_NLB) does not resolve to an IP. Is it down?"
  warn "Continuing anyway because the DNS rollback is the priority, but verify this."
fi

# DRY RUN
if [ "$DRY_RUN" = "1" ]; then
  log "DRY RUN — command that would run:"
  echo "    aws route53 change-resource-record-sets \\"
  echo "      --hosted-zone-id $HOSTED_ZONE \\"
  echo "      --change-batch file://$DNS_FILE"
  exit 0
fi

# Apply the change
log "Applying DNS change..."
CHANGE_ID=$(aws route53 change-resource-record-sets \
  --hosted-zone-id "$HOSTED_ZONE" \
  --change-batch "file://$DNS_FILE" \
  --query 'ChangeInfo.Id' \
  --output text) || err "Failed applying the DNS change"

log "Change ID: $CHANGE_ID"
log "Waiting for the change to propagate (INSYNC)..."

# Wait for INSYNC (Route 53 propagates internally; public resolvers can take
# longer due to TTL)
for i in {1..60}; do
  STATUS=$(aws route53 get-change --id "$CHANGE_ID" --query 'ChangeInfo.Status' --output text 2>/dev/null || echo "")
  if [ "$STATUS" = "INSYNC" ]; then
    ok "Change INSYNC in Route 53"
    break
  fi
  echo -n "."
  sleep 5
done
echo

if [ "$STATUS" != "INSYNC" ]; then
  warn "Change did not reach INSYNC after 5 min. Continue the rollback manually."
fi

# Smoke test
log "Waiting 30s for clients with low TTL to pick up the change..."
sleep 30

log "Smoke test against $HOSTNAME..."
RESULT=$(curl -sS -k -o /dev/null --max-time 10 \
  -w "%{http_code}|%{time_total}" \
  "https://$HOSTNAME/" 2>&1 || echo "ERROR|0")
STATUS_CODE="${RESULT%%|*}"

if [[ "$STATUS_CODE" =~ ^[23] ]]; then
  ok "Smoke test OK (status=$STATUS_CODE)"
elif [[ "$STATUS_CODE" =~ ^5 ]] || [ "$STATUS_CODE" = "ERROR" ]; then
  err "Smoke test FAILED (status=$STATUS_CODE). Check manually. Possible TTL not yet propagated."
else
  warn "Smoke test returned status=$STATUS_CODE (not 5xx but not 2xx/3xx either). Review."
fi

ok "Rollback complete. Traffic is now 100% on $TARGET_DESC."
log ""
log "Suggested next steps:"
log "  1. Check error rate / latency dashboards."
log "  2. Check logs of the active controller: kubectl logs -n <ns> ..."
log "  3. Do NOT uninstall the other controller yet — keep it in case of re-rollback."
log "  4. Run a post-mortem of what caused the rollback before the next attempt."
