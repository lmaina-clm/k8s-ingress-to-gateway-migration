**English** | [Español](04-migration-runbook.es.md)

# 04 — Migration runbook

This is the document you execute. Each phase has a **prerequisite**, **actions**, **success criteria**, and **immediate rollback**. Don't skip phases.

> **Convention**: commands assume you're at the repo root and your `kubectl` points to the correct cluster. Verify with `kubectl config current-context` **before each command**.

## Visual runbook summary

```
PHASE 1: Baseline               ← Verify your current Ingress works
PHASE 2: Install Gateway API    ← CRDs + NGINX Gateway Fabric (no traffic impact)
PHASE 3: Configure Gateway      ← Gateway + HTTPRoutes (no DNS yet)
PHASE 4: Validate in parallel   ← Curl with Host header against the new NLB
PHASE 5: Canary DNS             ← Route 53 weighted, 10% to Gateway
PHASE 6: Promote                ← Gradually move to 100% Gateway
PHASE 7: Drain Ingress          ← TTL elapsed, no residual traffic
PHASE 8: Decommission           ← Remove ingress-nginx
```

Total estimated duration: **3-5 days** (most of it is observation window, not active work).

---

## PHASE 1: Baseline

**Goal**: document the current state and verify the Ingress works as expected.

### Prerequisite

- All checklist from `01-prerequisites.md` completed.
- You have access to `ingress-nginx-controller` metrics and logs.

### Actions

1. **Snapshot current Ingresses**:
   ```bash
   kubectl get ingress -A -o yaml > /tmp/ingress-snapshot-$(date +%Y%m%d).yaml
   ```

2. **Snapshot special annotations**:
   ```bash
   kubectl get ingress -A -o json | jq '.items[] | {name: .metadata.name, ns: .metadata.namespace, annotations: .metadata.annotations}' > /tmp/annotations-$(date +%Y%m%d).json
   ```
   Review this file. Each annotation must have its Gateway API equivalent (see `03-ingress-vs-gateway.md`).

