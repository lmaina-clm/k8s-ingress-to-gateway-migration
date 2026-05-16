#!/usr/bin/env bash
# =============================================================================
# validate-traffic.sh
# =============================================================================
# Smoke tests contra el NLB de ingress-nginx, el de NGINX Gateway Fabric, o
# ambos. Hace requests a una lista de paths usando el Host: header, así no
# depende del estado del DNS público.
#
# Uso:
#   ./scripts/validate-traffic.sh ingress          # solo ingress-nginx
#   ./scripts/validate-traffic.sh gateway          # solo NGF
#   ./scripts/validate-traffic.sh both             # ambos, en paralelo
#   ./scripts/validate-traffic.sh ingress <NLB>    # forzar hostname del NLB
#
# Salida: tabla con status, latencia, tamaño respuesta por path/target.
# Exit code: 0 si todos los requests son <500, 1 si algún 5xx.
#
# Variables de entorno opcionales:
#   HOSTNAME_HEADER   (default: shop.example.com)
#   PROTOCOL          (default: https)
#   PATHS             (default: lista de paths de Online Boutique)
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
Uso: $0 <target> [nlb_hostname]

  target: ingress | gateway | both

Variables de entorno:
  HOSTNAME_HEADER   hostname para el Host: header (default: shop.example.com)
  PROTOCOL          http | https (default: https)
  PATHS             paths a probar, separados por espacios
EOF
  exit 1
}

[ $# -lt 1 ] && usage

TARGET="$1"
FORCED_NLB="${2:-}"

log() { echo -e "${BLUE}[validate]${NC} $*"; }
ok() { echo -e "${GREEN}✓${NC} $*"; }
fail() { echo -e "${RED}✗${NC} $*"; }

# Resolver el NLB hostname según el target
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
  # Buscar el Service que NGF crea para el data plane
  kubectl -n gateway-system get svc \
    -l gateway.networking.k8s.io/gateway-name=boutique-gateway \
    -o jsonpath='{.items[0].status.loadBalancer.ingress[0].hostname}' 2>/dev/null
}

# Test contra un NLB específico
test_nlb() {
  local label="$1"
  local nlb="$2"
  local failed=0

  if [ -z "$nlb" ]; then
    fail "$label: no se pudo determinar hostname del NLB"
    return 1
  fi

  log "Probando $label contra $nlb (Host: $HOSTNAME_HEADER)"
  echo

  # Resolver el NLB a una IP (curl --resolve necesita IP, no hostname).
  # Usamos dig porque es portable entre Linux y macOS (getent no existe en macOS).
  local nlb_ip
  nlb_ip=$(dig +short "$nlb" 2>/dev/null | grep -E '^[0-9]+\.' | head -1)
  if [ -z "$nlb_ip" ]; then
    fail "$label: no se pudo resolver IP de $nlb (¿dig instalado? ¿DNS funcionando?)"
    return 1
  fi

  local port
  if [ "$PROTOCOL" = "https" ]; then
    port=443
  else
    port=80
  fi

  printf "  %-40s  %-7s  %-10s  %-10s\n" "PATH" "STATUS" "LATENCIA" "TAMAÑO"
  printf "  %-40s  %-7s  %-10s  %-10s\n" "----" "------" "--------" "------"

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

    # latencia en ms
    local latency_ms
    latency_ms=$(awk "BEGIN{printf \"%.0f\", $latency*1000}" 2>/dev/null || echo "?")

    local status_color="$GREEN"
    if [[ "$status" =~ ^5 ]] || [ "$status" = "ERROR" ]; then
      status_color="$RED"
      failed=$((failed+1))
    elif [[ "$status" =~ ^4 ]]; then
      # 301/302/308 ya están manejados arriba; 4xx puede ser intencional (eg 404 en path inexistente)
      status_color="$YELLOW"
    fi

    printf "  %-40s  ${status_color}%-7s${NC}  %-10s  %-10s\n" \
      "$path" "$status" "${latency_ms}ms" "$size"
  done

  echo
  if [ $failed -gt 0 ]; then
    fail "$label: $failed request(s) con 5xx o error"
    return 1
  else
    ok "$label: todos los requests OK"
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
