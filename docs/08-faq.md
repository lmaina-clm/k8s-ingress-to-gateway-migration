**English** | [Español](08-faq.es.md)

# 08 — FAQ

Questions the team will ask when you present the migration.

## Why do we have to migrate?

`ingress-nginx` (the Kubernetes community project, not NGINX Inc.) was **marked as deprecated in March 2025**. The community recommends Gateway API as the successor. Although it will keep working for a while, it won't receive new features and security fixes will be increasingly slow.

Postponing the migration is tech debt that grows.

## Can't we stay on `ingress-nginx` "forever"?

Technically yes, while it works. But:
- Unpatched CVEs eventually.
- Helm chart stops being maintained.
- Documentation becomes obsolete.
- When you have to migrate under pressure, it'll be worse.

## Is Gateway API stable?

Yes. The core APIs (Gateway, GatewayClass, HTTPRoute) have been **GA since v1.0** (October 2023). Currently we're at v1.5.1. Multiple implementations in production (Google, AWS, NGINX, Istio).

## Why NGINX Gateway Fabric and not Istio/Envoy/Cilium?

See `02-architecture.md`. Summary:
- **Existing knowledge**: your team already understands NGINX. NGF keeps the same dataplane and mental model.
- **Commercial support**: F5 sells support if you need it.
- **Simple**: does one thing (Gateway API) and does it well. If you need service mesh, that's a separate decision.

If your team already uses Istio as service mesh, **Istio also implements Gateway API** and may be a better option to unify. If you don't use mesh, NGF is the simple path.

## How long does the migration take?

Per service: **3-5 calendar days**, with ~5 hours of active work. Most of the time is observation window between canary phases.

Per team (multiple services): can be parallelized or sequenced. Recommendation: **migrate a non-critical service first** so the team learns, then the critical ones.

## Can we do it in a single night?

Technically yes (shorten the observation windows). **We don't recommend it**. Some problems are only seen with real traffic during the natural usage cycle (peak / off-peak). Cutting the canary creates more risk than it saves in time.

## Does this affect how devs deploy their services?

Yes, but the change is contained. What changes for devs:

| Before | After |
|--------|-------|
| `kind: Ingress` in their chart | `kind: HTTPRoute` in their chart |
| `ingressClassName: nginx` | `parentRefs: [...gateway...]` |
| Annotations for configuration | Filters or policies CRD-based |

The change in helm charts / kustomize is **cosmetic in the simple case**. Cases with many annotations require more work.

## Do we need to change our CI/CD?

Only what validates manifests:

- If you have `kubeval` / `kubeconform` validating schemas, add the Gateway API CRDs to your config.
- If you have templates (Helm/Kustomize) hardcoded for Ingress, you need to create new ones for HTTPRoute.
- The deploy pipelines themselves don't change: `kubectl apply` keeps working.

## What about cert-manager?

It works, with two considerations:
- **Minimum version 1.14** for native Gateway API support.
- The `Certificate` can live in the `Gateway`'s namespace, not the app's.

Alternatively you can keep using `Certificate` linked to an `Ingress` (legacy) until you migrate, then move to the Gateway.

## What about `external-dns`?

`external-dns` supports `Gateway` and `HTTPRoute` since **v0.14**. Before the migration, upgrade your `external-dns` and configure it:

```bash
helm upgrade external-dns ... --set sources={service,ingress,gateway-httproute,gateway-grpcroute}
```

During the migration, **disable external-dns for the hostname you're migrating** and manage DNS manually. Re-enable it once done.

## What if we use Cloudflare in front?

Works the same way. Cloudflare points to the NLB (Ingress or Gateway). During the migration, you change the Cloudflare record instead of Route 53. The canary strategy works if you configure two origin pools (one per NLB) with weights.

## What if we use a service mesh (Istio/Linkerd)?

Two options:
1. **The mesh handles ingress** (Istio Gateway or Linkerd ingress). You migrate to the mesh's Gateway API, not to NGF.
2. **NGF is the ingress, the mesh is internal**. Works, no problem. Traffic enters through NGF and the mesh handles intra-cluster communication.

