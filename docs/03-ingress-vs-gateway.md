**English** | [Español](03-ingress-vs-gateway.es.md)

# 03 — Ingress vs Gateway API: conceptual comparison and mapping

This document is the quick reference during the migration. If you come from `ingress-nginx` and never touched Gateway API, **start here**.

## The mental shift: separation of responsibilities

`Ingress` mixes into a single object things that belong to different people:

- **How the cluster is exposed** (LB type, certificates, listeners) — platform team's responsibility.
- **How traffic is routed** to the application — application team's responsibility.

Gateway API separates this into **roles**:

```
┌────────────────────────────────────────────────────────────────┐
│  Role: Infrastructure (Cloud provider)                         │
│  Resource: GatewayClass                                        │
│  Defines: "I'm a controller capable of serving gateways."      │
└────────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌────────────────────────────────────────────────────────────────┐
│  Role: Platform / SRE                                          │
│  Resource: Gateway                                             │
│  Defines: "I want an entry point at :443 with this cert,       │
│            using this GatewayClass."                           │
└────────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌────────────────────────────────────────────────────────────────┐
│  Role: Application developer                                   │
│  Resource: HTTPRoute                                           │
│  Defines: "Attach your Gateway to the frontend service when    │
│            the path starts with /api/cart."                    │
└────────────────────────────────────────────────────────────────┘
```

In classic Ingress, **everyone edited the same object**, which created conflicts and permissions issues. Gateway API allows each role to have its own RBAC.

## Side-by-side comparison

### Case 1: Simple Ingress

**Classic Ingress:**

```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: boutique
  namespace: microservices
  annotations:
    nginx.ingress.kubernetes.io/ssl-redirect: "true"
spec:
  ingressClassName: nginx
  tls:
    - hosts: [shop.example.com]
      secretName: shop-tls
  rules:
    - host: shop.example.com
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: frontend
                port:
                  number: 80
```

**Gateway API equivalent:**

```yaml
# The Gateway (lives in the platform namespace)
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  name: boutique-gateway
  namespace: gateway-system
spec:
  gatewayClassName: nginx-gateway
  listeners:
    - name: https
      protocol: HTTPS
      port: 443
      hostname: shop.example.com
      tls:
        mode: Terminate
        certificateRefs:
          - kind: Secret
            name: shop-tls
            namespace: gateway-system
      allowedRoutes:
        namespaces:
          from: Selector
          selector:
            matchLabels:
              gateway-access: "true"
    - name: http
      protocol: HTTP
      port: 80
      hostname: shop.example.com
      allowedRoutes:
        namespaces:
          from: Selector
          selector:
            matchLabels:
              gateway-access: "true"
---
# The HTTPRoute (lives in the app namespace)
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: boutique-route
  namespace: microservices
spec:
  parentRefs:
    - name: boutique-gateway
      namespace: gateway-system
      sectionName: https
  hostnames:
    - shop.example.com
  rules:
    - matches:
        - path:
            type: PathPrefix
            value: /
      backendRefs:
        - name: frontend
          port: 80
---
# And an extra HTTPRoute to force HTTP → HTTPS redirect
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: boutique-https-redirect
  namespace: microservices
spec:
  parentRefs:
    - name: boutique-gateway
      namespace: gateway-system
      sectionName: http
  hostnames:
    - shop.example.com
  rules:
    - filters:
        - type: RequestRedirect
          requestRedirect:
            scheme: https
            statusCode: 301
```

Yes, it's more lines. But:
- You write the `Gateway` once and reuse it across many `HTTPRoute`s.
- The HTTP→HTTPS redirect is explicit (in Ingress it was a hidden annotation).
- `allowedRoutes` protects you from any dev creating an `HTTPRoute` pointing to your Gateway without permission.

## Complete `ingress-nginx` → Gateway API annotation mapping

| `ingress-nginx` annotation | Gateway API equivalent | Notes |
|----------------------------|------------------------|-------|
| `nginx.ingress.kubernetes.io/rewrite-target` | `HTTPRoute` filter `URLRewrite` | Native, much cleaner. |
| `nginx.ingress.kubernetes.io/ssl-redirect` | `HTTPRoute` filter `RequestRedirect` with `scheme: https` | Explicit on a route. |
| `nginx.ingress.kubernetes.io/force-ssl-redirect` | Same as above ↑ | Same pattern. |
| `nginx.ingress.kubernetes.io/use-regex` | `path.type: RegularExpression` | NGF supports it since 2.3+. |
| `nginx.ingress.kubernetes.io/backend-protocol` | `backendRefs` with `appProtocol` on the Service, or `GRPCRoute` for gRPC | For gRPC, use `GRPCRoute` (not `HTTPRoute`). |
| `nginx.ingress.kubernetes.io/proxy-body-size` | `NginxProxy` resource (NGF CRD) | NGF-specific, not standard Gateway API. |
| `nginx.ingress.kubernetes.io/proxy-read-timeout` | `NginxProxy` resource | Idem. |
| `nginx.ingress.kubernetes.io/proxy-connect-timeout` | `NginxProxy` resource | Idem. |
| `nginx.ingress.kubernetes.io/limit-rps` / `limit-rpm` | `ObservabilityPolicy` + `RateLimitPolicy` (NGF 2.4+) | Supported since 2.4. |
| `nginx.ingress.kubernetes.io/auth-url` | No direct equivalent. Use `ExtensionRef` or a sidecar (oauth2-proxy). | Paradigm shift. |
| `nginx.ingress.kubernetes.io/auth-tls-secret` (client mTLS) | `Gateway.spec.listeners[].tls` + `FrontendTLS` (NGF 2.6+) | New in 2.6. |
| `nginx.ingress.kubernetes.io/cors-*` | `HTTPRoute` with `ResponseHeaderModifier` filter or `NginxProxy` | More manual. |
| `nginx.ingress.kubernetes.io/server-snippet` | NO equivalent. Custom snippets are an antipattern in Gateway API. | Refactor to native resources. |
| `nginx.ingress.kubernetes.io/configuration-snippet` | NO equivalent. | Idem. |
| `nginx.ingress.kubernetes.io/canary` | Weights in `backendRefs[].weight` | Much cleaner, part of the spec. |
| `nginx.ingress.kubernetes.io/affinity` (sticky) | `SessionPersistence` policy (NGF 2.4+) | Sticky cookie supported. |
| `nginx.ingress.kubernetes.io/load-balance` | `BackendLBPolicy` (NGF 2.4+, custom) | Limited to round-robin/least-conn. |

