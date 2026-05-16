**English** | [Español](06-rollback.es.md)

# 06 — Rollback Plan

> A migration plan without a rollback plan isn't a plan, it's a bet.

This document details **what to do if things go wrong** at each phase. It's designed to be executed under pressure: use the exact commands, don't improvise.

## Principles

1. **Fast rollback > elegant rollback.** When in doubt, revert.
2. **Document the decision.** Why revert, what was observed. It'll help on the next attempt.
3. **Don't revert alone.** Notify the team before touching production.
4. **Keep Git as source of truth.** If it's not in Git, the state you'd roll back to doesn't exist.

## Rollback matrix per phase

| Phase | Reversible? | Time | User impact |
|-------|-------------|------|-------------|
| 1. Baseline | ✅ Trivial (nothing changed) | 0 min | 0 |
| 2. Install NGF | ✅ Clean | 5 min | 0 |
| 3. Configure Gateway | ✅ Clean | 5 min | 0 |
| 4. Validate in parallel | ✅ Clean | 5 min | 0 |
| 5. Canary DNS 10% | ✅ Fast (via DNS) | 1-2 min + TTL | ~10% of users affected during TTL |
| 6. Gradual promotion | ✅ Fast (via DNS) | 1-2 min + TTL | % equal to canary weight |
| 7. Drain Ingress | ⚠️ Still reversible | 5 min + TTL | Low, but users with new connections to the Gateway can see inconsistency |
| 8. Decommission | ❌ Costly | 15-30 min | Possible downtime while reinstalling |

## Rollback PHASE 2 — NGF installed

**Typical symptom**: NGF doesn't start, CRDs conflict with something existing, GatewayClass not accepted.

```bash
# 1. Uninstall NGF
helm uninstall ngf -n nginx-gateway

# 2. Remove Gateway API CRDs (CAUTION if you have other apps using them)
kubectl delete -f https://github.com/kubernetes-sigs/gateway-api/releases/download/v1.5.1/standard-install.yaml

# 3. Remove namespaces
kubectl delete namespace nginx-gateway gateway-system 2>/dev/null

# 4. Validate
kubectl get gatewayclass    # should be empty
kubectl get crd | grep gateway.networking.k8s.io   # should be empty
```

**Post-rollback validation**: traffic via `ingress-nginx` should remain intact. Run `./scripts/validate-traffic.sh ingress`.

## Rollback PHASE 3 — Gateway created

**Typical symptom**: the `Gateway` doesn't reach `Programmed`, NLB isn't created, errors in control-plane logs.

```bash
# 1. Remove HTTPRoutes and Gateway
kubectl delete -f manifests/03-gateway-api/

# 2. Verify the NLB was destroyed
aws elbv2 describe-load-balancers --region <region> \
  --query "LoadBalancers[?contains(LoadBalancerName,'k8s-gateway')]"
# The list should be empty (can take 1-2 min)

# 3. Keep CRDs and NGF installed; the problem is in the resources, not the controller
```

**Validation**: Gateway NLB destroyed in AWS. The `ingress-nginx` one remains intact.

## Rollback PHASE 4 — Parallel validation

Here you only did curls. If you found problems:

- **If the problem is semantic** (different responses between Ingress and Gateway): fix the `HTTPRoute`s or annotations, **don't revert yet**.
- **If the problem is the controller** (5xx, high latency): revert as in phase 3.

## Rollback PHASE 5 — Canary 10% active

**The most important one**. Here you're affecting real users.

### Immediate trigger (no thinking)

- Error rate to the new NLB > 1% for more than 30 seconds.
- p99 latency to the new NLB > 3x baseline.
- Cascading alerts in downstream services.

### Panic command

```bash
# DNS back to 100% Ingress
aws route53 change-resource-record-sets \
  --hosted-zone-id $HOSTED_ZONE_ID \
  --change-batch file://manifests/04-migration/dns-rollback-100pct-ingress.json

# While DNS propagates (60s with low TTL), optionally scale data-plane replicas to 0
kubectl scale deployment -n gateway-system nginx-boutique-gateway --replicas=0
```