## Does it support gRPC?

Yes, via `GRPCRoute` (a kind separate from `HTTPRoute`). Very similar syntax. NGF supports it since 2.0.

```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: GRPCRoute
metadata:
  name: my-grpc
spec:
  parentRefs: [...]
  rules:
    - matches:
        - method:
            service: my.package.MyService
            method: MyMethod
      backendRefs:
        - name: my-grpc-service
          port: 50051
```

## Does it support WebSockets?

Yes, no special configuration. NGF detects HTTP→WS upgrade automatically. **But WebSockets are the trickiest case for zero-downtime** — see `05-zero-downtime.md`.

## Does it support rate limiting?

Yes, since NGF 2.4 via `RateLimitPolicy`. Before that there was no native support and you had to use an external component.

```yaml
apiVersion: gateway.nginx.org/v1alpha1
kind: RateLimitPolicy
metadata:
  name: api-ratelimit
spec:
  targetRef:
    kind: HTTPRoute
    name: api-route
  limits:
    - limit: 100
      duration: 1m
      key:
        type: SourceIP
```

## Is it more expensive than `ingress-nginx`?

Marginally. Extra costs:
- **+1 NLB during migration** (~$20/month prorated to days).
- **+ control plane pods** of NGF (~100MB RAM total, negligible).

Post-migration: approximately the same as `ingress-nginx`.

If you compare with **NGINX Plus** (the commercial version), NGF can use either OSS or Plus. Plus adds features (live monitoring, better LB algorithms) but has a license cost.

## What if I want a definitive rollback after months?

Possible but requires inverse planning:
1. Reinstall `ingress-nginx`.
2. Re-create the Ingress objects (you have them in Git history).
3. Do the inverse canary.

However, after months operating with Gateway API, it's likely you've adopted features (filters, policies) that **don't have a direct Ingress equivalent**. The rollback may require app refactoring. **We don't recommend it** except in extreme cases.

## Does this break our existing dashboards/alerts?

Yes, the ones specific to `ingress-nginx`. Metric names change. You have to recreate them against NGF metrics before the cutover. See `07-troubleshooting.md` section "Observability".

## What do we do with annotations that have NO equivalent?

Three options, in order of preference:

1. **Refactor**: if the annotation was for something that should be in the app (auth, complex per-user rate-limit), move it to the app. It's an opportunity to pay tech debt.
2. **NGF NginxProxy/policies**: for NGINX-specific configs (timeouts, buffers), NGF has equivalent CRDs.
3. **Sidecar**: for auth or complex features, a sidecar (oauth2-proxy, envoy filter) can do the job.

## Who owns the `Gateway`?

Organizational decision. Recommendation:
- **`Gateway` is platform's**: the SRE/Platform team manages it, defines listeners, hostnames, certs.
- **`HTTPRoute` is the app team's**: each team manages its routes, in its namespace.

This is **exactly what Gateway API was designed to do**. Take advantage of it.

## Do we have to migrate all services at the same time?

No. **We don't recommend it either**. Migrate one by one:
1. Non-critical service first (learn).
2. Secondary services.
3. Critical services last, with the team seasoned.

During the transition, Ingress + Gateway coexist. No problem.

## What if client DNS fails?

If Route 53 fails, your DNS stops responding and new clients don't resolve. **It's a problem independent of the migration** — would happen the same without Gateway API. The difference: with active migration, you might have some clients resolving to the old NLB and others to the new one during the DNS outage. When DNS returns, everything normalizes to Route 53's current state.

## What if our Gateway fails?

Same analysis as `ingress-nginx`: NGF data-plane has N replicas with HPA. If the NLB remains healthy and at least 1 pod responds, no outage. If all pods fail: Gateway outage, the same as `ingress-nginx` would be in equivalent circumstances.

NGF **does NOT introduce new failure points** vs. `ingress-nginx`. The control-plane isn't in the request critical path (it just reads/writes config to NGINX).

---

Your question isn't here? Open an issue in the repo or ping the team channel.
