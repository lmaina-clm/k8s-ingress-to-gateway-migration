# 06 — Plan de Rollback

> Un plan de migración sin plan de rollback no es un plan, es una apuesta.

Este documento detalla **qué hacer si las cosas van mal** en cada fase. Está pensado para ejecutarse bajo presión: usa los comandos exactos, no improvises.

## Principios

1. **Rollback rápido > rollback elegante.** Si dudas, revierte.
2. **Documenta la decisión.** Por qué reverter, qué se observó. Te servirá para el siguiente intento.
3. **No reviertas solo.** Avisa al equipo antes de tocar producción.
4. **Mantén Git como fuente de verdad.** Si no está en Git, no existe el estado al que volver.

## Matriz de rollback por fase

| Fase | ¿Reversible? | Tiempo | Impacto en usuarios |
|------|--------------|--------|---------------------|
| 1. Baseline | ✅ Trivial (nada cambió) | 0 min | 0 |
| 2. Instalar NGF | ✅ Limpio | 5 min | 0 |
| 3. Configurar Gateway | ✅ Limpio | 5 min | 0 |
| 4. Validar paralelo | ✅ Limpio | 5 min | 0 |
| 5. Canary DNS 10% | ✅ Rápido (vía DNS) | 1-2 min + TTL | ~10% de usuarios afectados durante TTL |
| 6. Promoción gradual | ✅ Rápido (vía DNS) | 1-2 min + TTL | % igual al peso del canary |
| 7. Drenar Ingress | ⚠️ Aún reversible | 5 min + TTL | Bajo, pero los usuarios con nuevas conexiones al Gateway pueden ver inconsistencia |
| 8. Decomisionar | ❌ Costoso | 15-30 min | Posible downtime mientras se reinstala |

## Rollback FASE 2 — NGF instalado

**Síntoma típico**: NGF no arranca, CRDs conflictan con algo existente, GatewayClass no se acepta.

```bash
# 1. Desinstalar NGF
helm uninstall ngf -n nginx-gateway

# 2. Eliminar CRDs de Gateway API (CUIDADO si tienes otras apps que las usen)
kubectl delete -f https://github.com/kubernetes-sigs/gateway-api/releases/download/v1.5.1/standard-install.yaml

# 3. Eliminar namespaces
kubectl delete namespace nginx-gateway gateway-system 2>/dev/null

# 4. Validar
kubectl get gatewayclass    # debe estar vacío
kubectl get crd | grep gateway.networking.k8s.io   # debe estar vacío
```

**Validación post-rollback**: el tráfico vía `ingress-nginx` debe seguir intacto. Ejecutar `./scripts/validate-traffic.sh ingress`.

## Rollback FASE 3 — Gateway creado

**Síntoma típico**: el `Gateway` no llega a `Programmed`, NLB no se crea, errores en logs del control-plane.

```bash
# 1. Eliminar HTTPRoutes y Gateway
kubectl delete -f manifests/03-gateway-api/

# 2. Verificar que el NLB fue destruido
aws elbv2 describe-load-balancers --region <region> \
  --query "LoadBalancers[?contains(LoadBalancerName,'k8s-gateway')]"
# La lista debe estar vacía (puede tardar 1-2 min)

# 3. Conservar los CRDs y NGF instalados; el problema está en los recursos, no en el controller
```

**Validación**: NLB del Gateway destruido en AWS. El de `ingress-nginx` sigue intacto.

## Rollback FASE 4 — Validación paralela

Aquí solo hiciste curls. Si encontraste problemas:

- **Si el problema es semántico** (responses distintas entre Ingress y Gateway): corregir los `HTTPRoute` o anotaciones, **no revertir todavía**.
- **Si el problema es del controller** (5xx, latencia alta): reverter como fase 3.

## Rollback FASE 5 — Canary 10% activo

**El más importante**. Aquí estás impactando usuarios reales.

### Trigger inmediato (sin pensar)

- Error rate al NLB nuevo > 1% por más de 30 segundos.
- Latencia p99 al NLB nuevo > 3x baseline.
- Alertas en cascada en servicios downstream.

### Comando de pánico

```bash
# DNS de vuelta al 100% Ingress
aws route53 change-resource-record-sets \
  --hosted-zone-id $HOSTED_ZONE_ID \
  --change-batch file://manifests/04-migration/dns-rollback-100pct-ingress.json

# Mientras DNS propaga (60s con TTL bajo), opcionalmente baja a 0 las replicas del data-plane
kubectl scale deployment -n gateway-system nginx-boutique-gateway --replicas=0
```

