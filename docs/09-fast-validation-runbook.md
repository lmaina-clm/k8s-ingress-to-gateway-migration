**English** | [Español](09-fast-validation-runbook.es.md)

# 09 — Fast validation runbook (demo mode, no real domain)

This runbook validates the complete **ingress-nginx → NGINX Gateway Fabric** migration on an ephemeral EKS cluster, in ~45 min of active work, without needing a real domain.

> **It is NOT** a substitute for the production runbook ([04-migration-runbook.md](./04-migration-runbook.md)). It's the "smoke test" version to see the pattern working end-to-end before applying it to a real cluster.

## Differences vs. the production runbook

| Aspect | Production | Demo (this runbook) |
|--------|------------|---------------------|
| Cluster | Existing EKS | Newly created ephemeral EKS |
| Domain | Real, with public DNS | `shop.example.com` resolved via `curl --resolve` |
| TLS | Real cert (cert-manager or ACM) | Self-signed generated on the fly |
| Canary DNS | Route 53 weighted, 30 min – 4h waits between phases | Skipped — we validate both NLBs in parallel with `curl` |
| Traffic | Real user traffic | Internal `loadgenerator` + manual curls |
| Observation | Grafana dashboards, alerts | `kubectl get` + logs |
| Total duration | 3-5 days | ~45 min active |
| Cost | N/A (existing cluster) | ~$0.50-2 USD (1-3h of cluster in eu-west-1) |

## Prerequisites

