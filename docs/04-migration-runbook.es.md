[English](04-migration-runbook.md) | **Español**

# 04 — Runbook de migración

Este es el documento que ejecutas. Cada fase tiene **prerequisito**, **acciones**, **criterio de éxito** y **rollback inmediato**. No saltes fases.

> **Convención**: los comandos asumen que estás en la raíz del repo y tu `kubectl` apunta al clúster correcto. Verifica con `kubectl config current-context` **antes de cada comando**.

## Resumen visual del runbook

```
FASE 1: Baseline               ← Verificas que tu Ingress actual funciona
FASE 2: Instalar Gateway API   ← CRDs + NGINX Gateway Fabric (sin afectar tráfico)
FASE 3: Configurar Gateway     ← Gateway + HTTPRoutes (sin DNS todavía)
FASE 4: Validar paralelo       ← Curl con Host header al nuevo NLB
FASE 5: Canary DNS             ← Route 53 weighted, 10% al Gateway
FASE 6: Promover               ← Gradualmente 100% al Gateway
FASE 7: Drenar Ingress         ← TTL cumplido, sin tráfico residual
FASE 8: Decomisionar           ← Borrar ingress-nginx
```

Duración total estimada: **3-5 días** (la mayoría es ventana de observación, no trabajo activo).

---

## FASE 1: Baseline

**Objetivo**: documentar el estado actual y verificar que el Ingress funciona como esperamos.

### Prerequisito

- Todo el checklist de `01-prerequisites.es.md` completado.
- Tienes acceso a métricas y logs del `ingress-nginx-controller`.

### Acciones

1. **Snapshot de Ingress actuales**:
   ```bash
   kubectl get ingress -A -o yaml > /tmp/ingress-snapshot-$(date +%Y%m%d).yaml
   ```

2. **Snapshot de anotaciones especiales**:
   ```bash
   kubectl get ingress -A -o json | jq '.items[] | {name: .metadata.name, ns: .metadata.namespace, annotations: .metadata.annotations}' > /tmp/annotations-$(date +%Y%m%d).json
   ```
   Revisa este archivo. Cada anotación debe tener su equivalente en Gateway API (ver `03-ingress-vs-gateway.es.md`).

3. **Métricas baseline** (registra estos números, vas a compararlos):
   - RPS promedio (5 min y peak)
   - p50, p95, p99 latencia
   - Error rate (4xx, 5xx)
   - Top 10 endpoints por tráfico

4. **Smoke test**:
   ```bash
   ./scripts/validate-traffic.sh ingress
   ```
   Esto hace requests a los paths principales y reporta latencia/status. Guarda el output.

### Criterio de éxito

- [ ] Snapshot de Ingress capturado.
- [ ] Anotaciones documentadas con su plan de migración por cada una.
- [ ] Métricas baseline registradas.
- [ ] Smoke test pasa al 100%.

### Rollback

N/A — solo estás leyendo el estado.

---

## FASE 2: Instalar Gateway API y NGINX Gateway Fabric

**Objetivo**: instalar el nuevo controller **sin tocar nada del tráfico actual**.

### Prerequisito

- Fase 1 completa.
- AWS Load Balancer Controller funcionando.

### Acciones

1. **Instalar CRDs de Gateway API** (v1.5.1):
   ```bash
   kubectl apply -f https://github.com/kubernetes-sigs/gateway-api/releases/download/v1.5.1/standard-install.yaml
   ```

2. **Verificar CRDs**:
   ```bash
   kubectl get crd | grep gateway.networking.k8s.io
   ```
   Debes ver: `gateways`, `gatewayclasses`, `httproutes`, `grpcroutes`, `referencegrants`.

3. **Instalar NGINX Gateway Fabric** vía Helm:
   ```bash
   ./scripts/install-nginx-gateway-fabric.sh
   ```
   El script:
   - Crea namespace `nginx-gateway`.
   - Instala NGF 2.6.x con valores opinionados para EKS.
   - Espera a que el control-plane esté `Ready`.

4. **Verificar control-plane**:
   ```bash
   kubectl get pods -n nginx-gateway
   kubectl get gatewayclass nginx-gateway
   ```
   `gatewayclass nginx-gateway` debe estar `ACCEPTED=True`.

5. **NO crear `Gateway` todavía.** Sin `Gateway`, NGF no crea data-plane ni NLB. Cero impacto.

### Criterio de éxito