### Comunicación

```
🚨 Migration rollback activated
- Time: <timestamp>
- Phase: 5 (canary 10%)
- Reason: <error rate spike | latency | unknown>
- DNS reverted: yes
- ETA back to baseline: ~60s (DNS TTL)
- Next action: <root cause analysis | retry | postmortem>
```

Notificar canal de incidentes / on-call channel.

### Validación post-rollback

```bash
# 1. DNS revertido
dig +short shop.example.com

# 2. Tráfico volviendo al Ingress viejo
kubectl logs -n ingress-nginx -l app.kubernetes.io/component=controller --tail=20

# 3. Error rate normalizado
./scripts/validate-traffic.sh ingress
```

## Rollback FASE 6 — Promoción gradual

Idéntico a fase 5, pero el peso a restaurar es el del **paso anterior**, no el 0%.

```bash
# Ej: estabas al 75% y quieres volver al 50%
aws route53 change-resource-record-sets \
  --hosted-zone-id $HOSTED_ZONE_ID \
  --change-batch file://manifests/04-migration/dns-canary-50pct.json
```

Si los problemas son severos, **ve directo al 0% Gateway** (rollback total).

## Rollback FASE 7 — Ingress drenando

Todavía es reversible **siempre que no hayas decomisionado el controller**.

```bash
# DNS de vuelta al Ingress
aws route53 change-resource-record-sets \
  --hosted-zone-id $HOSTED_ZONE_ID \
  --change-batch file://manifests/04-migration/dns-rollback-100pct-ingress.json
```

Pero ojo: los clientes que ya conectaron al Gateway pueden tener **estado** (cookies de sesión emitidas por la app, no por el ingress). Si vuelven al Ingress viejo, **deberían** seguir funcionando (porque el estado lo maneja la app, no el ingress) — **pero esto debes validarlo en tu caso específico**. Si tu app usa cookies firmadas con secret específico al pod, esto es un problema independiente.

## Rollback FASE 8 — Después de decomisionar

Aquí el rollback es **costoso**. Pasos:

### 1. Reinstalar `ingress-nginx`

```bash
# Volver a aplicar la instalación
./scripts/install-ingress-nginx.sh
```

Esperar ~5 min a que el controller esté Ready y el NLB se cree.

### 2. Reaplicar Ingress objects

```bash
kubectl apply -f manifests/02-ingress-nginx/ingress.yaml
```

### 3. Obtener el hostname del nuevo NLB

```bash
INGRESS_NLB=$(kubectl get svc -n ingress-nginx ingress-nginx-controller \
  -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')
echo "Nuevo Ingress NLB: $INGRESS_NLB"
```

### 4. Cambiar DNS

```bash
# Editar manifests/04-migration/dns-rollback-100pct-ingress.json
# con el nuevo hostname y aplicar
```

### 5. Esperar propagación

Con TTL=60s, ~5 min de degradación parcial mientras DNS propaga.

**Impacto total estimado del rollback en esta fase**: 10-15 minutos donde un % del tráfico verá errores intermitentes.

## Cómo decidir reverter vs seguir adelante

Cuadro de decisión rápido:

| Síntoma | Decisión |
|---------|----------|
| Error rate > 1% sostenido > 1 min | **Revertir inmediato** |
| Error rate < 1% pero peor que baseline | Esperar 5 min. Si persiste, revertir. |
| Latencia p99 > 2x baseline sostenido | **Revertir inmediato** |
| Latencia p99 ~1.5x baseline | Probable problema esperable (NGF tarda en optimizarse). Esperar 10 min. |
| Errores aislados en un endpoint específico | NO revertir el cambio entero. Investigar config del `HTTPRoute` específico. |
| Cliente B2B se queja | Investigar — puede ser issue suyo (DNS hardcoded), no nuestro. |
| Alerta de servicio downstream | Probable correlación, no causalidad. Investigar antes de revertir. |
| "Algo se siente raro" | Esperar 5 min. Si la sensación persiste, revertir. La intuición de SREs es señal. |

## Script de rollback completo

`scripts/rollback.sh` automatiza el rollback más comun (DNS al 100% Ingress). Pero **lee el script antes de usarlo en pánico** — entiende qué hace.

```bash
./scripts/rollback.sh --to ingress --hosted-zone-id Z123ABC --confirm
```

El `--confirm` es obligatorio para evitar accidentes.

---

Siguiente: [`07-troubleshooting.md`](./07-troubleshooting.md) — problemas comunes y diagnóstico.
