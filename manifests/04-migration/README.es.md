[English](README.md) | **Español**

# manifests/04-migration

Archivos JSON con los change batches para Route 53. Cada uno representa un peso distinto en el weighted routing entre los dos NLBs.

## Cómo usar

Antes de aplicar **cualquiera**:

1. Edita los archivos JSON y reemplaza los placeholders:
   - `<HOSTED_ZONE_ID>` — no se usa en el JSON (se pasa por CLI), pero indica el contexto.
   - `<INGRESS_NLB_HOSTNAME>` — hostname del NLB de ingress-nginx.
   - `<INGRESS_NLB_ZONE_ID>` — Zone ID del NLB (ver tabla abajo).
   - `<GATEWAY_NLB_HOSTNAME>` — hostname del NLB de NGF.
   - `<GATEWAY_NLB_ZONE_ID>` — Zone ID del NLB.

2. Aplica con:

   ```bash
   aws route53 change-resource-record-sets \
     --hosted-zone-id Z123ABC \
     --change-batch file://manifests/04-migration/dns-canary-10pct.json
   ```

## Zone IDs de NLB por región

| Región | Zone ID |
|--------|---------|
| us-east-1 | Z26RNL4JYFTOTI |
| us-east-2 | ZLMOA37VPKANP |
| us-west-1 | Z24FKFUX50B4VW |
| us-west-2 | Z18D5FSROUN65G |
| eu-west-1 | Z2IFOLAFXWLO4F |
| eu-central-1 | Z3F0SRJ5LGBH90 |
| ap-southeast-1 | ZKVM4W9LS7TM |
| ap-northeast-1 | Z31USIVHYNEOWT |

(Lista completa en docs de AWS — para 2026 vigentes.)

Para descubrir un Zone ID dado un hostname:

```bash
aws elbv2 describe-load-balancers \
  --query "LoadBalancers[?DNSName=='<HOSTNAME>'].CanonicalHostedZoneId" \
  --output text
```

## Archivos por fase

| Archivo | Peso Ingress | Peso Gateway | Cuando usar |
|---------|--------------|--------------|-------------|
| `dns-canary-10pct.json` | 90 | 10 | Fase 5 inicial |
| `dns-canary-25pct.json` | 75 | 25 | Promoción |
| `dns-canary-50pct.json` | 50 | 50 | Punto de inflexión |
| `dns-canary-75pct.json` | 25 | 75 | Casi al final |
| `dns-canary-100pct.json` | 0 | 100 | Cutover final |
| `dns-rollback-100pct-ingress.json` | 100 | 0 | Rollback total |
| `dns-final-state.json` | (removed) | 100 (simple) | Post-decomisión |

## TTL bajo (preparación)

Antes de empezar el canary, baja el TTL para que los cambios propaguen rápido:

```bash
aws route53 change-resource-record-sets \
  --hosted-zone-id Z123ABC \
  --change-batch file://manifests/04-migration/dns-prepare-lower-ttl.json
```

Y espera 24h (o el TTL anterior) antes del primer canary.
