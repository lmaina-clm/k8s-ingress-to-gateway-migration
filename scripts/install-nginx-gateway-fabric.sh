#!/usr/bin/env bash
# =============================================================================
# install-nginx-gateway-fabric.sh
# =============================================================================
# Installs Gateway API CRDs (v1.5.1) + NGINX Gateway Fabric (v2.6.x) on the
# cluster. Idempotent.
#
# Usage:
#   ./scripts/install-nginx-gateway-fabric.sh
#
# Optional env vars:
#   GATEWAY_API_VERSION    (default: v1.5.1)
#   NGF_NAMESPACE          (default: nginx-gateway)
#   NGF_VERSION            (default: 2.6.0)
#   GATEWAY_CLASS_NAME     (default: nginx-gateway)
#   SKIP_CONFIRM           (default: 0 — set to "1" to skip the interactive
#                          confirmation; useful in automated runbooks)
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
command -v helm >/dev/null || err "helm is not installed"
command -v kubectl >/dev/null || err "kubectl is not installed"

CTX=$(kubectl config current-context)
log "Current context: $CTX"
if [ "$SKIP_CONFIRM" != "1" ]; then
  read -p "Continue with this cluster? (y/N) " -n 1 -r
  echo
  [[ $REPLY =~ ^[Yy]$ ]] || err "Cancelled by user"
else
  log "SKIP_CONFIRM=1 — skipping interactive confirmation"
fi

# Step 1: Gateway API CRDs
log "Installing Gateway API CRDs ($GATEWAY_API_VERSION)..."
kubectl apply -f "https://github.com/kubernetes-sigs/gateway-api/releases/download/${GATEWAY_API_VERSION}/standard-install.yaml"

log "Waiting for CRDs to be established..."
for crd in gateways.gateway.networking.k8s.io \
           gatewayclasses.gateway.networking.k8s.io \
           httproutes.gateway.networking.k8s.io \
           grpcroutes.gateway.networking.k8s.io \
           referencegrants.gateway.networking.k8s.io; do
  kubectl wait --for=condition=Established crd/$crd --timeout=60s
done

# Step 2: NGINX Gateway Fabric via Helm (OCI registry)
log "Installing NGINX Gateway Fabric $NGF_VERSION..."

# Create namespace if it doesn't exist (Helm 3.14+ creates it with
# --create-namespace, but we do it explicitly for compat)
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

# Step 3: Verify the GatewayClass is accepted
log "Verifying GatewayClass '$GATEWAY_CLASS_NAME'..."
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

[ "$STATUS" = "True" ] || err "GatewayClass '$GATEWAY_CLASS_NAME' is not Accepted after 60s"

log "✅ Installation complete."
log ""
log "Next steps:"
log "   1. Apply namespaces and ReferenceGrant: kubectl apply -f manifests/00-base/"
log "   2. Copy the TLS cert to the gateway-system namespace (or use cert-manager)"
log "   3. Apply Gateway and HTTPRoutes: kubectl apply -f manifests/03-gateway-api/"
log "   4. Verify: kubectl get gateway -A && kubectl get httproute -A"
