#!/usr/bin/env bash
# =============================================================================
# compare-responses.sh
# =============================================================================
# Compares responses between the ingress-nginx NLB and the NGINX Gateway
# Fabric NLB for a list of paths. It's the safety net before the DNS canary:
# if responses don't match (excluding volatile headers), there's probably a
# misturned annotation or a feature that wasn't migrated correctly.
#
# Usage:
#   ./scripts/compare-responses.sh
#   ./scripts/compare-responses.sh /path1 /path2 /path3   # custom paths
#
# Env vars:
#   HOSTNAME_HEADER   default: shop.example.com
#   PROTOCOL          default: https
#
# Exit code:
#   0 = all paths match
#   1 = at least one path differs significantly
#   2 = configuration error
# =============================================================================
set -uo pipefail

HOSTNAME_HEADER="${HOSTNAME_HEADER:-shop.example.com}"
PROTOCOL="${PROTOCOL:-https}"

DEFAULT_PATHS=(
  "/"
  "/product/OLJCESPC7Z"
  "/product/66VCHSJNUP"
  "/cart"
  "/static/styles/cart.css"
  "/static/styles/styles.css"
  "/_healthz"
)

if [ $# -gt 0 ]; then
  PATHS=("$@")
else
  PATHS=("${DEFAULT_PATHS[@]}")
fi

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log()  { echo -e "${BLUE}[compare]${NC} $*"; }
ok()   { echo -e "${GREEN}✓${NC} $*"; }
diff_warn() { echo -e "${YELLOW}~${NC} $*"; }
fail() { echo -e "${RED}✗${NC} $*"; }

# Discover NLBs
ING_NLB=$(kubectl -n ingress-nginx get svc ingress-nginx-controller \
  -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || true)
GW_NLB=$(kubectl -n gateway-system get svc \
  -l gateway.networking.k8s.io/gateway-name=boutique-gateway \
  -o jsonpath='{.items[0].status.loadBalancer.ingress[0].hostname}' 2>/dev/null || true)

if [ -z "$ING_NLB" ]; then
  fail "Could not find the ingress-nginx NLB (svc ingress-nginx-controller in ns ingress-nginx)"
  exit 2
fi
if [ -z "$GW_NLB" ]; then
  fail "Could not find the NGF NLB (svc with label gateway.networking.k8s.io/gateway-name=boutique-gateway in ns gateway-system)"
  exit 2
fi

log "Ingress NLB:  $ING_NLB"
log "Gateway NLB:  $GW_NLB"
log "Host header:  $HOSTNAME_HEADER"
log "Paths:        ${#PATHS[@]} to compare"
echo

# Resolve IPs
ING_IP=$(dig +short "$ING_NLB" | grep -E '^[0-9]+\.' | head -1)
GW_IP=$(dig +short "$GW_NLB" | grep -E '^[0-9]+\.' | head -1)
if [ -z "$ING_IP" ] || [ -z "$GW_IP" ]; then
  fail "Could not resolve IPs for one of the NLBs"
  exit 2
fi

PORT=443
[ "$PROTOCOL" = "http" ] && PORT=80

TMP=$(mktemp -d)
# Single quotes so $TMP expands when the trap fires, not when it's defined
trap 'rm -rf "$TMP"' EXIT

# Headers ignored in the comparison because they're volatile, expected to
# differ between the two controllers, or known and documented differences.
#
# Notes on headers documented as "expected to differ":
# - `strict-transport-security`: ingress-nginx injects it by default on HTTPS,
#   NGF doesn't. See docs/03-ingress-vs-gateway.md section "Security headers".
IGNORE_HEADERS_REGEX='^(date|x-request-id|x-correlation-id|server|x-trace-id|set-cookie|etag|via|nel|report-to|cf-ray|strict-transport-security)'

# Paths where the app serves different dynamic content per request
# (e.g. random recommendations from Online Boutique's frontend). For these,
# we only compare status code + headers, NOT the body. To compare them all,
# pass COMPARE_DYNAMIC_BODY=1.
DYNAMIC_BODY_PATHS_REGEX='^(/|/cart|/setCurrency)$'
COMPARE_DYNAMIC_BODY="${COMPARE_DYNAMIC_BODY:-0}"

fetch_to_files() {
  local nlb_ip="$1"
  local path="$2"
  local prefix="$3"

  curl -sS -k -o "$TMP/${prefix}_body" \
    -D "$TMP/${prefix}_headers" \
    --resolve "${HOSTNAME_HEADER}:${PORT}:${nlb_ip}" \
    --max-time 10 \
    -w "%{http_code}|%{time_total}|%{size_download}\n" \
    "${PROTOCOL}://${HOSTNAME_HEADER}${path}" \
    > "$TMP/${prefix}_meta" 2>/dev/null || echo "ERROR|0|0" > "$TMP/${prefix}_meta"
}

# Report
TOTAL=0
MATCHING=0
DIFFERING=0
ERRORED=0

for path in "${PATHS[@]}"; do
  TOTAL=$((TOTAL+1))

  fetch_to_files "$ING_IP" "$path" "ing"
  fetch_to_files "$GW_IP" "$path" "gw"

  ing_meta=$(cat "$TMP/ing_meta")
  gw_meta=$(cat "$TMP/gw_meta")
  ing_status="${ing_meta%%|*}"
  gw_status="${gw_meta%%|*}"

  # Case 1: error in one or both
  if [ "$ing_status" = "ERROR" ] || [ "$gw_status" = "ERROR" ]; then
    fail "$path: connection error (ingress=$ing_status, gateway=$gw_status)"
    ERRORED=$((ERRORED+1))
    continue
  fi

  # Case 2: different status codes
  if [ "$ing_status" != "$gw_status" ]; then
    fail "$path: different status codes (ingress=$ing_status, gateway=$gw_status)"
    DIFFERING=$((DIFFERING+1))
    continue
  fi

  # Case 3: body diff (skipped for dynamic-content paths unless override)
  body_diff=""
  if [[ "$path" =~ $DYNAMIC_BODY_PATHS_REGEX ]] && [ "$COMPARE_DYNAMIC_BODY" != "1" ]; then
    : # skip body comparison for dynamic-content paths
  elif ! diff -q "$TMP/ing_body" "$TMP/gw_body" >/dev/null 2>&1; then
    body_diff=$(diff <(cat "$TMP/ing_body") <(cat "$TMP/gw_body") | head -20 || true)
  fi

  # Case 4: significant headers differ
  ing_headers=$(grep -iE -v "$IGNORE_HEADERS_REGEX" "$TMP/ing_headers" | sort | tr -d '\r' || true)
  gw_headers=$(grep -iE -v "$IGNORE_HEADERS_REGEX" "$TMP/gw_headers" | sort | tr -d '\r' || true)
  header_diff=""
  if [ "$ing_headers" != "$gw_headers" ]; then
    header_diff=$(diff <(echo "$ing_headers") <(echo "$gw_headers") | head -20 || true)
  fi

  if [ -z "$body_diff" ] && [ -z "$header_diff" ]; then
    ok "$path: status=$ing_status, body match, headers match"
    MATCHING=$((MATCHING+1))
  else
    diff_warn "$path: status=$ing_status, but there are differences"
    if [ -n "$body_diff" ]; then
      echo -e "    ${YELLOW}body diff:${NC}"
      echo "$body_diff" | sed 's/^/      /'
    fi
    if [ -n "$header_diff" ]; then
      echo -e "    ${YELLOW}header diff:${NC}"
      echo "$header_diff" | sed 's/^/      /'
    fi
    DIFFERING=$((DIFFERING+1))
  fi
done

echo
log "Summary: $TOTAL paths tested"
log "  Match:        $MATCHING"
log "  Differing:    $DIFFERING"
log "  Errors:       $ERRORED"
echo

if [ $ERRORED -gt 0 ]; then
  fail "There were connection errors. Do NOT continue with the canary until they're resolved."
  exit 1
fi
if [ $DIFFERING -gt 0 ]; then
  diff_warn "There are differences between the two controllers. Review them before the canary."
  diff_warn "Some are acceptable (server header, new session set-cookie); others are not."
  exit 1
fi

ok "All paths match. Safe to continue with the DNS canary."
exit 0
