#!/usr/bin/env bash
# =============================================================================
# setup-eks-demo-cluster.sh
# =============================================================================
# Crea un cluster EKS pequeño para validar la migración ingress→Gateway.
# Pensado para sesiones cortas (1-3h) en una región dedicada.
#
# Lo que crea:
#   - Cluster EKS con OIDC habilitado (necesario para IRSA)
#   - 1 managed nodegroup con 2 t3.medium
#   - Addons básicos (vpc-cni, coredns, kube-proxy)
#   - IAM policy + IRSA service account para AWS Load Balancer Controller
#   - AWS Load Balancer Controller vía Helm
#
# Lo que NO crea:
#   - ingress-nginx, NGF, Online Boutique (eso lo hace el runbook)
#
# Uso (defaults pensados para una demo en eu-west-1):
#   ./scripts/setup-eks-demo-cluster.sh
#
# Variables de entorno opcionales:
#   CLUSTER_NAME   (default: ingress-gw-demo)
#   REGION         (default: eu-west-1)
#   K8S_VERSION    (default: 1.35 — última versión soportada en EKS standard
#                   support. Versiones <= 1.32 están en extended support con
#                   precio del control plane mayor a $0.10/h)
#   NODE_TYPE      (default: t3.medium)
#   NODE_COUNT     (default: 2)
#   AWS_LB_CTRL_VERSION   (default: 1.8.3 — versión del Helm chart)
#
# Idempotente: corriendo dos veces NO recrea el cluster si ya existe; solo
# reinstala/upgradea los componentes.
# =============================================================================
set -euo pipefail

CLUSTER_NAME="${CLUSTER_NAME:-ingress-gw-demo}"
REGION="${REGION:-eu-west-1}"
K8S_VERSION="${K8S_VERSION:-1.35}"
NODE_TYPE="${NODE_TYPE:-t3.medium}"
NODE_COUNT="${NODE_COUNT:-2}"
AWS_LB_CTRL_VERSION="${AWS_LB_CTRL_VERSION:-1.8.3}"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log()  { echo -e "${BLUE}[setup]${NC} $*"; }
ok()   { echo -e "${GREEN}✓${NC} $*"; }
warn() { echo -e "${YELLOW}!${NC} $*"; }
err()  { echo -e "${RED}✗${NC} $*" >&2; exit 1; }

# =============================================================================
# Preflight
# =============================================================================
log "Preflight checks..."

command -v aws >/dev/null     || err "aws CLI no instalado (instala AWS CLI v2)"
command -v eksctl >/dev/null  || err "eksctl no instalado (https://eksctl.io/installation/)"
command -v kubectl >/dev/null || err "kubectl no instalado"
command -v helm >/dev/null    || err "helm no instalado"
command -v jq >/dev/null      || err "jq no instalado"
command -v curl >/dev/null    || err "curl no instalado"

ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text 2>/dev/null) \
  || err "AWS credentials no funcionan. Configura AWS_PROFILE o aws configure."
CALLER=$(aws sts get-caller-identity --query Arn --output text)

log "AWS account:      $ACCOUNT_ID"
log "AWS caller:       $CALLER"
log "Región:           $REGION"
log "Cluster:          $CLUSTER_NAME"
log "K8s version:      $K8S_VERSION"
log "Nodos:            $NODE_COUNT × $NODE_TYPE"

if [ "${SKIP_CONFIRM:-0}" != "1" ]; then
  read -p "¿Continuar y crear el cluster? (y/N) " -n 1 -r
  echo
  [[ $REPLY =~ ^[Yy]$ ]] || err "Cancelado por usuario"
fi

# =============================================================================
# Paso 1: Crear el cluster EKS (si no existe)
# =============================================================================
if eksctl get cluster --name "$CLUSTER_NAME" --region "$REGION" >/dev/null 2>&1; then
  warn "El cluster '$CLUSTER_NAME' ya existe en $REGION. Saltando creación."
else
  log "Creando cluster EKS (esto tarda ~15 min)..."

  TMP_CFG=$(mktemp -t ekscfg.XXXXXX.yaml)
  cat > "$TMP_CFG" <<EOF
apiVersion: eksctl.io/v1alpha5
kind: ClusterConfig

metadata:
  name: $CLUSTER_NAME
  region: $REGION
  version: "$K8S_VERSION"
  tags:
    purpose: ingress-to-gateway-demo
    managed-by: setup-eks-demo-cluster.sh

iam:
  withOIDC: true

