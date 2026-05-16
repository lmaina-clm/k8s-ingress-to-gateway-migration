#!/usr/bin/env bash
# =============================================================================
# validate-traffic.sh
# =============================================================================
# Smoke tests against the ingress-nginx NLB, the NGINX Gateway Fabric NLB, or
# both. Makes requests to a list of paths using the Host: header, so it does
# not depend on public DNS state.
#
# Usage:
#   ./scripts/validate-traffic.sh ingress          # ingress-nginx only
#   ./scripts/validate-traffic.sh gateway          # NGF only
#   ./scripts/validate-traffic.sh both             # both, in parallel
#   ./scripts/validate-traffic.sh ingress <NLB>    # force the NLB hostname
#
# Output: table with status, latency, response size per path/target.
# Exit code: 0 if all requests are <500, 1 if any 5xx.
#
# Optional env vars:
#   HOSTNAME_HEADER   (default: shop.example.com)
#   PROTOCOL          (default: https)
#   PATHS             (default: list of Online Boutique paths)
# =============================================================================
set -uo pipefail

HOSTNAME_HEADER="${HOSTNAME_HEADER:-shop.example.com}"
PROTOCOL="${PROTOCOL:-https}"
PATHS="${PATHS:-/ /product/OLJCESPC7Z /cart /static/styles/cart.css}"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

usage() {
  cat <<EOF
Usage: $0 <target> [nlb_hostname]

  target: ingress | gateway | both

Env vars:
  HOSTNAME_HEADER   hostname for the Host: header (default: shop.example.com)
  PROTOCOL          http | https (default: https)
  PATHS             paths to test, space-separated
EOF
  exit 1
}

[ $# -lt 1 ] && usage

TARGET="$1"
FORCED_NLB="${2:-}"

log() { echo -e "${BLUE}[validate]${NC} $*"; }
ok() { echo -e "${GREEN}✓${NC} $*"; }
fail() { echo -e "${RED}✗${NC} $*"; }

# Resolve the NLB hostname for the given target
get_ingress_nlb() {
  if [ -n "$FORCED_NLB" ] && [ "$TARGET" = "ingress" ]; then
    echo "$FORCED_NLB"
    return
  fi
  kubectl -n ingress-nginx get svc ingress-nginx-controller \
    -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null
}

get_gateway_nlb() {
  if [ -n "$FORCED_NLB" ] && [ "$TARGET" = "gateway" ]; then
    echo "$FORCED_NLB"
    return
  fi
  # Find the Service NGF creates for the data plane
  kubectl -n gateway-system get svc \
    -l gateway.networking.k8s.io/gateway-name=boutique-gateway \
    -o jsonpath='{.items[0].status.loadBalancer.ingress[0].hostname}' 2>/dev/null
}

# Test against a specific NLB
test_nlb() {
  local label="$1"
  local nlb="$2"
  local failed=0

  if [ -z "$nlb" ]; then
    fail "$label: could not determine NLB hostname"
    return 1
  fi

  log "Testing $label against $nlb (Host: $HOSTNAME_HEADER)"
  echo

  # Resolve the NLB to an IP (curl --resolve needs IP, not hostname).
  # We use dig because it's portable between Linux and macOS (getent doesn't
  # exist on macOS).
  local nlb_ip
  nlb_ip=$(dig +short "$nlb" 2>/dev/null | grep -E '^[0-9]+\.' | head -1)
  if [ -z "$nlb_ip" ]; then
    fail "$label: could not resolve IP for $nlb (is dig installed? is DNS working?)"
    return 1
  fi

  local port
  if [ "$PROTOCOL" = "https" ]; then
    port=443
  else
    port=80
  fi

  printf "  %-40s  %-7s  %-10s  %-10s\n" "PATH" "STATUS" "LATENCY" "SIZE"
  printf "  %-40s  %-7s  %-10s  %-10s\n" "----" "------" "-------" "----"

  for path in $PATHS; do
    local result
    result=$(curl -sS -k -o /dev/null \
      --resolve "${HOSTNAME_HEADER}:${port}:${nlb_ip}" \
      --max-time 10 \
      -w "%{http_code}|%{time_total}|%{size_download}" \
      "${PROTOCOL}://${HOSTNAME_HEADER}${path}" 2>&1 || echo "ERROR|0|0")

    local status="${result%%|*}"
    local rest="${result#*|}"
    local latency="${rest%%|*}"
    local size="${rest##*|}"

    # latency in ms
    local latency_ms
    latency_ms=$(awk "BEGIN{printf \"%.0f\", $latency*1000}" 2>/dev/null || echo "?")

    local status_color="$GREEN"
    if [[ "$status" =~ ^5 ]] || [ "$status" = "ERROR" ]; then
      status_color="$RED"
      failed=$((failed+1))
    elif [[ "$status" =~ ^4 ]]; then
      # 301/302/308 are handled above; 4xx can be intentional (e.g. 404 on a nonexistent path)
      status_color="$YELLOW"
    fi

    printf "  %-40s  ${status_color}%-7s${NC}  %-10s  %-10s\n" \
      "$path" "$status" "${latency_ms}ms" "$size"
  done

  echo
  if [ $failed -gt 0 ]; then
    fail "$label: $failed request(s) returned 5xx or error"
    return 1
  else
    ok "$label: all requests OK"
    return 0
  fi
}

# Main
RC=0
case "$TARGET" in
  ingress)
    NLB=$(get_ingress_nlb)
    test_nlb "ingress-nginx" "$NLB" || RC=1
    ;;
  gateway)
    NLB=$(get_gateway_nlb)
    test_nlb "nginx-gateway-fabric" "$NLB" || RC=1
    ;;
  both)
    ING_NLB=$(get_ingress_nlb)
    GW_NLB=$(get_gateway_nlb)
    test_nlb "ingress-nginx" "$ING_NLB" || RC=1
    test_nlb "nginx-gateway-fabric" "$GW_NLB" || RC=1
    ;;
  *)
    usage
    ;;
esac

exit $RC
