#!/usr/bin/env bash
# =============================================================================
# install-ingress-nginx.sh
# =============================================================================
# Instala ingress-nginx (último release v1.11.x) en el clúster, configurado
# para EKS con un NLB. Idempotente: corriendo dos veces no rompe.
#
# Uso:
#   ./scripts/install-ingress-nginx.sh
#
# Variables de entorno opcionales:
#   INGRESS_NS         (default: ingress-nginx)
#   INGRESS_VERSION    (default: 4.11.3 — Helm chart, no la versión del binario)
#   AWS_LB_SCHEME      (default: internet-facing; usar "internal" para LB privado)
# =============================================================================
set -euo pipefail

INGRESS_NS="${INGRESS_NS:-ingress-nginx}"
INGRESS_VERSION="${INGRESS_VERSION:-4.11.3}"
AWS_LB_SCHEME="${AWS_LB_SCHEME:-internet-facing}"

# Color output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log() { echo -e "${GREEN}[install-ingress-nginx]${NC} $*"; }
warn() { echo -e "${YELLOW}[install-ingress-nginx]${NC} $*"; }
err() { echo -e "${RED}[install-ingress-nginx]${NC} $*"; exit 1; }

# Preflight
command -v helm >/dev/null || err "helm no está instalado"
command -v kubectl >/dev/null || err "kubectl no está instalado"

CTX=$(kubectl config current-context)
log "Contexto actual: $CTX"
read -p "¿Continuar con este clúster? (y/N) " -n 1 -r
echo
[[ $REPLY =~ ^[Yy]$ ]] || err "Cancelado por usuario"

# Repo Helm
log "Agregando repo Helm de ingress-nginx..."
helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx --force-update
helm repo update

# Instalar / upgrade
log "Instalando ingress-nginx versión $INGRESS_VERSION en namespace $INGRESS_NS..."
helm upgrade --install ingress-nginx ingress-nginx/ingress-nginx \
  --namespace "$INGRESS_NS" \
  --create-namespace \
  --version "$INGRESS_VERSION" \
  --set controller.kind=Deployment \
  --set controller.replicaCount=2 \
  --set controller.service.type=LoadBalancer \
  --set controller.service.annotations."service\.beta\.kubernetes\.io/aws-load-balancer-type"=external \
  --set controller.service.annotations."service\.beta\.kubernetes\.io/aws-load-balancer-nlb-target-type"=ip \
  --set controller.service.annotations."service\.beta\.kubernetes\.io/aws-load-balancer-scheme"="$AWS_LB_SCHEME" \
  --set controller.service.annotations."service\.beta\.kubernetes\.io/aws-load-balancer-cross-zone-load-balancing-enabled"="true" \
  --set controller.config.use-forwarded-headers="true" \
  --set controller.config.compute-full-forwarded-for="true" \
  --set controller.metrics.enabled=true \
  --wait \
  --timeout 5m

log "Esperando a que el LoadBalancer tenga hostname..."
for i in {1..30}; do
  LB_HOSTNAME=$(kubectl -n "$INGRESS_NS" get svc ingress-nginx-controller \
    -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || true)
  if [ -n "$LB_HOSTNAME" ]; then
    break
  fi
  echo -n "."
  sleep 10
done
echo

[ -n "$LB_HOSTNAME" ] || err "LoadBalancer no obtuvo hostname tras 5 min"

log "✅ Instalación completa."
log "   NLB hostname: $LB_HOSTNAME"
log ""
log "Próximos pasos:"
log "   1. Aplicar el Ingress: kubectl apply -f manifests/02-ingress-nginx/"
log "   2. Configurar DNS para apuntar a $LB_HOSTNAME"