- [ ] CRDs presentes (5 mínimo).
- [ ] NGF control-plane `Running`.
- [ ] `GatewayClass nginx-gateway` `ACCEPTED`.
- [ ] `kubectl get svc -A` NO muestra ningún NLB nuevo (todavía no se creó).
- [ ] Tráfico vía `ingress-nginx` sigue al 100%. `./scripts/validate-traffic.sh ingress` pasa.

### Rollback

```bash
helm uninstall ngf -n nginx-gateway
kubectl delete -f https://github.com/kubernetes-sigs/gateway-api/releases/download/v1.5.1/standard-install.yaml
kubectl delete namespace nginx-gateway
```

---

## FASE 3: Configurar Gateway y HTTPRoutes

**Objetivo**: crear los recursos Gateway API. Esto provisiona un **nuevo NLB en paralelo**, pero sin DNS público apuntando a él.

### Prerequisito

- Fase 2 completa.
- Tienes el `Secret` con el certificado TLS (puede ser el mismo que usa el Ingress actual).

### Acciones

1. **Crear namespace y ReferenceGrant**:
   ```bash
   kubectl apply -f manifests/00-base/
   ```

2. **Copiar el secret TLS al namespace `gateway-system`** (si no usas cert-manager):
   ```bash
   kubectl get secret shop-tls -n microservices -o yaml \
     | sed 's/namespace: microservices/namespace: gateway-system/' \
     | kubectl apply -f -
   ```
   Si usas **cert-manager**, crea el `Certificate` directamente en `gateway-system`:
   ```bash
   kubectl apply -f manifests/03-gateway-api/certificate.yaml
   ```

3. **Aplicar Gateway y HTTPRoutes**:
   ```bash
   kubectl apply -f manifests/03-gateway-api/
   ```

4. **Esperar a que el data-plane se provisione**:
   ```bash
   kubectl wait --for=condition=Programmed gateway/boutique-gateway \
     -n gateway-system --timeout=300s
   ```

5. **Obtener el hostname del NLB**:
   ```bash
   export GW_NLB=$(kubectl get svc -n gateway-system \
     -l gateway.networking.k8s.io/gateway-name=boutique-gateway \
     -o jsonpath='{.items[0].status.loadBalancer.ingress[0].hostname}')
   echo "Nuevo NLB: $GW_NLB"
   ```

### Criterio de éxito

- [ ] `kubectl get gateway -n gateway-system boutique-gateway` muestra `PROGRAMMED=True`.
- [ ] `kubectl get httproute -n microservices` — todas en `ACCEPTED=True` y `ResolvedRefs=True`.
- [ ] Existe un NLB nuevo (`$GW_NLB` no está vacío).
- [ ] El NLB viejo (ingress-nginx) sigue intacto y sirviendo tráfico.

### Rollback

```bash
kubectl delete -f manifests/03-gateway-api/
# El NLB nuevo se destruye automáticamente.
```

---

## FASE 4: Validar en paralelo (sin DNS)

**Objetivo**: validar que el nuevo Gateway sirve el tráfico correctamente, sin todavía exponerlo públicamente.

### Acciones

1. **Smoke test contra el NLB nuevo con `Host:` header**:
   ```bash
   ./scripts/validate-traffic.sh gateway $GW_NLB
   ```
   El script hace:
   ```bash
   curl -k --resolve shop.example.com:443:$(dig +short $GW_NLB | head -1) \
        https://shop.example.com/
   ```
   Esto te permite hablar con el nuevo NLB como si fuera el real, sin tocar DNS.

2. **Comparar respuestas entre los dos NLBs**:
   ```bash
   ./scripts/compare-responses.sh
   ```
   Hace el mismo request a ambos NLBs y compara:
   - Status code
   - Headers críticos (`Content-Type`, `Cache-Control`)
   - Body (con tolerancia a timestamps/IDs)

   **Resultado esperado**: 100% de matches. Si hay diferencias, revisa anotaciones que no se migraron correctamente.

3. **Test de carga ligero al nuevo NLB** (sin promocionar todavía):
   ```bash
   # 100 RPS por 60s, suficiente para validar que no hay problemas obvios
   hey -z 60s -c 10 -q 10 \
       -host shop.example.com \
       https://$GW_NLB/
   ```
   Métricas esperadas:
   - p95 latencia ≤ baseline + 20%
   - 0 errores 5xx

