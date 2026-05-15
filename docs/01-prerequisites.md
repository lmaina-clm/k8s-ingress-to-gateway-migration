# 01 — Prerequisitos

Antes de empezar la migración, valida que tu entorno cumple con lo siguiente. Si algo falla, **detente y resuélvelo** — intentar migrar con prerequisitos incompletos es la causa #1 de problemas en producción.

## 1. Clúster Kubernetes

### Versión mínima

- **Kubernetes 1.25+** (NGINX Gateway Fabric 2.x requiere 1.25 como mínimo).
- Recomendado: **1.30+** para tener Gateway API v1.5 sin parches.

Verifica:

```bash
kubectl version --short
```

### Permisos

Necesitas `cluster-admin` para:
- Instalar CRDs de Gateway API.
- Crear `GatewayClass` (cluster-scoped).
- Crear el namespace y RBAC del controller.

Para operaciones del día a día (crear `Gateway`, `HTTPRoute`), basta con permisos de namespace.

## 2. EKS específico

### IAM y networking

- **AWS Load Balancer Controller** instalado y funcionando. Sin él, los `Service` tipo `LoadBalancer` no provisionan NLBs correctamente.
  ```bash
  kubectl -n kube-system get deploy aws-load-balancer-controller
  ```
- **VPC con subnets etiquetadas** correctamente:
  - Subnets públicas: `kubernetes.io/role/elb: 1`
  - Subnets privadas: `kubernetes.io/role/internal-elb: 1`
- **Security Groups** que permitan tráfico desde el NLB hacia los nodos (puertos 80/443 al menos).

### Quotas

NGINX Gateway Fabric crea **un NLB adicional** durante la migración. Verifica que tu cuenta tenga cuota para al menos un NLB extra en la región:

```bash
aws service-quotas get-service-quota \
  --service-code elasticloadbalancing \
  --quota-code L-69A177A2 \
  --region <tu-región>
```

## 3. Herramientas locales

```bash
# Versiones probadas
kubectl version --client     # >= 1.30
helm version                  # >= 3.14
aws --version                 # >= 2.15
jq --version                  # >= 1.6
```

Opcionales pero recomendadas:
- `kubectx` / `kubens` — para no equivocarte de clúster en el momento incorrecto.
- `stern` — para tail de logs multi-pod durante validación.
- `k9s` — UI de terminal para inspección rápida.

## 4. DNS

Necesitas control sobre el dominio que apunta a la API. Los escenarios soportados:

### Escenario A — Route 53 (recomendado)

- Zona hospedada en Route 53.
- Permisos IAM para crear/modificar records.
- Habilitarás **weighted routing** para el canary.

### Escenario B — DNS externo (Cloudflare, NS1, etc.)

- Funciona igual, pero necesitarás un mecanismo equivalente de weighted/percentage routing.
- Si tu DNS no soporta weighted routing, hay un fallback con dos hostnames distintos documentado en `05-zero-downtime.md`.

### Escenario C — ExternalDNS automatizado

Si usas `external-dns` con anotaciones en los `Ingress`, ojo: tendrás que **deshabilitarlo temporalmente** o configurar `external-dns` para que también gestione recursos `Gateway` (soportado desde v0.14).

## 5. Observabilidad

**No migres sin observabilidad funcional.** Mínimo necesario:

- **Métricas del Ingress actual** (latencia, error rate, RPS) — para tener baseline.
- **Logs accesibles** del ingress-nginx-controller — para diagnosticar si algo se desvía.
- **Alertas activas** sobre el endpoint público — para detectar degradación durante el cutover.

Si usas Prometheus, los dashboards típicos de `ingress-nginx` que necesitas tener funcionando:
- Request rate por host/path
- p50/p95/p99 latency
- 4xx/5xx rate
- Upstream response time

Habrá que replicarlos para NGINX Gateway Fabric **antes** del cutover — los nombres de métricas cambian. Ver `07-troubleshooting.md` sección "Observabilidad".

## 6. Aplicación

Validaciones específicas de la aplicación que vas a migrar (no la demo, sino la real):

- [ ] ¿Usa anotaciones de `ingress-nginx`? Lista cuáles. Algunas tienen equivalente directo en Gateway API, otras requieren `NginxProxy` o policies custom de NGF. Ver `03-ingress-vs-gateway.md` tabla de mapeo.
- [ ] ¿Usa rewrites de path? Gateway API los soporta nativamente vía `URLRewrite` filter — distinto a la anotación `nginx.ingress.kubernetes.io/rewrite-target`.
- [ ] ¿Usa autenticación a nivel de Ingress (`auth-url`, `auth-snippet`)? Esto requiere policies custom o un sidecar — planifica antes.
- [ ] ¿Tiene websockets o gRPC streaming? Soportado, pero requiere consideración especial en el cutover.
- [ ] ¿Termina TLS en el Ingress? Anota dónde están los `Secret`s con certificados; los vas a referenciar desde el `Gateway`.
- [ ] ¿Usa client-cert / mTLS? Soportado en NGF 2.6+ vía `FrontendTLS`, pero la sintaxis es distinta.

## 7. Ventana de mantenimiento

Aunque el plan es zero-downtime, **planifica una ventana** de todas formas:
- Mínimo 2 horas para el cutover.
- Idealmente fuera del peak de tráfico.
- Con dos personas mínimo: una ejecuta, otra observa métricas y tiene el rollback listo.

## Checklist final

Antes de continuar al siguiente documento, marca todo:

- [ ] Clúster Kubernetes 1.25+ accesible con `cluster-admin`.
- [ ] AWS Load Balancer Controller funcionando.
- [ ] Cuota AWS para 1 NLB adicional.
- [ ] Herramientas locales instaladas (kubectl, helm, aws, jq).
- [ ] Control sobre DNS del endpoint público.
- [ ] Observabilidad: métricas, logs, alertas funcionando contra el Ingress actual.
- [ ] Inventario completo de anotaciones y features especiales del Ingress actual.
- [ ] Ventana de mantenimiento agendada (incluso si esperamos no usarla).
- [ ] Rollback plan revisado por al menos otra persona del equipo.

✅ Si todo está marcado → continúa a [`02-architecture.md`](./02-architecture.md).
