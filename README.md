**English** | [Español](README.es.md)

# Migrating from NGINX Ingress Controller to Gateway API on EKS

> Practical guide and production-ready manifests to migrate a Kubernetes microservices architecture from the classic **NGINX Ingress Controller** to **NGINX Gateway Fabric** (Gateway API) — with a validated **zero-downtime** plan.

## Why this repo?

In **March 2026**, the upstream `ingress-nginx` project (the controller most teams have in production) was marked as **deprecated** by the Kubernetes community, with a definitive retirement date. The natural successor is the **Gateway API**, now GA, which separates infrastructure and application responsibilities, supports advanced routing natively, and eliminates the dependency on vendor-specific annotations.

This repository gives you:

1. **A working microservices architecture** (Google's Online Boutique) deployed on an EKS cluster, initially exposed via NGINX Ingress Controller.
2. **A step-by-step migration plan** toward NGINX Gateway Fabric using Gateway API, with a **coexistence** strategy to achieve zero-downtime.
3. **Complete manifests** for both states (Ingress and Gateway), `HTTPRoute`s equivalent to each `Ingress`, and validation scripts.
4. **A rollback runbook** because no production change is complete without one.

## Who is it for?

**DevOps / SRE / Platform Engineering** teams who:
- Operate one or more Kubernetes clusters (this repo uses EKS but applies to any distribution).
- Already use `ingress-nginx` and need a path out before end-of-life.
- Want to understand Gateway API with a realistic example, not a `hello-world`.

## Architecture

The demo application is Google's **Online Boutique**: 10 microservices in different languages (Go, Python, Node.js, C#, Java) simulating an e-commerce site. All external API traffic enters through a single point:

```
                 ┌────────────────────────────────────────┐
                 │           AWS NLB (public)             │
                 └────────────────────┬───────────────────┘
                                      │
            ┌─────────────────────────┴──────────────────────────┐
            │                                                    │
   INITIAL STATE                                          FINAL STATE
            │                                                    │
            ▼                                                    ▼
  ┌──────────────────┐                              ┌──────────────────────┐
  │ ingress-nginx    │                              │ NGINX Gateway Fabric │
  │ Controller       │                              │ (Gateway API)        │
  │ + Ingress objs   │                              │ + HTTPRoutes         │
  └────────┬─────────┘                              └──────────┬───────────┘
           │                                                   │
           ▼                                                   ▼
   ┌───────────────┐                                  ┌───────────────┐
   │ frontend Svc  │                                  │ frontend Svc  │
   └───────┬───────┘                                  └───────┬───────┘
           │                                                  │
   ┌───────┴────────────┐                          ┌──────────┴─────────┐
   │ 9 microservices    │  ← identical in both →   │ 9 microservices    │
   │ (cart, checkout,   │                          │ (cart, checkout,   │
   │  payment, etc.)    │                          │  payment, etc.)    │
   └────────────────────┘                          └────────────────────┘
```

During the migration, **both controllers run in parallel** with separate LoadBalancers. The switch happens at the DNS level, which allows fast rollback and real zero-downtime.

## Repo structure

```
.
├── README.md                          ← you are here (English by default)
├── README.es.md                       ← Spanish version
├── docs/                              ← English by default; `.es.md` versions for Spanish
│   ├── 01-prerequisites.md            ← what you need before starting
│   ├── 02-architecture.md             ← design decisions and why
│   ├── 03-ingress-vs-gateway.md       ← conceptual comparison and 1:1 mapping
│   ├── 04-migration-runbook.md        ← the step-by-step runbook ← START HERE
│   ├── 05-zero-downtime.md            ← analysis and strategy
│   ├── 06-rollback.md                 ← reversal plan
│   ├── 07-troubleshooting.md          ← common issues
│   ├── 08-faq.md
│   └── 09-fast-validation-runbook.md  ← fast validation on ephemeral EKS (~45 min)
├── manifests/
│   ├── 00-base/                       ← namespaces, shared resources
│   ├── 01-microservices/              ← Online Boutique (Deployments + Services)
│   ├── 02-ingress-nginx/              ← initial state: controller + Ingress
│   ├── 03-gateway-api/                ← final state: GatewayClass + Gateway + HTTPRoutes
│   └── 04-migration/                  ← coexistence and validation resources
├── scripts/
│   ├── setup-eks-demo-cluster.sh      ← creates ephemeral EKS for the fast validation
│   ├── teardown-eks-demo-cluster.sh   ← destroys the ephemeral EKS (with --confirm)
│   ├── install-ingress-nginx.sh
│   ├── install-nginx-gateway-fabric.sh
│   ├── validate-traffic.sh            ← smoke tests during the migration
│   ├── compare-responses.sh           ← diff between Ingress and Gateway
│   └── rollback.sh
└── .github/workflows/
    └── validate-manifests.yml         ← lint and dry-run in CI
```

## Quick start (impatient mode)

If you just want to see this running in your test cluster:

```bash
# 1. Deploy the microservices
kubectl apply -f manifests/00-base/
kubectl apply -f manifests/01-microservices/

# 2. Initial state with Ingress
./scripts/install-ingress-nginx.sh
kubectl apply -f manifests/02-ingress-nginx/

# 3. Verify it works
./scripts/validate-traffic.sh ingress

# 4. Install Gateway API CRDs and NGINX Gateway Fabric
./scripts/install-nginx-gateway-fabric.sh
kubectl apply -f manifests/03-gateway-api/

# 5. Verify BOTH endpoints work in parallel
./scripts/validate-traffic.sh both

# 6. When ready, cut traffic via DNS (see runbook)
# 7. Clean up the Ingress
kubectl delete -f manifests/02-ingress-nginx/
```

## Quick start (responsible mode)

Read, in order:

1. **`docs/01-prerequisites.md`** — confirm your environment meets the requirements.
2. **`docs/03-ingress-vs-gateway.md`** — understand what changes conceptually.
3. **`docs/04-migration-runbook.md`** — the executable runbook, with checkpoints and success criteria at each phase.
4. **`docs/05-zero-downtime.md`** — understand the real risks and how to mitigate them before touching production.

## Is zero-downtime really possible?

Yes, **with the following assumptions met**:

- Your application tolerates the same request potentially arriving via two different data planes during the change window (i.e., does not assume sticky sessions at the Ingress level — and if it does, there's a documented pattern to solve it).
- You control the public DNS pointing to the service.
- Your DNS TTLs are reasonable (≤300s ideal, 60s better).
- You don't have critical long-lived connections (websockets, long gRPC streams) without automatic client reconnection.

If any of these isn't met, **`docs/05-zero-downtime.md`** documents the workarounds and the cost of each one. The base strategy is the following:

| Phase | Time | Traffic via Ingress | Traffic via Gateway |
|-------|------|---------------------|---------------------|
| 1. Preparation | T-0 | 100% | 0% (doesn't exist) |
| 2. Parallel deployment | T+1d | 100% | 0% (exists but no DNS) |
| 3. Internal validation | T+2d | 100% | 0% (tested with `Host:` header) |
| 4. Weighted DNS — canary | T+3d | 90% → 50% | 10% → 50% |
| 5. Cutover | T+4d | 0% (draining) | 100% |
| 6. Decommission | T+5d | removed | 100% |

## Versions and compatibility

Tested and documented against:

| Component | Version |
|-----------|---------|
| Kubernetes (EKS) | 1.33, 1.34, 1.35 (1.32 already in extended support) |
| ingress-nginx | v1.11.x (last before EOL) |
| Gateway API CRDs | v1.5.1 |
| NGINX Gateway Fabric | 2.6.x |
| Online Boutique | v0.10.x |
| AWS Load Balancer Controller | v2.8.x |

Earlier NGF versions (1.x) use a different installation scheme. If you're on 1.x, see `docs/07-troubleshooting.md` for the upgrade path.

## License

MIT. Use it, adapt it, break it, improve it. PRs welcome.

## Credits

- [Google Cloud Platform — Online Boutique](https://github.com/GoogleCloudPlatform/microservices-demo) — demo application.
- [NGINX Gateway Fabric](https://github.com/nginx/nginx-gateway-fabric) — Gateway API implementation we use as target.
- The Kubernetes Gateway API community for the spec work.