managedNodeGroups:
  - name: workers
    instanceType: $NODE_TYPE
    desiredCapacity: $NODE_COUNT
    minSize: $NODE_COUNT
    maxSize: $((NODE_COUNT + 1))
    volumeSize: 30
    volumeType: gp3
    labels:
      role: worker
    iam:
      withAddonPolicies:
        externalDNS: false
        certManager: false
        ebs: false

addons:
  - name: vpc-cni
  - name: coredns
  - name: kube-proxy
EOF

  log "Config de eksctl en $TMP_CFG"
  eksctl create cluster -f "$TMP_CFG"
  rm -f "$TMP_CFG"
fi

# =============================================================================
# Paso 2: Configurar kubectl
# =============================================================================
log "Configurando kubeconfig..."
aws eks update-kubeconfig --name "$CLUSTER_NAME" --region "$REGION" >/dev/null
kubectl config set-context --current --namespace=default >/dev/null
ok "kubectl apunta a $(kubectl config current-context)"

# =============================================================================
# Paso 3: AWS Load Balancer Controller — IAM policy
# =============================================================================
log "Configurando IAM policy para AWS Load Balancer Controller..."

POLICY_NAME="AWSLoadBalancerControllerIAMPolicy-${CLUSTER_NAME}"
POLICY_ARN="arn:aws:iam::${ACCOUNT_ID}:policy/${POLICY_NAME}"

if aws iam get-policy --policy-arn "$POLICY_ARN" >/dev/null 2>&1; then
  warn "Policy $POLICY_NAME ya existe — reutilizando."
else
  POLICY_DOC=$(mktemp -t lbcpolicy.XXXXXX.json)
  curl -sSL -o "$POLICY_DOC" \
    https://raw.githubusercontent.com/kubernetes-sigs/aws-load-balancer-controller/v2.8.3/docs/install/iam_policy.json
  aws iam create-policy \
    --policy-name "$POLICY_NAME" \
    --policy-document "file://$POLICY_DOC" >/dev/null
  rm -f "$POLICY_DOC"
  ok "Policy $POLICY_NAME creada."
fi

# =============================================================================
# Paso 4: IRSA service account
# =============================================================================
log "Configurando IRSA service account para AWS LB Controller..."

if eksctl get iamserviceaccount \
     --cluster "$CLUSTER_NAME" \
     --region "$REGION" \
     --namespace kube-system 2>/dev/null \
   | grep -q aws-load-balancer-controller; then
  warn "IRSA service account ya existe — saltando."
else
  eksctl create iamserviceaccount \
    --cluster="$CLUSTER_NAME" \
    --region="$REGION" \
    --namespace=kube-system \
    --name=aws-load-balancer-controller \
    --attach-policy-arn="$POLICY_ARN" \
    --override-existing-serviceaccounts \
    --approve
fi

# =============================================================================
# Paso 5: Instalar AWS Load Balancer Controller vía Helm
# =============================================================================
log "Instalando AWS Load Balancer Controller v${AWS_LB_CTRL_VERSION}..."

helm repo add eks https://aws.github.io/eks-charts --force-update >/dev/null
helm repo update >/dev/null

VPC_ID=$(aws eks describe-cluster --name "$CLUSTER_NAME" --region "$REGION" \
  --query 'cluster.resourcesVpcConfig.vpcId' --output text)

helm upgrade --install aws-load-balancer-controller eks/aws-load-balancer-controller \
  --namespace kube-system \
  --version "$AWS_LB_CTRL_VERSION" \
  --set clusterName="$CLUSTER_NAME" \
  --set serviceAccount.create=false \
  --set serviceAccount.name=aws-load-balancer-controller \
  --set region="$REGION" \
  --set vpcId="$VPC_ID" \
  --wait \
  --timeout 5m

ok "AWS Load Balancer Controller instalado."

# =============================================================================
# Resumen
# =============================================================================
echo
ok "Cluster listo."
log ""
log "Resumen:"
log "  Cluster:       $CLUSTER_NAME ($REGION)"
log "  Account:       $ACCOUNT_ID"
log "  Nodos:         $NODE_COUNT × $NODE_TYPE"
log "  kubectl ctx:   $(kubectl config current-context)"
log ""
log "Próximo paso: seguir docs/09-fast-validation-runbook.md desde la Fase 2."
log ""
log "Para destruir todo cuando termines:"
log "  ./scripts/teardown-eks-demo-cluster.sh"
