**English** | [Español](README.es.md)

# manifests/04-migration

JSON files with Route 53 change batches. Each one represents a different weight in the weighted routing between the two NLBs.

## How to use

Before applying **any**:

1. Edit the JSON files and replace the placeholders:
   - `<HOSTED_ZONE_ID>` — not used in the JSON (passed via CLI), but indicates context.
   - `<INGRESS_NLB_HOSTNAME>` — hostname of the ingress-nginx NLB.
   - `<INGRESS_NLB_ZONE_ID>` — Zone ID of the NLB (see table below).
   - `<GATEWAY_NLB_HOSTNAME>` — hostname of the NGF NLB.
   - `<GATEWAY_NLB_ZONE_ID>` — Zone ID of the NLB.

2. Apply with:

   ```bash
   aws route53 change-resource-record-sets \
     --hosted-zone-id Z123ABC \
     --change-batch file://manifests/04-migration/dns-canary-10pct.json
   ```

## NLB Zone IDs per region

| Region | Zone ID |
|--------|---------|
| us-east-1 | Z26RNL4JYFTOTI |
| us-east-2 | ZLMOA37VPKANP |
| us-west-1 | Z24FKFUX50B4VW |
| us-west-2 | Z18D5FSROUN65G |
| eu-west-1 | Z2IFOLAFXWLO4F |
| eu-central-1 | Z3F0SRJ5LGBH90 |
| ap-southeast-1 | ZKVM4W9LS7TM |
| ap-northeast-1 | Z31USIVHYNEOWT |

(Full list in AWS docs — current for 2026.)

To discover a Zone ID for a given hostname:

```bash
aws elbv2 describe-load-balancers \
  --query "LoadBalancers[?DNSName=='<HOSTNAME>'].CanonicalHostedZoneId" \
  --output text
```

## Files per phase

| File | Ingress weight | Gateway weight | When to use |
|------|----------------|----------------|-------------|
| `dns-canary-10pct.json` | 90 | 10 | Initial phase 5 |
| `dns-canary-25pct.json` | 75 | 25 | Promotion |
| `dns-canary-50pct.json` | 50 | 50 | Inflection point |
| `dns-canary-75pct.json` | 25 | 75 | Near the end |
| `dns-canary-100pct.json` | 0 | 100 | Final cutover |
| `dns-rollback-100pct-ingress.json` | 100 | 0 | Full rollback |
| `dns-final-state.json` | (removed) | 100 (simple) | Post-decommission |

## Low TTL (preparation)

Before starting the canary, lower the TTL so changes propagate fast:

```bash
aws route53 change-resource-record-sets \
  --hosted-zone-id Z123ABC \
  --change-batch file://manifests/04-migration/dns-prepare-lower-ttl.json
```

And wait 24h (or the previous TTL) before the first canary.
