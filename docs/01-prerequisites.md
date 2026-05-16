**English** | [Español](01-prerequisites.es.md)

# 01 — Prerequisites

Before starting the migration, validate that your environment meets the following. If something fails, **stop and fix it** — trying to migrate with incomplete prerequisites is the #1 cause of production issues.

## 1. Kubernetes cluster

### Minimum version

- **Kubernetes 1.25+** (NGINX Gateway Fabric 2.x requires 1.25 as minimum).
- Recommended: **1.30+** to have Gateway API v1.5 without patches.

Verify:

```bash
kubectl version --short
```

### Permissions

You need `cluster-admin` to:
- Install Gateway API CRDs.
- Create `GatewayClass` (cluster-scoped).
- Create the controller's namespace and RBAC.

For day-to-day operations (creating `Gateway`, `HTTPRoute`), namespace-level permissions are enough.

## 2. EKS-specific

### IAM and networking

- **AWS Load Balancer Controller** installed and working. Without it, `Service` of type `LoadBalancer` won't provision NLBs correctly.
  ```bash
  kubectl -n kube-system get deploy aws-load-balancer-controller
  ```
- **VPC with subnets tagged** correctly:
  - Public subnets: `kubernetes.io/role/elb: 1`
  - Private subnets: `kubernetes.io/role/internal-elb: 1`
- **Security Groups** that allow traffic from the NLB to the nodes (at least ports 80/443).

### Quotas

NGINX Gateway Fabric creates **one additional NLB** during the migration. Verify that your account has quota for at least one extra NLB in the region:

```bash
aws service-quotas get-service-quota \
  --service-code elasticloadbalancing \
  --quota-code L-69A177A2 \
  --region <your-region>
```

## 3. Local tools

```bash
# Tested versions
kubectl version --client     # >= 1.30
helm version                  # >= 3.14
aws --version                 # >= 2.15
jq --version                  # >= 1.6
```

Optional but recommended:
- `kubectx` / `kubens` — so you don't switch to the wrong cluster at the wrong moment.
- `stern` — for multi-pod log tailing during validation.
- `k9s` — terminal UI for fast inspection.

## 4. DNS

You need control over the domain pointing to the API. Supported scenarios:

### Scenario A — Route 53 (recommended)

- Hosted zone in Route 53.
- IAM permissions to create/modify records.
- You'll enable **weighted routing** for the canary.

### Scenario B — External DNS (Cloudflare, NS1, etc.)

- Works the same, but you'll need an equivalent weighted/percentage routing mechanism.
- If your DNS doesn't support weighted routing, there's a fallback with two distinct hostnames documented in `05-zero-downtime.md`.

### Scenario C — Automated ExternalDNS

If you use `external-dns` with annotations on `Ingress`, beware: you'll have to **temporarily disable it** or configure `external-dns` to also manage `Gateway` resources (supported since v0.14).

## 5. Observability

**Don't migrate without working observability.** Minimum required:

- **Metrics from the current Ingress** (latency, error rate, RPS) — to have a baseline.
- **Accessible logs** from the ingress-nginx-controller — to diagnose if anything drifts.
- **Active alerts** on the public endpoint — to detect degradation during the cutover.

If you use Prometheus, typical `ingress-nginx` dashboards you need working:
- Request rate per host/path
- p50/p95/p99 latency
- 4xx/5xx rate
- Upstream response time

You'll have to replicate these for NGINX Gateway Fabric **before** the cutover — metric names change. See `07-troubleshooting.md` section "Observability".

## 6. Application

Application-specific validations for the app you're migrating (not the demo, the real one):

- [ ] Does it use `ingress-nginx` annotations? List which. Some have a direct equivalent in Gateway API, others require `NginxProxy` or NGF custom policies. See `03-ingress-vs-gateway.md` mapping table.
- [ ] Does it use path rewrites? Gateway API supports them natively via `URLRewrite` filter — different from the `nginx.ingress.kubernetes.io/rewrite-target` annotation.
- [ ] Does it use Ingress-level auth (`auth-url`, `auth-snippet`)? This requires custom policies or a sidecar — plan ahead.
- [ ] Does it have websockets or gRPC streaming? Supported, but requires special consideration in the cutover.
- [ ] Does it terminate TLS at the Ingress? Note where the `Secret`s with certificates live; you'll reference them from the `Gateway`.
- [ ] Does it use client-cert / mTLS? Supported in NGF 2.6+ via `FrontendTLS`, but the syntax differs.

## 7. Maintenance window

Even though the plan is zero-downtime, **plan a window** anyway:
- Minimum 2 hours for the cutover.
- Ideally outside peak traffic.
- With at least two people: one executes, the other watches metrics and has rollback ready.

## Final checklist

Before continuing to the next document, check everything:

- [ ] Kubernetes cluster 1.25+ accessible with `cluster-admin`.
- [ ] AWS Load Balancer Controller working.
- [ ] AWS quota for 1 additional NLB.
- [ ] Local tools installed (kubectl, helm, aws, jq).
- [ ] Control over public endpoint DNS.
- [ ] Observability: metrics, logs, alerts working against the current Ingress.
- [ ] Complete inventory of annotations and special features of the current Ingress.
- [ ] Maintenance window scheduled (even if we hope not to use it).
- [ ] Rollback plan reviewed by at least one other team member.

✅ If everything is checked → continue to [`02-architecture.md`](./02-architecture.md).