4. **Validar observabilidad del nuevo path**:
   - Métricas de NGF llegando a Prometheus.
   - Logs accesibles.
   - Las alertas que tienes sobre el viejo Ingress, ya replicadas para NGF (con los nombres de métricas nuevos).

### Criterio de éxito

- [ ] Smoke test pasa al 100% contra el nuevo NLB.
- [ ] Diff entre los dos NLBs: solo diferencias esperadas (request IDs, timestamps).
- [ ] Test de carga ligero sin errores.
- [ ] Métricas y logs de NGF visibles en tus dashboards.
- [ ] Alertas para el nuevo dataplane configuradas.

### Rollback

Idem fase 3. Esto es lo último que puedes deshacer sin riesgo.

---

## FASE 5: Canary DNS — 10%

**Objetivo**: empezar a enviar tráfico real al nuevo Gateway, pero solo una fracción pequeña.

> ⚠️ **A partir de aquí, los cambios son visibles a usuarios.** Ten observabilidad activa y rollback al teclado.

### Prerequisito

- Fase 4 completa con métricas estables.
- DNS basado en Route 53 (o equivalente con weighted routing).
- Ventana de mantenimiento anunciada (incluso si esperamos no necesitarla).
- Mínimo dos personas: una opera, otra observa.

### Acciones

1. **Cambiar el record DNS de `A` simple a weighted alias** (si no lo era ya):

   **Antes** (estado inicial):
   ```
   shop.example.com  →  ALIAS  →  <NLB-ingress-nginx>
   ```

   **Después** (weighted):
   ```
   shop.example.com  →  weighted, weight=90, id="ingress"  →  <NLB-ingress-nginx>
   shop.example.com  →  weighted, weight=10, id="gateway"  →  <NLB-gateway-fabric>
   ```

   Comando AWS CLI (asume zona hospedada `Z123ABC`):
   ```bash
   aws route53 change-resource-record-sets \
     --hosted-zone-id Z123ABC \
     --change-batch file://manifests/04-migration/dns-canary-10pct.json
   ```
   (ver archivo de ejemplo en `manifests/04-migration/`)

2. **Bajar TTL antes del cambio** (idealmente 24h antes):
   ```
   TTL: 60s
   ```
   Si tu TTL era 3600s, los DNS resolvers tendrán caché. Bajar el TTL **24 horas antes** garantiza que los cambios subsecuentes propaguen rápido.

3. **Observar durante 30 min mínimo**:
   - Error rate en ambos NLBs.
   - Latencia p95 en ambos NLBs.
   - Logs de errores en NGF data-plane.
   - Logs de errores en `ingress-nginx`.

   Si todo está estable: continúa a fase 6.

### Criterio de éxito

- [ ] Tráfico observable en NGF (~10% del total).
- [ ] Error rate en el nuevo NLB ≤ error rate baseline.
- [ ] Latencia p95 ≤ baseline + 20%.
- [ ] No hay errores en logs de NGF que sugieran problemas de routing.

### Rollback

**Rápido (recomendado si hay duda)**:
```bash
aws route53 change-resource-record-sets \
  --hosted-zone-id Z123ABC \
  --change-batch file://manifests/04-migration/dns-rollback-100pct-ingress.json
```
DNS revierte a 100% Ingress. Esperar TTL (60s) y los clientes vuelven al estado anterior.

---

## FASE 6: Promover gradualmente

**Objetivo**: subir el peso del Gateway en pasos controlados, verificando estabilidad en cada uno.

### Acciones

Repite el patrón fase 5 con estos pesos, esperando **mínimo 30 minutos** entre cambios (idealmente 2-4 horas en producción):

```
10% → 25% → 50% → 75% → 100%
```

En cada paso:

1. Aplica el cambio DNS (un archivo `.json` por paso en `manifests/04-migration/`).
2. Observa 30 min mínimo.
3. Valida criterios de éxito.
4. Continúa o haz rollback.

### Criterio de éxito por paso

- Mismo que fase 5, con tolerancias estables.
- **Atención especial al 50%**: es el punto donde más obvio será cualquier diferencia entre los dos controllers (sticky sessions rotas, headers diferentes, etc.).

### Rollback

A cualquier paso, aplicar el DNS del paso anterior. TTL bajo → propagación rápida.

---

## FASE 7: Drenar el Ingress

**Objetivo**: con 100% del tráfico nuevo en Gateway, esperar a que el Ingress drene las conexiones residuales.

### Acciones