### Communication

```
🚨 Migration rollback activated
- Time: <timestamp>
- Phase: 5 (canary 10%)
- Reason: <error rate spike | latency | unknown>
- DNS reverted: yes
- ETA back to baseline: ~60s (DNS TTL)
- Next action: <root cause analysis | retry | postmortem>
```

Notify the incident channel / on-call channel.

### Post-rollback validation

```bash
# 1. DNS reverted
dig +short shop.example.com

# 2. Traffic returning to the old Ingress
kubectl logs -n ingress-nginx -l app.kubernetes.io/component=controller --tail=20

# 3. Error rate normalized
./scripts/validate-traffic.sh ingress
```

## Rollback PHASE 6 — Gradual promotion

Identical to phase 5, but the weight to restore is the **previous step's**, not 0%.

```bash
# E.g.: you were at 75% and want to go back to 50%
aws route53 change-resource-record-sets \
  --hosted-zone-id $HOSTED_ZONE_ID \
  --change-batch file://manifests/04-migration/dns-canary-50pct.json
```

If problems are severe, **go directly to 0% Gateway** (full rollback).

## Rollback PHASE 7 — Ingress draining

Still reversible **as long as you haven't decommissioned the controller**.

```bash
# DNS back to the Ingress
aws route53 change-resource-record-sets \
  --hosted-zone-id $HOSTED_ZONE_ID \
  --change-batch file://manifests/04-migration/dns-rollback-100pct-ingress.json
```

But beware: clients that already connected to the Gateway may have **state** (session cookies issued by the app, not by the ingress). If they return to the old Ingress, they **should** keep working (because state is managed by the app, not the ingress) — **but you must validate this in your specific case**. If your app uses cookies signed with a pod-specific secret, that's a separate problem.

## Rollback PHASE 8 — After decommissioning

Here rollback is **costly**. Steps:

### 1. Reinstall `ingress-nginx`

```bash
# Reapply the installation
./scripts/install-ingress-nginx.sh
```

Wait ~5 min for the controller to be Ready and the NLB to be created.

### 2. Reapply Ingress objects

```bash
kubectl apply -f manifests/02-ingress-nginx/ingress.yaml
```

### 3. Get the new NLB hostname

```bash
INGRESS_NLB=$(kubectl get svc -n ingress-nginx ingress-nginx-controller \
  -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')
echo "New Ingress NLB: $INGRESS_NLB"
```

### 4. Change DNS

```bash
# Edit manifests/04-migration/dns-rollback-100pct-ingress.json
# with the new hostname and apply
```

### 5. Wait for propagation

With TTL=60s, ~5 min of partial degradation while DNS propagates.

**Estimated total rollback impact at this phase**: 10-15 minutes where a % of traffic will see intermittent errors.

## How to decide: revert vs continue

Quick decision table:

| Symptom | Decision |
|---------|----------|
| Error rate > 1% sustained > 1 min | **Revert immediately** |
| Error rate < 1% but worse than baseline | Wait 5 min. If it persists, revert. |
| p99 latency > 2x baseline sustained | **Revert immediately** |
| p99 latency ~1.5x baseline | Likely expected (NGF takes time to warm up). Wait 10 min. |
| Isolated errors on a specific endpoint | DO NOT revert the whole change. Investigate the specific `HTTPRoute` config. |
| B2B client complains | Investigate — could be their issue (hardcoded DNS), not ours. |
| Downstream service alert | Likely correlation, not causation. Investigate before reverting. |
| "Something feels off" | Wait 5 min. If the feeling persists, revert. SRE intuition is a signal. |

## Complete rollback script

`scripts/rollback.sh` automates the most common rollback (DNS to 100% Ingress). But **read the script before using it in panic** — understand what it does.

```bash
./scripts/rollback.sh --to ingress --hosted-zone-id Z123ABC --confirm
```

The `--confirm` is mandatory to avoid accidents.

---

Next: [`07-troubleshooting.md`](./07-troubleshooting.md) — common problems and diagnosis.
