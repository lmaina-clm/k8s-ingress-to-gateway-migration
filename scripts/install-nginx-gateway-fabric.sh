#!/usr/bin/env bash
# =============================================================================
# install-nginx-gateway-fabric.sh
# =============================================================================
# Instala Gateway API CRDs (v1.5.1) + NGINX Gateway Fabric (v2.6.x) en el
# clúster. Idempotente.
#
# Uso:
#   ./scripts/install-nginx-gateway-fabric.sh
#
# Variables de entorno opcionales:
#   GATEWAY_API_VERSION    (default: v1.5.1)
#   NGF_NAMESPACE          (default: nginx-gateway)
#   NGF_VERSION            (default: 2.6.0)
#   GATEWAY_CLASS_NAME     (default: nginx-gateway)
#   SKIP_CONFIRM           (default: 0 — set a "1" para no preguntar antes de
#                          instalar; útil en runbooks automatizados)
# =============================================================================
set -euo pipefail

GATEWAY_API_VERSION="${GATEWAY_API_VERSION:-v1.5.1}"
NGF_NAMESPACE="${NGF_NAMESPACE:-nginx-gateway}"
NGF_VERSION="${NGF_VERSION:-2.6.0}"
GATEWAY_CLASS_NAME="${GATEWAY_CLASS_NAME:-nginx-gateway}"
SKIP_CONFIRM="${SKIP_CONFIRM:-0}"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log() { echo -e "${GREEN}[install-ngf]${NC} $*"; }
warn() { echo -e "${YELLOW}[install-ngf]${NC} $*"; }
err() { echo -e "${RED}[install-ngf]${NC} $*"; exit 1; }

# Preflight
command -v helm >/dev/null || err "helm no está instalado"
command -v kubectl >/dev/null || err "kubectl no está instalado"

CTX=$(kubectl config current-context)
log "Contexto actual: $CTX"
if [ "$SKIP_CONFIRM" != "1" ]; then
  read -p "¿Continuar con este clúster? (y/N) " -n 1 -r
  echo
  [[ $REPLY =~ ^[Yy]$ ]] || err "Cancelado por usuario"
else
  log "SKIP_CONFIRM=1 — saltando confirmación interactiva"
fi

# Paso 1: Gateway API CRDs
log "Instalando Gateway API CRDs ($GATEWAY_API_VERSION)..."
kubectl apply -f "https://github.com/kubernetes-sigs/gateway-api/releases/download/${GATEWAY_API_VERSION}/standard-install.yaml"

log "Esperando a que los CRDs estén establecidos..."
for crd in gateways.gateway.networking.k8s.io \
           gatewayclasses.gateway.networking.k8s.io \
           httproutes.gateway.networking.k8s.io \
           grpcroutes.gateway.networking.k8s.io \
           referencegrants.gateway.networking.k8s.io; do
  kubectl wait --for=condition=Established crd/$crd --timeout=60s
done

# Paso 2: NGINX Gateway Fabric vía Helm (OCI registry)
log "Instalando NGINX Gateway Fabric $NGF_VERSION..."

# Crear namespace si no existe (Helm 3.14+ lo crea con --create-namespace, pero
# por compat hacemos esto explícitamente)
kubectl get namespace "$NGF_NAMESPACE" >/dev/null 2>&1 || \
  kubectl create namespace "$NGF_NAMESPACE"

helm upgrade --install ngf oci://ghcr.io/nginx/charts/nginx-gateway-fabric \
  --namespace "$NGF_NAMESPACE" \
  --version "$NGF_VERSION" \
  --set nginx.image.repository=ghcr.io/nginx/nginx-gateway-fabric/nginx \
  --set nginxGateway.gatewayClassName="$GATEWAY_CLASS_NAME" \
  --set nginxGateway.replicaCount=2 \
  --set nginxGateway.metrics.enable=true \
  --set nginxGateway.metrics.port=9113 \
  --set nginx.metrics.enable=true \
  --wait \
  --timeout 5m

# Paso 3: Verificar que el GatewayClass está aceptado
log "Verificando GatewayClass '$GATEWAY_CLASS_NAME'..."
for i in {1..30}; do
  STATUS=$(kubectl get gatewayclass "$GATEWAY_CLASS_NAME" \
    -o jsonpath='{.status.conditions[?(@.type=="Accepted")].status}' 2>/dev/null || true)
  if [ "$STATUS" = "True" ]; then
    break
  fi
  echo -n "."
  sleep 2
done
echo

[ "$STATUS" = "True" ] || err "GatewayClass '$GATEWAY_CLASS_NAME' no está Accepted tras 60s"

log "✅ Instalación completa."
log ""
log "Próximos pasos:"
log "   1. Aplicar namespaces y ReferenceGrant: kubectl apply -f manifests/00-base/"
log "   2. Copiar el cert TLS al namespace gateway-system (o usar cert-manager)"
log "   3. Aplicar Gateway y HTTPRoutes: kubectl apply -f manifests/03-gateway-api/"
log "   4. Verificar: kubectl get gateway -A && kubectl get httproute -A"