On your local machine:
- `aws` CLI v2, authenticated (`aws sts get-caller-identity` must work)
- `eksctl` ≥ 0.190 ([installation](https://eksctl.io/installation/))
- `kubectl` ≥ 1.30
- `helm` ≥ 3.14
- `jq`, `curl`, `openssl`, `dig` (standard on macOS/Linux)

Required AWS permissions (summary): `eks:*`, `iam:*` (limited to IRSA roles/policies), `ec2:*` (VPC/subnets/SG), `elasticloadbalancing:*`, `cloudformation:*`. If you have `AdministratorAccess`, it covers everything.

---

## Phase 0 — Preflight (~1 min, free)

```bash
# Verify credentials and region
export REGION=eu-west-1
export CLUSTER_NAME=ingress-gw-demo

aws sts get-caller-identity
aws ec2 describe-availability-zones --region $REGION --query 'AvailabilityZones[].ZoneName'
```

**Success criteria**: you see your account ID and at least 3 AZs.

---

## Phase 1 — Create the EKS cluster (~15 min, cost starts)

```bash
./scripts/setup-eks-demo-cluster.sh
```

This creates:
- EKS cluster 1.35 with OIDC enabled
- 2 t3.medium nodes in a managed nodegroup
- AWS Load Balancer Controller with IRSA

**Approximate cost**: $0.10/h control plane + $0.09/h nodes (2× t3.medium in eu-west-1) ≈ $0.19/h.

**Success criteria**:
```bash
kubectl get nodes
# 2 nodes Ready
kubectl -n kube-system get deploy aws-load-balancer-controller
# AVAILABLE 1/1 (or 2/2 depending on replicas)
```

---

## Phase 2 — Deploy Online Boutique (~3 min)

> Note: we only apply `namespaces.yaml` here. The `reference-grant.yaml` is
> applied later, in Phase 6, because it requires the Gateway API CRDs which
> are not installed yet.

```bash
kubectl apply -f manifests/00-base/namespaces.yaml
kubectl apply -k manifests/01-microservices/

# Wait for everything to be Ready
kubectl -n microservices wait --for=condition=Ready pod --all --timeout=300s
```

**Success criteria**: all pods in `Running` and `1/1 Ready`. Takes 3-5 min due to inter-service dependencies.

```bash
kubectl -n microservices get pods
```

---

## Phase 3 — Generate self-signed cert and create the Secret

Since we don't have a real domain, we generate a self-signed cert for `shop.example.com` and place it as a Secret in the two namespaces that need it.

```bash
# Generate cert+key pair
openssl req -x509 -newkey rsa:2048 -nodes -days 1 \
  -keyout /tmp/shop.key \
  -out /tmp/shop.crt \
  -subj "/CN=shop.example.com" \
  -addext "subjectAltName=DNS:shop.example.com"

# Create Secret in the app namespace (used by the Ingress)
kubectl -n microservices create secret tls shop-tls \
  --cert=/tmp/shop.crt --key=/tmp/shop.key

# Create the gateway-system namespace first if it doesn't exist
kubectl get ns gateway-system >/dev/null 2>&1 || kubectl create ns gateway-system

# Copy the Secret to gateway-system (used by the Gateway)
kubectl -n microservices get secret shop-tls -o yaml \
  | sed 's/namespace: microservices/namespace: gateway-system/' \
  | kubectl apply -f -

# Clean up temporary files
rm -f /tmp/shop.key /tmp/shop.crt
```

**Success criteria**:
```bash
kubectl get secret shop-tls -n microservices
kubectl get secret shop-tls -n gateway-system
# Both must exist
```

---

## Phase 4 — Initial state: install ingress-nginx + apply Ingress (~5 min)

```bash
SKIP_CONFIRM=1 ./scripts/install-ingress-nginx.sh

# Apply the Ingress
kubectl apply -f manifests/02-ingress-nginx/

# Get the Ingress NLB (can take 1-2 min to appear)
until [ -n "$(kubectl -n ingress-nginx get svc ingress-nginx-controller \
                -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null)" ]; do
  echo "Waiting for Ingress NLB..."; sleep 10
done

export INGRESS_NLB=$(kubectl -n ingress-nginx get svc ingress-nginx-controller \
  -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')
echo "INGRESS_NLB=$INGRESS_NLB"
```

**Success criteria**:
```bash
kubectl get ingress -n microservices
# Must show the Ingress with HOSTS=shop.example.com
```

---

## Phase 5 — Validate traffic against the Ingress (~2 min)

```bash
./scripts/validate-traffic.sh ingress
```

**Success criteria**: all paths return `200` or `301/302` (HTTP → HTTPS redirects are expected).

> If you see `301` on some paths, perfect — it means `force-ssl-redirect` is working. The validation is following the correct flow.

---

## Phase 6 — Install Gateway API + NGF (~3 min)

```bash
SKIP_CONFIRM=1 ./scripts/install-nginx-gateway-fabric.sh

# Now that the CRDs exist, apply the ReferenceGrant we left pending
# in Phase 2 (authorizes HTTPRoutes in `microservices` to reference the Gateway
# in `gateway-system`).
kubectl apply -f manifests/00-base/reference-grant.yaml
```

**Success criteria**:
```bash
kubectl get crd | grep gateway.networking.k8s.io
# Must show 5+ CRDs

kubectl get gatewayclass nginx-gateway
# ACCEPTED=True

kubectl get referencegrant -n gateway-system
# allow-microservices-to-use-gateway must exist
```

---

## Phase 7 — Apply Gateway + HTTPRoutes (~3 min)

```bash
kubectl apply -f manifests/03-gateway-api/

# Wait for the Gateway to be Programmed (NGF creates the NLB)
kubectl wait --for=condition=Programmed gateway/boutique-gateway \
  -n gateway-system --timeout=300s

# Get the Gateway NLB
export GATEWAY_NLB=$(kubectl -n gateway-system get svc \
  -l gateway.networking.k8s.io/gateway-name=boutique-gateway \
  -o jsonpath='{.items[0].status.loadBalancer.ingress[0].hostname}')
echo "GATEWAY_NLB=$GATEWAY_NLB"
```

**Success criteria**:
```bash
kubectl get gateway -n gateway-system
# PROGRAMMED=True

kubectl get httproute -n microservices
# ACCEPTED=True for both HTTPRoutes
```

---

## Phase 8 — Validate traffic against the Gateway (~2 min)

```bash
./scripts/validate-traffic.sh gateway
```

**Success criteria**: same behavior as with the Ingress — `200` or `301/302` on all paths.

---

## Phase 9 — Compare both endpoints in parallel (~2 min)

This is the key phase: both NLBs must serve the same thing.

```bash
./scripts/validate-traffic.sh both

# If you have scripts/compare-responses.sh (review the code before running):
./scripts/compare-responses.sh
```

**Success criteria**:
- Same status codes on both NLBs
- Latencies in the same order of magnitude
- Differences only on volatile headers (`Date`, `X-Request-Id`)

---

## Phase 10 — Cutover simulation without DNS (~2 min)

In production we'd change Route 53 here. In the demo we simply "declare" that the Gateway is active and delete the Ingress:

```bash
# Delete the Ingress (the Gateway keeps serving)
kubectl delete -f manifests/02-ingress-nginx/ingress.yaml

# Validate that the Gateway keeps working
./scripts/validate-traffic.sh gateway

# Verify the Ingress is gone
kubectl get ingress -n microservices
# No resources found
```

**Success criteria**: the Gateway keeps responding with `200`/`301`, and `kubectl get ingress` returns nothing.

---

## Phase 11 — Uninstall ingress-nginx (~2 min)

```bash
helm uninstall ingress-nginx -n ingress-nginx
kubectl delete namespace ingress-nginx

# The Ingress NLB is destroyed automatically
# Validate the Gateway keeps working
./scripts/validate-traffic.sh gateway
```

**Success criteria**: only 1 NLB remains in AWS (the Gateway's). The service is still 100% functional.

```bash
aws elbv2 describe-load-balancers --region $REGION \
  --query 'LoadBalancers[].LoadBalancerName' --output table
# Must show 1 NLB (or none if NGF hasn't provisioned yet)
```

---

## Phase 12 — Teardown (~10 min, stops the cost)

```bash
./scripts/teardown-eks-demo-cluster.sh --confirm
```

This deletes:
1. Cluster LoadBalancer Services (= destroys the NLBs in AWS)
2. The EKS cluster and its entire VPC
3. LB Controller IAM policy

**Success criteria**: the script ends with "Teardown complete" and reports no residual resources.

> If the script reports "residual NLBs" or "residual CloudFormation stacks", delete them manually — they're rare but can remain if a LoadBalancer Service was created outside your visibility.

---

## Complete checklist

- [ ] **Phase 0**: preflight OK
- [ ] **Phase 1**: cluster created, AWS LB Controller running
- [ ] **Phase 2**: Online Boutique deployed, all pods Ready
- [ ] **Phase 3**: Secret `shop-tls` created in `microservices` and `gateway-system`
- [ ] **Phase 4**: ingress-nginx installed, Ingress applied, NLB assigned
- [ ] **Phase 5**: validate-traffic.sh ingress passes
- [ ] **Phase 6**: Gateway API CRDs + NGF installed
- [ ] **Phase 7**: Gateway Programmed=True, HTTPRoutes Accepted=True, second NLB assigned
- [ ] **Phase 8**: validate-traffic.sh gateway passes
- [ ] **Phase 9**: both NLBs serve equivalent responses
- [ ] **Phase 10**: Ingress deleted, Gateway still serving
- [ ] **Phase 11**: ingress-nginx uninstalled, old NLB destroyed
- [ ] **Phase 12**: teardown complete, no residual resources

---

## Quick troubleshooting

| Symptom | Typical cause | Solution |
|---------|---------------|----------|
| NLB doesn't appear after 5 min | AWS LB Controller not running or without permissions | `kubectl logs -n kube-system deploy/aws-load-balancer-controller` |
| Online Boutique pods in `Pending` | Insufficient resources on 2 t3.medium | Increase to 3 nodes: `eksctl scale nodegroup ...` |
| `Gateway` stuck in `Programmed=False` | `shop-tls` Secret doesn't exist in `gateway-system` | Re-apply Phase 3 |
| `curl` returns `SSL: no alternative certificate subject name matches` | You used `-k` wrong or the cert was made for another CN | `--resolve` must use `shop.example.com:443:<IP>`, not the NLB hostname |
| Teardown fails with "DependencyViolation" | NLBs weren't deleted before the VPC | Manually delete the NLBs in the console and retry |

---

## What we DON'T validate in this fast mode

Be honest about the gaps vs. a real migration:

- **DNS behavior under load and TTL** — the canary phase of the production runbook isn't exercised here. Propagation times and behavior of clients with DNS cache aren't observed.
- **Semantic differences with real traffic** — `loadgenerator` covers the main flow, but not edge cases of your real application.
- **Performance under sustained load** — the test is minutes, not hours. Memory leaks or slow degradation wouldn't be detected.
- **Rollback under pressure** — the rollback script works, but the human component of "what does on-call do at 3am" isn't tested.

To validate all that, **you need a staging environment with realistic traffic**, not this mode.

---

## Expected total cost

In eu-west-1, for a 2-3 hour session:

| Resource | Cost/hour | Total time | Subtotal |
|----------|-----------|------------|----------|
| EKS control plane | $0.10 | 2-3h | $0.20-0.30 |
| 2× t3.medium nodes | $0.091 | 2-3h | $0.18-0.27 |
| 1-2 NLBs | $0.025-0.050 | 2h average | $0.05-0.10 |
| EBS gp3 (2× 30GB) | ~$0.005 | 2-3h | $0.02 |
| Misc (CloudWatch, ENI) | ~$0.01 | 2-3h | $0.05 |
| **TOTAL** | | | **$0.50-0.75** |

Cost at 4h: ~$1. At 8h: ~$2. Golden rule: **run the teardown as soon as you finish**.