3. **Baseline metrics** (record these numbers, you'll compare against them):
   - Average RPS (5 min and peak)
   - p50, p95, p99 latency
   - Error rate (4xx, 5xx)
   - Top 10 endpoints by traffic

4. **Smoke test**:
   ```bash
   ./scripts/validate-traffic.sh ingress
   ```
   This makes requests to the main paths and reports latency/status. Save the output.

### Success criteria

- [ ] Ingress snapshot captured.
- [ ] Annotations documented with a migration plan for each.
- [ ] Baseline metrics recorded.
- [ ] Smoke test passes at 100%.

### Rollback

N/A — you're just reading state.

---

## PHASE 2: Install Gateway API and NGINX Gateway Fabric

**Goal**: install the new controller **without touching current traffic**.

### Prerequisite

- Phase 1 complete.
- AWS Load Balancer Controller working.

### Actions

1. **Install Gateway API CRDs** (v1.5.1):
   ```bash
   kubectl apply -f https://github.com/kubernetes-sigs/gateway-api/releases/download/v1.5.1/standard-install.yaml
   ```

2. **Verify CRDs**:
   ```bash
   kubectl get crd | grep gateway.networking.k8s.io
   ```
   You should see: `gateways`, `gatewayclasses`, `httproutes`, `grpcroutes`, `referencegrants`.

3. **Install NGINX Gateway Fabric** via Helm:
   ```bash
   ./scripts/install-nginx-gateway-fabric.sh
   ```
   The script:
   - Creates the `nginx-gateway` namespace.
   - Installs NGF 2.6.x with EKS-opinionated values.
   - Waits for the control-plane to be `Ready`.

4. **Verify control-plane**:
   ```bash
   kubectl get pods -n nginx-gateway
   kubectl get gatewayclass nginx-gateway
   ```
   `gatewayclass nginx-gateway` must be `ACCEPTED=True`.

5. **DO NOT create the `Gateway` yet.** Without a `Gateway`, NGF doesn't create a data-plane or NLB. Zero impact.

### Success criteria

- [ ] CRDs present (5 minimum).
- [ ] NGF control-plane `Running`.
- [ ] `GatewayClass nginx-gateway` `ACCEPTED`.
- [ ] `kubectl get svc -A` does NOT show any new NLB (none was created yet).
- [ ] Traffic via `ingress-nginx` still at 100%. `./scripts/validate-traffic.sh ingress` passes.

### Rollback

```bash
helm uninstall ngf -n nginx-gateway
kubectl delete -f https://github.com/kubernetes-sigs/gateway-api/releases/download/v1.5.1/standard-install.yaml
kubectl delete namespace nginx-gateway
```

---

## PHASE 3: Configure Gateway and HTTPRoutes

**Goal**: create the Gateway API resources. This provisions a **new NLB in parallel**, but with no public DNS pointing to it.

### Prerequisite

- Phase 2 complete.
- You have the `Secret` with the TLS certificate (can be the same the current Ingress uses).

### Actions

1. **Create namespaces and ReferenceGrant**:
   ```bash
   kubectl apply -f manifests/00-base/
   ```

2. **Copy the TLS secret to namespace `gateway-system`** (if not using cert-manager):
   ```bash
   kubectl get secret shop-tls -n microservices -o yaml \
     | sed 's/namespace: microservices/namespace: gateway-system/' \
     | kubectl apply -f -
   ```
   If using **cert-manager**, create the `Certificate` directly in `gateway-system`:
   ```bash
   kubectl apply -f manifests/03-gateway-api/examples/certificate.yaml.example
   ```

3. **Apply Gateway and HTTPRoutes**:
   ```bash
   kubectl apply -f manifests/03-gateway-api/
   ```

4. **Wait for the data-plane to be provisioned**:
   ```bash
   kubectl wait --for=condition=Programmed gateway/boutique-gateway \
     -n gateway-system --timeout=300s
   ```

5. **Get the NLB hostname**:
   ```bash
   export GW_NLB=$(kubectl get svc -n gateway-system \
     -l gateway.networking.k8s.io/gateway-name=boutique-gateway \
     -o jsonpath='{.items[0].status.loadBalancer.ingress[0].hostname}')
   echo "New NLB: $GW_NLB"
   ```

### Success criteria

- [ ] `kubectl get gateway -n gateway-system boutique-gateway` shows `PROGRAMMED=True`.
- [ ] `kubectl get httproute -n microservices` — all in `ACCEPTED=True` and `ResolvedRefs=True`.
- [ ] A new NLB exists (`$GW_NLB` not empty).
- [ ] The old NLB (ingress-nginx) is intact and serving traffic.

### Rollback

```bash
kubectl delete -f manifests/03-gateway-api/
# The new NLB is destroyed automatically.
```

---

## PHASE 4: Validate in parallel (no DNS)

**Goal**: validate that the new Gateway serves traffic correctly, without exposing it publicly yet.

### Actions

1. **Smoke test against the new NLB with `Host:` header**:
   ```bash
   ./scripts/validate-traffic.sh gateway $GW_NLB
   ```
   The script does:
   ```bash
   curl -k --resolve shop.example.com:443:$(dig +short $GW_NLB | head -1) \
        https://shop.example.com/
   ```
   This lets you talk to the new NLB as if it were real, without touching DNS.

2. **Compare responses between the two NLBs**:
   ```bash
   ./scripts/compare-responses.sh
   ```
   Makes the same request to both NLBs and compares:
   - Status code
   - Critical headers (`Content-Type`, `Cache-Control`)
   - Body (with tolerance for timestamps/IDs)

   **Expected result**: 100% match. If there are differences, review annotations that weren't migrated correctly.

3. **Light load test against the new NLB** (without promoting yet):
   ```bash
   # 100 RPS for 60s, enough to validate no obvious problems
   hey -z 60s -c 10 -q 10 \
       -host shop.example.com \
       https://$GW_NLB/
   ```
   Expected metrics:
   - p95 latency ≤ baseline + 20%
   - 0 5xx errors

4. **Validate observability of the new path**:
   - NGF metrics arriving in Prometheus.
   - Logs accessible.
   - Alerts you have on the old Ingress, already replicated for NGF (with the new metric names).

### Success criteria

- [ ] Smoke test passes 100% against the new NLB.
- [ ] Diff between the two NLBs: only expected differences (request IDs, timestamps).
- [ ] Light load test without errors.
- [ ] NGF metrics and logs visible in your dashboards.
- [ ] Alerts for the new dataplane configured.

### Rollback

Same as phase 3. This is the last point you can undo without risk.

---

## PHASE 5: Canary DNS — 10%

**Goal**: start sending real traffic to the new Gateway, but only a small fraction.

> ⚠️ **From here on, changes are user-visible.** Have observability active and rollback at hand.

### Prerequisite

- Phase 4 complete with stable metrics.
- DNS based on Route 53 (or equivalent with weighted routing).
- Maintenance window announced (even if we hope not to need it).
- Minimum two people: one operates, the other observes.

### Actions

1. **Change DNS record from simple `A` to weighted alias** (if it wasn't already):

   **Before** (initial state):
   ```
   shop.example.com  →  ALIAS  →  <NLB-ingress-nginx>
   ```

   **After** (weighted):
   ```
   shop.example.com  →  weighted, weight=90, id="ingress"  →  <NLB-ingress-nginx>
   shop.example.com  →  weighted, weight=10, id="gateway"  →  <NLB-gateway-fabric>
   ```

   AWS CLI command (assumes hosted zone `Z123ABC`):
   ```bash
   aws route53 change-resource-record-sets \
     --hosted-zone-id Z123ABC \
     --change-batch file://manifests/04-migration/dns-canary-10pct.json
   ```
   (see example file in `manifests/04-migration/`)

2. **Lower TTL before the change** (ideally 24h before):
   ```
   TTL: 60s
   ```
   If your TTL was 3600s, DNS resolvers will have a cache. Lowering the TTL **24 hours before** ensures subsequent changes propagate fast.

3. **Observe for minimum 30 min**:
   - Error rate on both NLBs.
   - p95 latency on both NLBs.
   - Error logs on NGF data-plane.
   - Error logs on `ingress-nginx`.

   If everything is stable: continue to phase 6.

### Success criteria

- [ ] Traffic observable on NGF (~10% of total).
- [ ] Error rate on the new NLB ≤ baseline error rate.
- [ ] p95 latency ≤ baseline + 20%.
- [ ] No errors in NGF logs suggesting routing issues.

### Rollback

**Fast (recommended if in doubt)**:
```bash
aws route53 change-resource-record-sets \
  --hosted-zone-id Z123ABC \
  --change-batch file://manifests/04-migration/dns-rollback-100pct-ingress.json
```
DNS reverts to 100% Ingress. Wait for TTL (60s) and clients return to the previous state.

---

## PHASE 6: Promote gradually

**Goal**: increase the Gateway weight in controlled steps, verifying stability at each one.

### Actions

Repeat the phase 5 pattern with these weights, waiting **minimum 30 minutes** between changes (ideally 2-4 hours in production):

```
10% → 25% → 50% → 75% → 100%
```

At each step:

1. Apply the DNS change (a `.json` file per step in `manifests/04-migration/`).
2. Observe minimum 30 min.
3. Validate success criteria.
4. Continue or rollback.

### Success criteria per step

- Same as phase 5, with stable tolerances.
- **Special attention at 50%**: it's the point where any difference between the two controllers will be most visible (broken sticky sessions, different headers, etc.).

### Rollback

At any step, apply the DNS of the previous step. Low TTL → fast propagation.

---

## PHASE 7: Drain the Ingress

**Goal**: with 100% of new traffic on Gateway, wait for the Ingress to drain residual connections.

### Actions

1. **With DNS at 100% on Gateway**, wait **minimum 5 × TTL** of the DNS.
   - With TTL=60s → 5 min minimum, recommended 1 hour for long-lived connections.

2. **Verify residual traffic** on `ingress-nginx`:
   ```bash
   kubectl logs -n ingress-nginx -l app.kubernetes.io/component=controller \
     --tail=100 -f
   ```
   If you still see requests, **don't continue**. Some client has long DNS cache or a persistent connection without reconnection.

3. **Common residual traffic and what to do**:
   - Bots with hardcoded DNS cache → ignorable, they eventually reconnect.
   - Clients honoring TTL=0 badly → wait more.
   - **Long-lived non-reconnecting connections** → your problem. Force client restart or wait.

### Success criteria

- [ ] DNS at 100% on Gateway for minimum 1 hour.
- [ ] Traffic to `ingress-nginx` NLB < 0.1% of total (or zero).
- [ ] No active alerts related to the change.

### Rollback

Still possible: revert DNS. But with new clients already connected to the Gateway, partial rollback can cause state inconsistencies. **Conscious decision with stakeholders.**

---

## PHASE 8: Decommission `ingress-nginx`

**Goal**: clean up. Once decommissioned, rollback is no longer trivial.

### Prerequisite

- Phase 7 complete, minimum 24 hours stable.
- Explicit approval from the service owner.

### Actions

1. **Delete the Ingresses** (this does NOT destroy the controller yet):
   ```bash
   kubectl delete -f manifests/02-ingress-nginx/ingress.yaml
   ```

2. **Wait 30 minutes**. If something breaks, restore:
   ```bash
   kubectl apply -f manifests/02-ingress-nginx/ingress.yaml
   ```
   And revert DNS. This is the last reasonable rollback window.

3. **If everything OK, uninstall `ingress-nginx`**:
   ```bash
   helm uninstall ingress-nginx -n ingress-nginx
   kubectl delete namespace ingress-nginx
   ```
   This destroys the old NLB automatically.

4. **Clean up DNS** — remove the weighted record pointing to the old NLB, leave only the Gateway one (or convert to a simple record without weighting):
   ```bash
   aws route53 change-resource-record-sets \
     --hosted-zone-id Z123ABC \
     --change-batch file://manifests/04-migration/dns-final-state.json
   ```

5. **Raise TTL back** to your normal value (300s or more).

### Success criteria

- [ ] `ingress-nginx` namespace removed.
- [ ] Old NLB destroyed (verify in AWS console).
- [ ] DNS clean, no records to the old NLB.
- [ ] Service working at 100% only with Gateway API.
- [ ] Post-mortem or retrospective scheduled.

---

## Post-migration

Tasks that **aren't urgent** but need to be done:

- [ ] Update operational runbooks that mention `ingress-nginx`.
- [ ] Update dashboards if old widgets remain.
- [ ] Review your Helm chart / Kustomize / GitOps to use Gateway API by default in future deploys.
- [ ] Train the team (this repo + internal Q&A session).
- [ ] Document any deviations from the standard runbook for future migrations.

---

## Typical timings

| Phase | Active time | Total time (with observation) |
|-------|-------------|------------------------------|
| 1. Baseline | 1h | 1h |
| 2. Install NGF | 30 min | 1h |
| 3. Configure Gateway | 30 min | 1h |
| 4. Validate in parallel | 1h | 4h (recommended overnight if production-critical) |
| 5. Canary 10% | 15 min | 30 min - 2h |
| 6. Gradual promotion | 1h | 1 day (with waits between steps) |
| 7. Drain Ingress | 15 min | 2-4h |
| 8. Decommission | 30 min | 24h (safety wait before deleting) |
| **TOTAL** | **~5h** | **3-5 days** |

---

Next: [`05-zero-downtime.md`](./05-zero-downtime.md) — deep analysis of zero-downtime risks.
