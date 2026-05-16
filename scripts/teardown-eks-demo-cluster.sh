#!/usr/bin/env bash
# =============================================================================
# teardown-eks-demo-cluster.sh
# =============================================================================
# Destroys the cluster created by setup-eks-demo-cluster.sh, including:
#   - LoadBalancer Services (so AWS deletes the NLBs before the VPC)
#   - IRSA service account
#   - LB Controller IAM policy
#   - The EKS cluster (this removes VPC, subnets, NAT GW, etc.)
#
# Idempotent: if something doesn't exist, it skips without error.
#
# Usage:
#   ./scripts/teardown-eks-demo-cluster.sh --confirm
#
# Without --confirm, the script shows what it would delete and touches nothing
# (dry-run).
#
# Optional env vars:
#   CLUSTER_NAME   (default: ingress-gw-demo)
#   REGION         (default: eu-west-1)
# =============================================================================
set -uo pipefail

CLUSTER_NAME="${CLUSTER_NAME:-ingress-gw-demo}"
REGION="${REGION:-eu-west-1}"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log()  { echo -e "${BLUE}[teardown]${NC} $*"; }
ok()   { echo -e "${GREEN}✓${NC} $*"; }
warn() { echo -e "${YELLOW}!${NC} $*"; }
err()  { echo -e "${RED}✗${NC} $*" >&2; exit 1; }

CONFIRM=0
[ "${1:-}" = "--confirm" ] && CONFIRM=1

command -v aws >/dev/null     || err "aws CLI not installed"
command -v eksctl >/dev/null  || err "eksctl not installed"
command -v kubectl >/dev/null || err "kubectl not installed"

ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text 2>/dev/null) \
  || err "AWS credentials not working."

log "Account:    $ACCOUNT_ID"
log "Cluster:    $CLUSTER_NAME"
log "Region:     $REGION"
echo

if ! eksctl get cluster --name "$CLUSTER_NAME" --region "$REGION" >/dev/null 2>&1; then
  warn "Cluster '$CLUSTER_NAME' does not exist in $REGION. Nothing to delete at the EKS level."
  CLUSTER_EXISTS=0
else
  CLUSTER_EXISTS=1
fi

if [ "$CONFIRM" != "1" ]; then
  warn "DRY RUN — add --confirm to actually delete."
  log "Would be deleted:"
  [ "$CLUSTER_EXISTS" = "1" ] && log "  - EKS cluster: $CLUSTER_NAME"
  log "  - All LoadBalancer Services in the cluster (= NLBs in AWS)"
  log "  - IRSA service account: kube-system/aws-load-balancer-controller"
  log "  - IAM policy: AWSLoadBalancerControllerIAMPolicy-${CLUSTER_NAME}"
  exit 0
fi

# =============================================================================
# Step 1: Delete LoadBalancer Services BEFORE deleting the cluster
# =============================================================================
# Without this, the NLBs become orphaned and the VPC cannot be destroyed
# (the NLB ENIs block subnet deletion).
# =============================================================================
if [ "$CLUSTER_EXISTS" = "1" ]; then
  log "Configuring kubectl..."
  aws eks update-kubeconfig --name "$CLUSTER_NAME" --region "$REGION" >/dev/null 2>&1 || true

  if kubectl cluster-info >/dev/null 2>&1; then
    log "Deleting LoadBalancer Services (to clean up NLBs)..."
    LB_SVCS=$(kubectl get svc -A -o json | \
      jq -r '.items[] | select(.spec.type=="LoadBalancer") | "\(.metadata.namespace)/\(.metadata.name)"')

    if [ -n "$LB_SVCS" ]; then
      echo "$LB_SVCS" | while IFS='/' read -r ns name; do
        log "  - $ns/$name"
        kubectl delete svc "$name" -n "$ns" --wait=false --timeout=30s 2>/dev/null || true
      done

      # Wait for AWS to actually destroy the NLBs (without this, eksctl delete
      # cluster fails because the ENIs are still alive)
      log "Waiting 90s for AWS to destroy the NLBs..."
      sleep 90
    else
      ok "No LoadBalancer Services to delete."
    fi
  else
    warn "kubectl cannot reach the cluster (may already be degraded). Skipping Service deletion."
  fi

  # =============================================================================
  # Step 2: Delete the EKS cluster via eksctl
  # =============================================================================
  log "Deleting EKS cluster (this takes ~10 min)..."
  eksctl delete cluster --name "$CLUSTER_NAME" --region "$REGION" --wait \
    || warn "eksctl delete cluster reported errors. Check CloudFormation in the console."

  ok "Cluster deleted (or attempt completed)."
else
  log "Skipping cluster deletion (does not exist)."
fi

# =============================================================================
# Step 3: Delete the LB Controller IAM policy
# =============================================================================
POLICY_NAME="AWSLoadBalancerControllerIAMPolicy-${CLUSTER_NAME}"
POLICY_ARN="arn:aws:iam::${ACCOUNT_ID}:policy/${POLICY_NAME}"

if aws iam get-policy --policy-arn "$POLICY_ARN" >/dev/null 2>&1; then
  log "Deleting IAM policy $POLICY_NAME..."
  # Detach from any residual role before deleting
  ATTACHED_ROLES=$(aws iam list-entities-for-policy --policy-arn "$POLICY_ARN" \
    --query 'PolicyRoles[].RoleName' --output text 2>/dev/null || echo "")
  for role in $ATTACHED_ROLES; do
    warn "  - Detaching from role $role"
    aws iam detach-role-policy --role-name "$role" --policy-arn "$POLICY_ARN" 2>/dev/null || true
  done
  if aws iam delete-policy --policy-arn "$POLICY_ARN" 2>/dev/null; then
    ok "IAM policy deleted."
  else
    warn "Could not delete the policy (may have multiple versions — check manually)."
  fi
else
  ok "IAM policy no longer exists."
fi

# =============================================================================
# Step 4: Final validation — look for residual resources
# =============================================================================
log "Checking for residual resources..."

# NLBs with the cluster's tag
ORPHAN_LBS=$(aws elbv2 describe-load-balancers --region "$REGION" \
  --query "LoadBalancers[?contains(LoadBalancerName, '$CLUSTER_NAME')].LoadBalancerArn" \
  --output text 2>/dev/null || echo "")
if [ -n "$ORPHAN_LBS" ]; then
  warn "Found residual NLBs:"
  echo "$ORPHAN_LBS"
  warn "Delete them manually with: aws elbv2 delete-load-balancer --load-balancer-arn <ARN>"
else
  ok "No residual NLBs."
fi

# CloudFormation stacks
ORPHAN_STACKS=$(aws cloudformation describe-stacks --region "$REGION" \
  --query "Stacks[?contains(StackName, 'eksctl-${CLUSTER_NAME}')].StackName" \
  --output text 2>/dev/null || echo "")
if [ -n "$ORPHAN_STACKS" ]; then
  warn "Found residual CloudFormation stacks:"
  echo "$ORPHAN_STACKS"
  warn "Check the console and delete manually if needed."
else
  ok "No residual CloudFormation stacks."
fi

echo
ok "Teardown complete."
log "If you care about cost, also check:"
log "  - aws ec2 describe-volumes --region $REGION (orphan EBS)"
log "  - aws ec2 describe-network-interfaces --region $REGION (orphan ENIs)"
