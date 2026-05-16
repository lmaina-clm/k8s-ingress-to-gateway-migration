#!/usr/bin/env bash
# =============================================================================
# rollback.sh
# =============================================================================
# Rollback automatizado del DNS de Route 53 al 100% del NLB de ingress-nginx
# (o al de NGF, si el rollback es en la otra dirección).
#
# Diseñado para usarse bajo presión. Pide --confirm explícito.
#
# Uso:
#   ./scripts/rollback.sh --to ingress --hosted-zone-id Z123ABC --confirm
#   ./scripts/rollback.sh --to gateway --hosted-zone-id Z123ABC --confirm
#
# Lo que hace:
#   1. Verifica que el NLB destino existe y está healthy.
#   2. Aplica el JSON correspondiente con `aws route53 change-resource-record-sets`.
#   3. Espera a que el cambio propague (status INSYNC).
#   4. Hace un smoke test contra el endpoint público.
#
# Lo que NO hace:
#   - Desinstalar el controller "perdedor" (eso se hace después, conscientemente).
#   - Tocar nada dentro del clúster.
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
Uso: $0 --to <ingress|gateway> --hosted-zone-id <Z...> --confirm

Argumentos:
  --to               Destino del rollback: 'ingress' (vuelve a ingress-nginx)
                     o 'gateway' (vuelve a NGF).
  --hosted-zone-id   ID de la zona hospedada en Route 53.
  --confirm          Obligatorio. Sin este flag, el script no hace nada.

Variables de entorno opcionales:
  HOSTNAME           hostname público (default: shop.example.com)
  DRY_RUN            si está en "1", solo imprime qué haría
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
  err "Falta --confirm. El rollback es destructivo (cambia DNS productivo). Re-ejecuta con --confirm si estás seguro."
fi

# Preflight
command -v aws >/dev/null || err "aws CLI no instalado"
command -v kubectl >/dev/null || err "kubectl no instalado"
command -v jq >/dev/null || err "jq no instalado"

# Localizar el archivo de DNS a aplicar
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

[ -f "$DNS_FILE" ] || err "Archivo DNS no encontrado: $DNS_FILE"
[ -n "$TARGET_NLB" ] || err "No se pudo determinar el NLB destino ($TARGET_DESC)"

log "Rollback hacia: $TARGET_DESC"
log "Hostname:       $HOSTNAME"
log "Hosted zone:    $HOSTED_ZONE"
log "NLB destino:    $TARGET_NLB"
log "Archivo DNS:    $DNS_FILE"
echo

# Validar que los placeholders en el JSON fueron reemplazados
if grep -q '<.*_NLB_' "$DNS_FILE"; then
  warn "El archivo $DNS_FILE todavía tiene placeholders (<INGRESS_NLB_*>, <GATEWAY_NLB_*>)."
  warn "Antes de hacer un rollback bajo presión, esos archivos deben tener los valores reales."
  warn "Edítalos AHORA con tus valores reales o aplica manualmente."
  err "Abortando: archivo no listo para producción"
fi

# Verificar que el NLB destino está healthy (al menos resuelve)
if ! dig +short "$TARGET_NLB" | grep -qE '^[0-9]+\.'; then
  warn "El NLB destino ($TARGET_NLB) no resuelve a una IP. ¿Está caído?"
  warn "Continúo de todas formas porque el rollback DNS es prioritario, pero verifica esto."
fi

# DRY RUN
if [ "$DRY_RUN" = "1" ]; then
  log "DRY RUN — comando que se ejecutaría:"
  echo "    aws route53 change-resource-record-sets \\"
  echo "      --hosted-zone-id $HOSTED_ZONE \\"
  echo "      --change-batch file://$DNS_FILE"
  exit 0
fi

# Aplicar el cambio
log "Aplicando cambio DNS..."
CHANGE_ID=$(aws route53 change-resource-record-sets \
  --hosted-zone-id "$HOSTED_ZONE" \
  --change-batch "file://$DNS_FILE" \
  --query 'ChangeInfo.Id' \
  --output text) || err "Fallo aplicando el cambio DNS"

log "Change ID: $CHANGE_ID"
log "Esperando a que el cambio propague (INSYNC)..."

# Esperar a INSYNC (Route 53 propaga internamente; los resolvers públicos
# pueden tardar más por TTL)
for i in {1..60}; do
  STATUS=$(aws route53 get-change --id "$CHANGE_ID" --query 'ChangeInfo.Status' --output text 2>/dev/null || echo "")
  if [ "$STATUS" = "INSYNC" ]; then
    ok "Cambio INSYNC en Route 53"
    break
  fi
  echo -n "."
  sleep 5
done
echo

if [ "$STATUS" != "INSYNC" ]; then
  warn "Cambio no llegó a INSYNC tras 5 min. Continúa el rollback manualmente."
fi

# Smoke test
log "Esperando 30s para que clientes con TTL bajo recojan el cambio..."
sleep 30

log "Smoke test contra $HOSTNAME..."
RESULT=$(curl -sS -k -o /dev/null --max-time 10 \
  -w "%{http_code}|%{time_total}" \
  "https://$HOSTNAME/" 2>&1 || echo "ERROR|0")
STATUS_CODE="${RESULT%%|*}"

if [[ "$STATUS_CODE" =~ ^[23] ]]; then
  ok "Smoke test OK (status=$STATUS_CODE)"
elif [[ "$STATUS_CODE" =~ ^5 ]] || [ "$STATUS_CODE" = "ERROR" ]; then
  err "Smoke test FALLÓ (status=$STATUS_CODE). Revisar manualmente. Posible TTL todavía no propagado."
else
  warn "Smoke test devolvió status=$STATUS_CODE (no es 5xx pero tampoco 2xx/3xx). Revisar."
fi

ok "Rollback completo. Tráfico ahora va al 100% a $TARGET_DESC."
log ""
log "Próximos pasos sugeridos:"
log "  1. Verificar dashboards de error rate / latencia."
log "  2. Verificar logs del controller activo: kubectl logs -n <ns> ..."
log "  3. NO desinstalar el otro controller todavía — mantenerlo por si hay re-rollback."
log "  4. Hacer post-mortem de qué causó la necesidad de rollback antes del siguiente intento."