1. **Con DNS al 100% en Gateway**, espera **mínimo 5 × TTL** del DNS.
   - Con TTL=60s → 5 min mínimo, recomendado 1 hora para conexiones long-lived.

2. **Verificar tráfico residual** en `ingress-nginx`:
   ```bash
   kubectl logs -n ingress-nginx -l app.kubernetes.io/component=controller \
     --tail=100 -f
   ```
   Si todavía ves requests, **no continúes**. Algún cliente tiene caché DNS larga o conexión persistente sin reconexión.

3. **Tráfico residual común y qué hacer**:
   - Bots con caché DNS hardcoded → ignorables, eventualmente se reconectan.
   - Clientes con TTL=0 honoreado mal → esperar más.
   - **Conexiones long-lived no reconectadas** → tu problema. Forzar reinicio del cliente o esperar.

### Criterio de éxito

- [ ] DNS al 100% en Gateway por mínimo 1 hora.
- [ ] Tráfico al NLB de `ingress-nginx` < 0.1% del total (o cero).
- [ ] No hay alertas activas relacionadas con el cambio.

### Rollback

Aún posible: revertir DNS. Pero con clientes nuevos ya conectados al Gateway, el rollback parcial puede causar inconsistencias de estado. **Decisión consciente con stakeholders.**

---

## FASE 8: Decomisionar `ingress-nginx`

**Objetivo**: limpiar. Una vez decomisionado, el rollback ya no es trivial.

### Prerequisito

- Fase 7 completa, mínimo 24 horas estable.
- Aprobación explícita del responsable del servicio.

### Acciones

1. **Borrar los Ingress** (esto NO destruye el controller todavía):
   ```bash
   kubectl delete -f manifests/02-ingress-nginx/ingress.yaml
   ```

2. **Esperar 30 minutos**. Si algo se rompe, restaurar:
   ```bash
   kubectl apply -f manifests/02-ingress-nginx/ingress.yaml
   ```
   Y revertir DNS. Es la última ventana razonable de rollback.

3. **Si todo OK, desinstalar `ingress-nginx`**:
   ```bash
   helm uninstall ingress-nginx -n ingress-nginx
   kubectl delete namespace ingress-nginx
   ```
   Esto destruye el NLB viejo automáticamente.

4. **Limpiar el DNS** — eliminar el weighted record que apuntaba al NLB viejo, dejar solo el del Gateway (o convertir a record simple sin weighted):
   ```bash
   aws route53 change-resource-record-sets \
     --hosted-zone-id Z123ABC \
     --change-batch file://manifests/04-migration/dns-final-state.json
   ```

5. **Subir TTL de vuelta** a tu valor normal (300s o más).

### Criterio de éxito

- [ ] `ingress-nginx` namespace eliminado.
- [ ] NLB viejo destruido (verificar en consola AWS).
- [ ] DNS limpio, sin records al NLB viejo.
- [ ] Servicio funcionando al 100% solo con Gateway API.
- [ ] Post-mortem o retrospectiva agendada.

---

## Post-migración

Tareas que **no son urgentes** pero hay que hacer:

- [ ] Actualizar runbooks operativos que mencionen `ingress-nginx`.
- [ ] Actualizar dashboards si quedan widgets antiguos.
- [ ] Revisar tu chart de Helm / Kustomize / GitOps para que use Gateway API por defecto en deploys futuros.
- [ ] Capacitar al equipo (este repo + sesión interna de Q&A).
- [ ] Documentar cualquier desvío del runbook estándar para futuras migraciones.

---

## Tiempos típicos

| Fase | Tiempo activo | Tiempo total (con observación) |
|------|---------------|-------------------------------|
| 1. Baseline | 1h | 1h |
| 2. Instalar NGF | 30 min | 1h |
| 3. Configurar Gateway | 30 min | 1h |
| 4. Validar paralelo | 1h | 4h (recomendado overnight si producción crítica) |
| 5. Canary 10% | 15 min | 30 min - 2h |
| 6. Promoción gradual | 1h | 1 día (con esperas entre pasos) |
| 7. Drenar Ingress | 15 min | 2-4h |
| 8. Decomisionar | 30 min | 24h (espera de seguridad antes de borrar) |
| **TOTAL** | **~5h** | **3-5 días** |

---

Siguiente: [`05-zero-downtime.es.md`](./05-zero-downtime.es.md) — análisis profundo de los riesgos de zero-downtime.
