#!/usr/bin/env bash
# =============================================================================
# setup-eks-demo-cluster.sh
# =============================================================================
# Creates a small EKS cluster to validate the ingress→Gateway migration.
# Designed for short sessions (1-3h) in a dedicated region.
#
# What it creates:
#   - EKS cluster with OIDC enabled (required for IRSA)
#   - 1 managed nodegroup with 2 t3.medium nodes
#   - Default addons (vpc-cni, coredns, kube-proxy)
#   - IAM policy + IRSA service account for AWS Load Balancer Controller
#   - AWS Load Balancer Controller via Helm
#
# What it does NOT create:
#   - ingress-nginx, NGF, Online Boutique (those come from the runbook)
#
# Usage (defaults tuned for an eu-west-1 demo):
#   ./scripts/setup-eks-demo-cluster.sh
#
# Optional env vars:
#   CLUSTER_NAME   (default: ingress-gw-demo)
#   REGION         (default: eu-west-1)
#   K8S_VERSION    (default: 1.35 — latest version in EKS standard support.
#                   Versions <= 1.32 are in extended support with control
#                   plane priced above $0.10/h)
#   NODE_TYPE      (default: t3.medium)
#   NODE_COUNT     (default: 2)
#   AWS_LB_CTRL_VERSION   (default: 1.8.3 — Helm chart version)
#
# Idempotent: running it twice does NOT recreate the cluster if it already
# exists; it only reinstalls/upgrades the components.
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

command -v aws >/dev/null     || err "aws CLI not installed (install AWS CLI v2)"
command -v eksctl >/dev/null  || err "eksctl not installed (https://eksctl.io/installation/)"
command -v kubectl >/dev/null || err "kubectl not installed"
command -v helm >/dev/null    || err "helm not installed"
command -v jq >/dev/null      || err "jq not installed"
command -v curl >/dev/null    || err "curl not installed"

ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text 2>/dev/null) \
  || err "AWS credentials not working. Set AWS_PROFILE or run 'aws configure'."
CALLER=$(aws sts get-caller-identity --query Arn --output text)

log "AWS account:      $ACCOUNT_ID"
log "AWS caller:       $CALLER"
log "Region:           $REGION"
log "Cluster:          $CLUSTER_NAME"
log "K8s version:      $K8S_VERSION"
log "Nodes:            $NODE_COUNT × $NODE_TYPE"

if [ "${SKIP_CONFIRM:-0}" != "1" ]; then
  read -p "Continue and create the cluster? (y/N) " -n 1 -r
  echo
  [[ $REPLY =~ ^[Yy]$ ]] || err "Cancelled by user"
fi

# =============================================================================
# Step 1: Create the EKS cluster (if it doesn't exist)
# =============================================================================
if eksctl get cluster --name "$CLUSTER_NAME" --region "$REGION" >/dev/null 2>&1; then
  warn "Cluster '$CLUSTER_NAME' already exists in $REGION. Skipping creation."
else
  log "Creating EKS cluster (this takes ~15 min)..."

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

  log "eksctl config at $TMP_CFG"
  eksctl create cluster -f "$TMP_CFG"
  rm -f "$TMP_CFG"
fi

# =============================================================================
# Step 2: Configure kubectl
# =============================================================================
log "Configuring kubeconfig..."
aws eks update-kubeconfig --name "$CLUSTER_NAME" --region "$REGION" >/dev/null
kubectl config set-context --current --namespace=default >/dev/null
ok "kubectl points to $(kubectl config current-context)"

# =============================================================================
# Step 3: AWS Load Balancer Controller — IAM policy
# =============================================================================
log "Configuring IAM policy for AWS Load Balancer Controller..."

POLICY_NAME="AWSLoadBalancerControllerIAMPolicy-${CLUSTER_NAME}"
POLICY_ARN="arn:aws:iam::${ACCOUNT_ID}:policy/${POLICY_NAME}"

if aws iam get-policy --policy-arn "$POLICY_ARN" >/dev/null 2>&1; then
  warn "Policy $POLICY_NAME already exists — reusing."
else
  POLICY_DOC=$(mktemp -t lbcpolicy.XXXXXX.json)
  curl -sSL -o "$POLICY_DOC" \
    https://raw.githubusercontent.com/kubernetes-sigs/aws-load-balancer-controller/v2.8.3/docs/install/iam_policy.json
  aws iam create-policy \
    --policy-name "$POLICY_NAME" \
    --policy-document "file://$POLICY_DOC" >/dev/null
  rm -f "$POLICY_DOC"
  ok "Policy $POLICY_NAME created."
fi

# =============================================================================
# Step 4: IRSA service account
# =============================================================================
log "Configuring IRSA service account for AWS LB Controller..."

if eksctl get iamserviceaccount \
     --cluster "$CLUSTER_NAME" \
     --region "$REGION" \
     --namespace kube-system 2>/dev/null \
   | grep -q aws-load-balancer-controller; then
  warn "IRSA service account already exists — skipping."
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
# Step 5: Install AWS Load Balancer Controller via Helm
# =============================================================================
log "Installing AWS Load Balancer Controller v${AWS_LB_CTRL_VERSION}..."

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

ok "AWS Load Balancer Controller installed."

# =============================================================================
# Summary
# =============================================================================
echo
ok "Cluster ready."
log ""
log "Summary:"
log "  Cluster:       $CLUSTER_NAME ($REGION)"
log "  Account:       $ACCOUNT_ID"
log "  Nodes:         $NODE_COUNT × $NODE_TYPE"
log "  kubectl ctx:   $(kubectl config current-context)"
log ""
log "Next step: follow docs/09-fast-validation-runbook.md from Phase 2."
log ""
log "To destroy everything when done:"
log "  ./scripts/teardown-eks-demo-cluster.sh"