### Annotations without direct equivalent

If your Ingress has any of these, **review before migrating**:

- `server-snippet` / `configuration-snippet` — Gateway API is deliberately strict: it doesn't allow injecting arbitrary NGINX config. Consider it a refactor opportunity.
- `auth-url` / `auth-signin` — For this, NGF has the `ExtensionRef` filter that points to an `ExternalAuth` policy, but it's additional complexity. The most common alternative is to **move auth to the application** or use a sidecar (`oauth2-proxy`).
- `permanent-redirect` with complex regex — Works, but the syntax changes. Validate one by one.

## Important semantic differences

### 1. `pathType`

| Ingress | Gateway API |
|---------|-------------|
| `Exact` | `Exact` |
| `Prefix` | `PathPrefix` |
| `ImplementationSpecific` | `RegularExpression` (more explicit) |

**Common gotcha**: `Prefix: /foo` in Ingress matches `/foo` and `/foo/bar`. In Gateway API `PathPrefix: /foo` matches **only `/foo` and `/foo/...`** (with `/` after). To match `/foobar`, you need regex. This is a known gotcha — test it in the canary.

### 2. Multiple hosts

In Ingress: one object can have N hosts in `rules`. In Gateway API: an `HTTPRoute` can also have multiple `hostnames`, **but they must be a subset of the `Gateway`'s hostnames**. If your Ingress serves `a.example.com` and `b.example.com`, the `Gateway` needs both in `listeners`.

### 3. TLS per host

Ingress allows `tls[]` with one cert per host. Gateway API: each `listener` has its own cert. If you have 5 hosts with 5 certs, that's 5 listeners (or one with SNI and multiple `certificateRefs` — supported).

### 4. Status and observability

Gateway API has a much richer `status` model. Each resource reports:
- `Accepted`: the controller understood it.
- `Programmed`: the dataplane already has the config applied.
- `ResolvedRefs`: the `backendRefs` point to services that exist.

```bash
kubectl get httproute -n microservices boutique-route -o yaml | yq '.status'
```

This tells you **exactly** if your route is active or why not. With `ingress-nginx`, you had to read controller logs.

### 5. Security headers injected by default

Difference **detected during real validation** between the two data planes:

| Header | ingress-nginx | NGF 2.x |
|--------|---------------|---------|
| `strict-transport-security` (HSTS) | Injected by default when TLS is on (`max-age=31536000; includeSubDomains`) | **NOT** injected |
| `x-frame-options` / `x-content-type-options` | Configurable via `ConfigMap` | Via `ResponseHeaderModifier` filter or policy |

**Implication**: if your app implicitly depended on the HSTS that `ingress-nginx` added, when migrating to NGF clients will stop receiving it. To preserve the behavior, add a filter to the `HTTPRoute`:

```yaml
rules:
  - filters:
      - type: ResponseHeaderModifier
        responseHeaderModifier:
          add:
            - name: Strict-Transport-Security
              value: "max-age=31536000; includeSubDomains"
    backendRefs:
      - name: frontend
        port: 80
```

### 6. HTTP → HTTPS redirect status code

| Implementation | Default status code |
|----------------|---------------------|
| `ingress-nginx` with `force-ssl-redirect: "true"` | **308** (Permanent Redirect, preserves the method) |
| NGF with `RequestRedirect` filter without `statusCode` | **302** (Found, doesn't preserve method) |
| NGF with `statusCode: 301` (default in this repo) | **301** (Moved Permanently, doesn't preserve method) |

**Implication**: if your clients send POST/PUT to the HTTP URL expecting them to be forwarded as-is, `308` preserves them. `301`/`302` convert them to `GET` in many clients (especially legacy ones). To replicate the exact `ingress-nginx` behavior, use `statusCode: 308` in the `RequestRedirect` filter of the Gateway.

## What if I need something Gateway API doesn't support natively?

Three paths in order of preference:

1. **Use a standard policy** (`BackendTLSPolicy`, `RateLimitPolicy`, etc.) — they're part of the extended spec.
2. **Use an NGF-specific policy** (`NginxProxy`, `ClientSettingsPolicy`, `ObservabilityPolicy`). Ties you to NGF but is closest to `ingress-nginx` annotations.
3. **Refactor to another layer** (sidecar, service mesh, app code). Sometimes the healthiest option.

---

Next: [`04-migration-runbook.md`](./04-migration-runbook.md) — the executable runbook.
