#!/usr/bin/env bash
# =============================================================================
# teardown-eks-demo-cluster.sh
# =============================================================================
# Destruye el cluster creado por setup-eks-demo-cluster.sh, incluyendo:
#   - Services tipo LoadBalancer (para que AWS borre los NLBs antes que la VPC)
#   - IRSA service account
#   - IAM policy del LB Controller
#   - El cluster EKS (esto borra VPC, subnets, NAT GW, etc.)
#
# Idempotente: si algo no existe, lo salta sin error.
#
# Uso:
#   ./scripts/teardown-eks-demo-cluster.sh --confirm
#
# Sin --confirm el script muestra qué borraría y no toca nada (dry-run).
#
# Variables de entorno opcionales:
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

command -v aws >/dev/null     || err "aws CLI no instalado"
command -v eksctl >/dev/null  || err "eksctl no instalado"
command -v kubectl >/dev/null || err "kubectl no instalado"

ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text 2>/dev/null) \
  || err "AWS credentials no funcionan."

log "Account:    $ACCOUNT_ID"
log "Cluster:    $CLUSTER_NAME"
log "Región:     $REGION"
echo

if ! eksctl get cluster --name "$CLUSTER_NAME" --region "$REGION" >/dev/null 2>&1; then
  warn "El cluster '$CLUSTER_NAME' no existe en $REGION. Nada que borrar a nivel EKS."
  CLUSTER_EXISTS=0
else
  CLUSTER_EXISTS=1
fi

if [ "$CONFIRM" != "1" ]; then
  warn "DRY RUN — agrega --confirm para borrar de verdad."
  log "Se eliminarían:"
  [ "$CLUSTER_EXISTS" = "1" ] && log "  - Cluster EKS: $CLUSTER_NAME"
  log "  - Todos los Services LoadBalancer del cluster (= NLBs en AWS)"
  log "  - IRSA service account: kube-system/aws-load-balancer-controller"
  log "  - IAM policy: AWSLoadBalancerControllerIAMPolicy-${CLUSTER_NAME}"
  exit 0
fi

# =============================================================================
# Paso 1: Borrar Services tipo LoadBalancer ANTES de borrar el cluster
# =============================================================================
# Si no hacemos esto, los NLBs quedan huérfanos y la VPC no se puede destruir
# (los ENIs de los NLBs bloquean la eliminación de subnets).
# =============================================================================
if [ "$CLUSTER_EXISTS" = "1" ]; then
  log "Configurando kubectl..."
  aws eks update-kubeconfig --name "$CLUSTER_NAME" --region "$REGION" >/dev/null 2>&1 || true

  if kubectl cluster-info >/dev/null 2>&1; then
    log "Borrando Services tipo LoadBalancer (para limpiar NLBs)..."
    LB_SVCS=$(kubectl get svc -A -o json | \
      jq -r '.items[] | select(.spec.type=="LoadBalancer") | "\(.metadata.namespace)/\(.metadata.name)"')

    if [ -n "$LB_SVCS" ]; then
      echo "$LB_SVCS" | while IFS='/' read -r ns name; do
        log "  - $ns/$name"
        kubectl delete svc "$name" -n "$ns" --wait=false --timeout=30s 2>/dev/null || true
      done

      # Esperar a que AWS realmente destruya los NLBs (sin esto, eksctl delete
      # cluster falla porque los ENIs siguen vivos)
      log "Esperando 90s a que AWS destruya los NLBs..."
      sleep 90
    else
      ok "No hay Services LoadBalancer que borrar."
    fi
  else
    warn "kubectl no puede conectar al cluster (puede estar ya degradado). Saltando borrado de Services."
  fi

  # =============================================================================
  # Paso 2: Borrar el cluster EKS vía eksctl
  # =============================================================================
  log "Borrando cluster EKS (esto tarda ~10 min)..."
  eksctl delete cluster --name "$CLUSTER_NAME" --region "$REGION" --wait \
    || warn "eksctl delete cluster reportó errores. Revisa CloudFormation en la consola."

  ok "Cluster eliminado (o intento completado)."
else
  log "Saltando borrado de cluster (no existe)."
fi

# =============================================================================
# Paso 3: Borrar IAM policy del LB Controller
# =============================================================================
POLICY_NAME="AWSLoadBalancerControllerIAMPolicy-${CLUSTER_NAME}"
POLICY_ARN="arn:aws:iam::${ACCOUNT_ID}:policy/${POLICY_NAME}"

if aws iam get-policy --policy-arn "$POLICY_ARN" >/dev/null 2>&1; then
  log "Borrando IAM policy $POLICY_NAME..."
  # Desligar de cualquier role residual antes de borrar
  ATTACHED_ROLES=$(aws iam list-entities-for-policy --policy-arn "$POLICY_ARN" \
    --query 'PolicyRoles[].RoleName' --output text 2>/dev/null || echo "")
  for role in $ATTACHED_ROLES; do
    warn "  - Desadjuntando de role $role"
    aws iam detach-role-policy --role-name "$role" --policy-arn "$POLICY_ARN" 2>/dev/null || true
  done
  if aws iam delete-policy --policy-arn "$POLICY_ARN" 2>/dev/null; then
    ok "IAM policy borrada."
  else
    warn "No se pudo borrar la policy (puede haber versiones múltiples — revisar manualmente)."
  fi
else
  ok "IAM policy ya no existe."
fi

# =============================================================================
# Paso 4: Validación final — buscar recursos residuales
# =============================================================================
log "Verificando recursos residuales..."

# NLBs con tag del cluster
ORPHAN_LBS=$(aws elbv2 describe-load-balancers --region "$REGION" \
  --query "LoadBalancers[?contains(LoadBalancerName, '$CLUSTER_NAME')].LoadBalancerArn" \
  --output text 2>/dev/null || echo "")
if [ -n "$ORPHAN_LBS" ]; then
  warn "Encontré NLBs residuales:"
  echo "$ORPHAN_LBS"
  warn "Bórralos manualmente con: aws elbv2 delete-load-balancer --load-balancer-arn <ARN>"
else
  ok "No hay NLBs residuales."
fi

# CloudFormation stacks
ORPHAN_STACKS=$(aws cloudformation describe-stacks --region "$REGION" \
  --query "Stacks[?contains(StackName, 'eksctl-${CLUSTER_NAME}')].StackName" \
  --output text 2>/dev/null || echo "")
if [ -n "$ORPHAN_STACKS" ]; then
  warn "Encontré stacks de CloudFormation residuales:"
  echo "$ORPHAN_STACKS"
  warn "Revisa la consola y borra manualmente si es necesario."
else
  ok "No hay stacks de CloudFormation residuales."
fi

echo
ok "Teardown completo."
log "Si el costo te importa, verifica también:"
log "  - aws ec2 describe-volumes --region $REGION (EBS huérfanos)"
log "  - aws ec2 describe-network-interfaces --region $REGION (ENIs huérfanos)"
