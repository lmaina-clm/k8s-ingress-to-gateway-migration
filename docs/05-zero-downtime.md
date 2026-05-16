**English** | [Español](05-zero-downtime.es.md)

# 05 — Zero-downtime analysis

This document answers the million-dollar question: **can you really migrate from Ingress to Gateway API without downtime?**

**Short answer**: Yes, in most cases. But there are a handful of scenarios where **it's impossible** or requires a tradeoff. Read them before promising it to anyone.

## What counts as "downtime"?

Let's define terms. "Zero-downtime" can mean different things:

| Definition | Strict | Practical |
|------------|--------|-----------|
| Availability | No 5xx requests during the migration. | < 0.01% error rate, within SLO. |
| Latency | p99 never increases > 10%. | p99 spike can rise 2x for <1 min. |
| Sessions | No user is logged out. | Few users reconnect (resilient clients). |
| Long-lived connections | Websockets/gRPC streams uninterrupted. | Automatic client reconnection OK. |

**The "practical" definition is achievable.** The "strict" one requires very strong assumptions (perfect clients, perfect DNS). Be honest with your stakeholders about which one you're promising.

## Why does the strategy with two parallel controllers work?

The key insight: **`ingress-nginx` and `nginx-gateway-fabric` are two independent controllers**, with:
- Different binaries.
- Different `IngressClass` vs `GatewayClass`.
- Different LoadBalancers (separate NLBs in AWS).
- Different pods in different namespaces.

They don't compete for resources. They don't interfere. Each one serves **its own resources** (Ingress vs HTTPRoute) and ignores the others.

This means **adding the second controller doesn't affect the first**. The only moment real traffic changes is when you modify DNS — and that's **outside the cluster**, controllable and reversible.

## The 4 real risks

### Risk 1: DNS TTL

**The problem**: if your DNS has TTL=3600s and you make the change, for an hour some clients will keep resolving to the old NLB. If you decommission before that → downtime for those clients.

**Mitigation**:
- **Lower TTL 24h before the change** to 60s (or less).
- **Wait 5×TTL before decommissioning** the old one. Ideally more.
- **Some clients (mobile apps, bots) ignore TTL** and cache for hours. For those, there's no solution other than waiting more.

**Residual impact**: 0.01% - 1% of traffic, depending on your clients. If your app has automatic retries, users don't notice.

### Risk 2: Long-lived HTTP connections

**The problem**: HTTP/1.1 keep-alive allows reusing TCP sockets for minutes/hours. HTTP/2 multiplexes requests over a single persistent connection. Once established, **a DNS change doesn't affect that connection** — it keeps going to the old NLB until it closes.

**Mitigation**:
- **The Ingress NLB keeps responding** during coexistence. Clients with open connections keep working.
- **Force close**: doing a `kubectl rollout restart deployment ingress-nginx-controller` closes connections from the server side; clients reconnect to current DNS.
- **Wait for natural timeouts**: most clients close after ~60s of inactivity. Long-duration connections have the next problem.

### Risk 3: Websockets and gRPC streams

**The problem**: a websocket or gRPC server-streaming connection can last **hours or days**. DNS changes don't affect it. Decommissioning the Ingress does, **abruptly**.

**This is the closest thing to "real downtime"** during the migration.

**Mitigations in order of complexity**:

1. **If your client reconnects automatically with backoff** (the right thing in any modern app): no problem. When you close the Ingress, clients reconnect to current DNS (which already points to the Gateway).

2. **Drain progressively before closing**: scaling down `ingress-nginx-controller` isn't optimal (NLB terminates connections abruptly). Better: reduce replicas to 1 and force termination with a `preStop` hook that does `nginx -s quit` (graceful drain). The NLB will take pods out of rotation without replicas.

3. **If you have clients that DON'T reconnect** (legacy, hardware): you have to coordinate the cutover with those clients. It's not real zero-downtime for them.

### Risk 4: Undetected semantic differences

**The problem**: Gateway API behaves slightly differently from Ingress in some subtle cases. If your app depends on a specific behavior, the change can break things **without a 5xx error** — just subtle bugs.

**Real examples we've seen**:

- **`Prefix` semantics**: `Prefix: /api` in Ingress matches `/api`, `/api/`, `/api/v1`, **and also `/apiv1`** (the latter depends on the controller). In Gateway API `PathPrefix: /api` matches `/api`, `/api/`, `/api/v1` but **NOT** `/apiv1`. If your client uses the misspelled path, it'll stop working.

- **Rewritten headers**: `ingress-nginx` adds `X-Forwarded-For`, `X-Real-IP`. NGF too, but the exact syntax can differ (especially with proxies in chain).

- **gRPC**: if your Ingress had `backend-protocol: GRPC`, in Gateway API you need a `GRPCRoute` (not an `HTTPRoute`). Using `HTTPRoute` for gRPC seems to work but fails in edge cases (trailing headers, streaming).

- **CORS**: if `ingress-nginx` CORS annotations are translated to `ResponseHeaderModifier`, the rules might not be identical (especially for preflights).

**Mitigation**:
- `scripts/compare-responses.sh` diffs responses between the two NLBs **for a list of paths**. Make sure that list covers your critical endpoints.
- **Long canary**: don't pass 10% in less than 1 hour. Give subtle differences time to show up in metrics.

## Scenarios where you CAN'T do zero-downtime

Be honest. These scenarios exist:

### Scenario A: Clients with DNS hardcoded to an IP

If your app is consumed by B2B integrations that **hardcoded the NLB IP** in their firewall, the NLB change IS an IP change. Zero-downtime requires either:
- Negotiating with the client to change their firewall (can be weeks).
- Keeping the old NLB pointing to the Gateway via an external proxy mechanism (massive over-engineering).

### Scenario B: Single-replica Ingress controller with critical connections

If for some reason you only have 1 `ingress-nginx-controller` replica, forced drain will cut connections abruptly. Before the migration, **scale to 3+ replicas and migrate gradually**.

### Scenario C: Mutual TLS with controller-specific client certs

If your Ingress had mTLS with very specific config (`auth-tls-secret`, custom validation), NGF has an equivalent since 2.6 but **client certificates may need re-rotation if they trust the Ingress cert**. Rarely a problem, but validate.

### Scenario D: Apps that DON'T tolerate seeing two backends during cutover

Very rare, but it exists. For example, if your app has **rate limiting by client IP** and the Gateway exposes a different IP than the old Ingress, during canary some clients could see "duplicated limits". Solution: rate limit in the app, not in the ingress (which is the right thing to do anyway).

## What if I fail zero-downtime?

If during canary phase you detect 5xx errors **before** 50%, reverting DNS is practically instantaneous (limited by TTL, which is 60s).

If errors appear **after** the cutover and `ingress-nginx` was already decommissioned, rollback is:
1. Reinstall `ingress-nginx`.
2. Reapply the Ingresses (you have them in Git).
3. Wait for the new NLB to be created (~3-5 min in AWS).
4. Update DNS to the new NLB.

This is **NOT zero-downtime for the rollback**, it's ~10 minutes of degradation. That's why decommissioning at the end is deliberately slow.

## Executive summary

**What we promise**: with the runbook followed, a migration with less than 0.1% additional error rate during the window, and zero user loss with resilient clients.

**What we DON'T promise**: literally zero failed requests. That's only possible with perfect clients and perfect DNS.

**Key client requirement**: automatic retries with backoff. If your client does that (any modern HTTP library), you'll notice absolutely nothing.

---

Next: [`06-rollback.md`](./06-rollback.md) — detailed rollback plan per phase.
