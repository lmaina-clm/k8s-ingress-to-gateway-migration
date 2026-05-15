#!/usr/bin/env bash
# =============================================================================
# compare-responses.sh
# =============================================================================
# Compara las respuestas entre el NLB de ingress-nginx y el de NGINX Gateway
# Fabric para una lista de paths. Es la red de seguridad antes de hacer el
# canary DNS: si las respuestas no coinciden (sin contar headers volátiles),
# probablemente hay una anotación o feature mal migrada.
#
# Uso:
#   ./scripts/compare-responses.sh
#   ./scripts/compare-responses.sh /path1 /path2 /path3   # paths custom
#
# Variables de entorno:
#   HOSTNAME_HEADER   default: shop.example.com
#   PROTOCOL          default: https
#
# Exit code:
#   0 = todos los paths coinciden
#   1 = al menos un path difiere significativamente
#   2 = error de configuración
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

# Descubrir NLBs
ING_NLB=$(kubectl -n ingress-nginx get svc ingress-nginx-controller \
  -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || true)
GW_NLB=$(kubectl -n gateway-system get svc \
  -l gateway.nginx.org/gateway=boutique-gateway \
  -o jsonpath='{.items[0].status.loadBalancer.ingress[0].hostname}' 2>/dev/null || true)

if [ -z "$ING_NLB" ]; then
  fail "No se encontró el NLB de ingress-nginx (svc ingress-nginx-controller en ns ingress-nginx)"
  exit 2
fi
if [ -z "$GW_NLB" ]; then
  fail "No se encontró el NLB de NGF (svc con label gateway.nginx.org/gateway=boutique-gateway en ns gateway-system)"
  exit 2
fi

log "Ingress NLB:  $ING_NLB"
log "Gateway NLB:  $GW_NLB"
log "Host header:  $HOSTNAME_HEADER"
log "Paths:        ${#PATHS[@]} a comparar"
echo

# Resolver IPs
ING_IP=$(dig +short "$ING_NLB" | grep -E '^[0-9]+\.' | head -1)
GW_IP=$(dig +short "$GW_NLB" | grep -E '^[0-9]+\.' | head -1)
if [ -z "$ING_IP" ] || [ -z "$GW_IP" ]; then
  fail "No se pudo resolver IPs para uno de los NLBs"
  exit 2
fi

PORT=443
[ "$PROTOCOL" = "http" ] && PORT=80

TMP=$(mktemp -d)
# Comillas simples para que $TMP se expanda al ejecutar el trap, no al definirlo
trap 'rm -rf "$TMP"' EXIT

# Headers que se ignoran en la comparación porque son volátiles o esperados
# diferentes entre los dos controllers
IGNORE_HEADERS_REGEX='^(date|x-request-id|x-correlation-id|server|x-trace-id|set-cookie|etag|via|nel|report-to|cf-ray)'

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

# Reporte
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

  # Caso 1: error en uno o ambos
  if [ "$ing_status" = "ERROR" ] || [ "$gw_status" = "ERROR" ]; then
    fail "$path: error de conexión (ingress=$ing_status, gateway=$gw_status)"
    ERRORED=$((ERRORED+1))
    continue
  fi

  # Caso 2: status codes distintos
  if [ "$ing_status" != "$gw_status" ]; then
    fail "$path: status codes distintos (ingress=$ing_status, gateway=$gw_status)"
    DIFFERING=$((DIFFERING+1))
    continue
  fi

  # Caso 3: body diff
  body_diff=""
  if ! diff -q "$TMP/ing_body" "$TMP/gw_body" >/dev/null 2>&1; then
    body_diff=$(diff <(cat "$TMP/ing_body") <(cat "$TMP/gw_body") | head -20 || true)
  fi

  # Caso 4: headers significativos distintos
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
    diff_warn "$path: status=$ing_status, pero hay diferencias"
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
log "Resumen: $TOTAL paths probados"
log "  Match:       $MATCHING"
log "  Diferencias: $DIFFERING"
log "  Errores:     $ERRORED"
echo

if [ $ERRORED -gt 0 ]; then
  fail "Hubo errores de conexión. NO continuar con el canary hasta resolverlos."
  exit 1
fi
if [ $DIFFERING -gt 0 ]; then
  diff_warn "Hay diferencias entre los dos controllers. Revísalas antes del canary."
  diff_warn "Algunas son aceptables (server header, set-cookie de sesión nueva); otras no."
  exit 1
fi

ok "Todos los paths coinciden. Es seguro continuar con el canary DNS."
exit 0
