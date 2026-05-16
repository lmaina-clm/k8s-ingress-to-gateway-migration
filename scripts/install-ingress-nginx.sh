#!/usr/bin/env bash
# =============================================================================
# install-ingress-nginx.sh
# =============================================================================
# Installs ingress-nginx (latest v1.11.x release) on the cluster, configured
# for EKS with an NLB. Idempotent: running it twice doesn't break.
#
# Usage:
#   ./scripts/install-ingress-nginx.sh
#
# Optional env vars:
#   INGRESS_NS         (default: ingress-nginx)
#   INGRESS_VERSION    (default: 4.11.3 — Helm chart version, not the binary)
#   AWS_LB_SCHEME      (default: internet-facing; use "internal" for a private LB)
#   SKIP_CONFIRM       (default: 0 — set to "1" to skip the interactive
#                      confirmation; useful in automated runbooks)
# =============================================================================
set -euo pipefail

INGRESS_NS="${INGRESS_NS:-ingress-nginx}"
INGRESS_VERSION="${INGRESS_VERSION:-4.11.3}"
AWS_LB_SCHEME="${AWS_LB_SCHEME:-internet-facing}"
SKIP_CONFIRM="${SKIP_CONFIRM:-0}"

# Color output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log() { echo -e "${GREEN}[install-ingress-nginx]${NC} $*"; }
warn() { echo -e "${YELLOW}[install-ingress-nginx]${NC} $*"; }
err() { echo -e "${RED}[install-ingress-nginx]${NC} $*"; exit 1; }

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

# Helm repo
log "Adding ingress-nginx Helm repo..."
helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx --force-update
helm repo update

# Install / upgrade
log "Installing ingress-nginx version $INGRESS_VERSION in namespace $INGRESS_NS..."
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

log "Waiting for the LoadBalancer to get a hostname..."
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

[ -n "$LB_HOSTNAME" ] || err "LoadBalancer didn't get a hostname after 5 min"

log "✅ Installation complete."
log "   NLB hostname: $LB_HOSTNAME"
log ""
log "Next steps:"
log "   1. Apply the Ingress: kubectl apply -f manifests/02-ingress-nginx/"
log "   2. Configure DNS to point to $LB_HOSTNAME"
