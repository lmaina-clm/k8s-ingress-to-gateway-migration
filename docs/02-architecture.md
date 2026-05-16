**English** | [Español](02-architecture.es.md)

# 02 — Architecture and design decisions

This document explains **the why** behind the technical decisions. If you just want to execute the migration, skip to `04-migration-runbook.md`.

## The application: Online Boutique

[Online Boutique](https://github.com/GoogleCloudPlatform/microservices-demo) is an e-commerce app with 11 microservices. We picked it because:

- **It's realistic**: multiple languages (Go, Python, Node.js, C#, Java), gRPC communication between services, async dependencies.
- **It's actively maintained** by Google.
- **It has a single external entry point** (`frontend`), but with rich internal communication that exercises cluster networking.
- **It's not trivial**: it teaches you to handle more than a `hello-world`.

### Topology

```
                          External Traffic (HTTPS)
                                    │
                                    ▼
                        ┌─────────────────────┐
                        │ Ingress / Gateway   │ ← What we're going to migrate
                        └──────────┬──────────┘
                                   │
                                   ▼
                        ┌─────────────────────┐
                        │     frontend        │ (Go, HTTP)
                        └──────────┬──────────┘
                                   │ internal gRPC
        ┌──────────────┬───────────┼────────────┬──────────────┐
        ▼              ▼           ▼            ▼              ▼
   ┌─────────┐   ┌──────────┐ ┌─────────┐ ┌──────────┐  ┌───────────┐
   │ product │   │   cart   │ │ checkout│ │ shipping │  │ currency  │
   │ catalog │   │          │ │         │ │          │  │           │
   │  (Go)   │   │  (C#)    │ │  (Go)   │ │  (Go)    │  │ (Node.js) │
   └─────────┘   └─────┬────┘ └────┬────┘ └──────────┘  └───────────┘
                       │           │
                       ▼           ▼
                 ┌──────────┐ ┌──────────┐
                 │  redis   │ │ payment  │
                 │ (data)   │ │  (Node)  │
                 └──────────┘ └──────────┘
                                   │
                              ┌────┴────┐
                              ▼         ▼
                         ┌──────┐  ┌─────────┐
                         │email │  │   ads   │
                         │(Py)  │  │  (Java) │
                         └──────┘  └─────────┘
```

**What matters for this migration**: only `frontend` is exposed externally. All the rest are `ClusterIP`. The migration only touches the edge — internal traffic (gRPC between services) doesn't change.

This is **representative of 80% of microservices architectures in production**: a BFF/app-gateway as the only exposed service, the rest internal. If your case is different (multiple services exposed directly), the pattern scales — just add more `HTTPRoute`s.

## Decision 1: Why NGINX Gateway Fabric and not another implementation?

| Implementation | Pros | Cons |
|----------------|------|------|
| **NGINX Gateway Fabric** | Same family as `ingress-nginx`, smaller conceptual transition. NGINX as dataplane (what we already know). Maintained by F5/NGINX. Commercial support available. | Younger than Istio. Some advanced features (ratelimit, session persistence) are recent. |
| **Istio** | Mature, huge ecosystem, service mesh + gateway in one. | Much more complex. If you only need ingress, it's over-engineering. |
| **Envoy Gateway** | Envoy is the de facto standard in service mesh. Excellent performance. | Learning curve. If you've never used Envoy, you add complexity. |
| **Cilium Gateway API** | If you already use Cilium as CNI, natural integration. eBPF dataplane. | Requires Cilium as CNI; doesn't apply if you use another. |
| **AWS Gateway API Controller** | Native integration with AWS VPC Lattice. | AWS lock-in, different cost model. |

**For a team coming from `ingress-nginx`, NGF is minimum friction**: same company, same dataplane, same NGINX mental models (workers, upstreams, etc.). Annotations change, but underlying behavior is predictable.

## Decision 2: Coexistence strategy (the key to zero-downtime)

Three possible approaches:

### A) Big-bang: delete Ingress and apply Gateway

❌ **No.** Implies guaranteed downtime while the new controller initializes and the NLB is reprovisioned. Impossible to do zero-downtime.

### B) In-place: same controller serves Ingress and Gateway

❌ **Doesn't work with NGF.** NGF only understands Gateway API. `ingress-nginx` only understands Ingress. They are different binaries.

### C) Coexistence with two controllers in parallel ← **what we do**

✅ Both controllers run at the same time, with separate LoadBalancers. `Ingress` are served by one, `HTTPRoute` by the other. The cutover happens **outside the cluster**, at the DNS level.

```
         dns.example.com
                │
                ├─ (during coexistence) → Route 53 weighted records
                │       ├─ 90% → NLB-A (ingress-nginx)
                │       └─ 10% → NLB-B (nginx-gateway-fabric)
                │
                └─ (post-cutover) → 100% → NLB-B
```

Advantages:
- **Immediate rollback** by reverting DNS (limited by TTL).
- **Controlled canary traffic** from the start.
- **Both systems observable** simultaneously to compare.

Disadvantage:
- Cost of one extra NLB during the migration window (~$20/month in us-east-1, prorated to days).
- More operational complexity for 1-2 weeks.

The cost is trivial compared to a downtime incident.

## Decision 3: Namespace model

NGF creates the data-plane (NGINX pods) dynamically when you create a `Gateway`. By default, it creates them in the **same namespace as the `Gateway`**. Recommendation:

- **`nginx-gateway`** — NGF control-plane namespace (created by Helm).
- **`gateway-system`** — namespace where the `Gateway` resource and its associated data-plane live.
- **`microservices`** — application namespace, where the `HTTPRoute`s live (with cross-namespace `ParentRefs` to the Gateway).

This separates responsibilities:
- Platform team controls `gateway-system`.
- Application team controls their `HTTPRoute`s in `microservices`.

Cross-namespace access is granted via `ReferenceGrant` — Gateway API requires explicit consent.

## Decision 4: What do we do with TLS?

Three options to terminate TLS:

| Option | Where TLS terminates | When to use it |
|--------|----------------------|----------------|
| Pass-through to the pod | At the pod (TCP route) | When you need end-to-end mTLS. |
| **Terminate at the Gateway** (recommended default) | At NGF | General case; certificates in K8s `Secret`s or cert-manager. |
| Terminate at the NLB | In AWS, via ACM | If you want ACM and AWS WAF integration. |

This repo assumes **termination at the Gateway** because it's the most portable option and replicates what `ingress-nginx` normally did. If you terminate at the NLB with ACM, the manifests are slightly different — see the "TLS at the NLB" section in `07-troubleshooting.md`.

## Decision 5: How we map Ingress → HTTPRoute

Online Boutique has a single Ingress that routes everything to `frontend`. That makes it a simple case, but we document the general mapping:

| Ingress concept | Gateway API equivalent |
|-----------------|------------------------|
| `kind: Ingress` | `kind: HTTPRoute` |
| `spec.ingressClassName: nginx` | `spec.parentRefs[].name` (points to `Gateway`) |
| `spec.tls[]` (cert) | Configured in `Gateway.spec.listeners[].tls` |
| `spec.rules[].host` | `HTTPRoute.spec.hostnames[]` |
| `spec.rules[].http.paths[]` | `HTTPRoute.spec.rules[].matches[]` |
| `path.backend.service` | `rules[].backendRefs[]` |
| `rewrite-target` annotation | `URLRewrite` filter |
| `force-ssl-redirect` annotation | HTTP listener with `HTTPRoute` doing redirect |
| `proxy-body-size` annotation | `NginxProxy` resource (NGF-specific) |
| `auth-url` annotation | No direct equivalent; use `ExtensionRef` |

The complete table with all `ingress-nginx` annotations is in `03-ingress-vs-gateway.md`.

## What we DON'T cover in this migration (deliberately)

- **Internal service mesh** — If you want mTLS between microservices, that's a separate project. NGF can be your ingress without touching the internal traffic.
- **Advanced L7 API Gateway features** (per-user rate limiting, JWT validation with introspection). Some are in NGF 2.4+, others need a dedicated API Gateway (Kong, Apigee) behind the K8s Gateway.
- **Multi-cluster routing** — Possible with Gateway API + Submariner/Linkerd multi-cluster, but out of scope.

---

Next: [`03-ingress-vs-gateway.md`](./03-ingress-vs-gateway.md) — the complete conceptual mapping between the two worlds.
