# 09 — Runbook de validación rápida (modo demo, sin dominio real)

Este runbook valida la migración completa **ingress-nginx → NGINX Gateway Fabric** en un cluster EKS efímero, en ~45 min de trabajo activo, sin necesidad de un dominio real.

> **No es** un sustituto del runbook de producción ([04-migration-runbook.md](./04-migration-runbook.md)). Es la versión "smoke test" para ver el patrón funcionando end-to-end antes de aplicarlo en un cluster real.

## Diferencias vs. el runbook de producción

| Aspecto | Producción | Demo (este runbook) |
|---------|-----------|---------------------|
| Cluster | EKS existente | EKS efímero recién creado |
| Dominio | Real, con DNS público | `shop.example.com` resuelto vía `curl --resolve` |
| TLS | Cert real (cert-manager o ACM) | Auto-firmado generado al vuelo |
| Canary DNS | Route 53 weighted, esperas de 30 min – 4h entre fases | Saltada — validamos los dos NLBs en paralelo con `curl` |
| Tráfico | Real de usuarios | `loadgenerator` interno + curls manuales |
| Observación | Dashboards en Grafana, alertas | `kubectl get` + logs |
| Duración total | 3-5 días | ~45 min activos |
| Costo | N/A (cluster existente) | ~$0.50-2 USD (1-3h de cluster en eu-west-1) |

## Prerequisitos

En tu máquina local:
- `aws` CLI v2, autenticada (`aws sts get-caller-identity` debe funcionar)
- `eksctl` ≥ 0.190 ([instalación](https://eksctl.io/installation/))
- `kubectl` ≥ 1.30
- `helm` ≥ 3.14
- `jq`, `curl`, `openssl`, `dig` (estándar en macOS/Linux)

Permisos AWS necesarios (resumen): `eks:*`, `iam:*` (limitado a roles/policies de IRSA), `ec2:*` (VPC/subnets/SG), `elasticloadbalancing:*`, `cloudformation:*`. Si tienes `AdministratorAccess`, cubre todo.

---

## Fase 0 — Preflight (~1 min, gratis)

```bash
# Verifica credenciales y región
export REGION=eu-west-1
export CLUSTER_NAME=ingress-gw-demo

aws sts get-caller-identity
aws ec2 describe-availability-zones --region $REGION --query 'AvailabilityZones[].ZoneName'
```

**Criterio de éxito**: ves tu account ID y al menos 3 AZs.

---

## Fase 1 — Crear el cluster EKS (~15 min, empieza el costo)

```bash
./scripts/setup-eks-demo-cluster.sh
```

Esto crea:
- Cluster EKS 1.32 con OIDC habilitado
- 2 nodos t3.medium en un managed nodegroup
- AWS Load Balancer Controller con IRSA

**Costo aproximado**: $0.10/h control plane + $0.09/h nodos (2× t3.medium en eu-west-1) ≈ $0.19/h.

**Criterio de éxito**:
```bash
kubectl get nodes
# 2 nodos en Ready
kubectl -n kube-system get deploy aws-load-balancer-controller
# AVAILABLE 1/1 (o 2/2 dependiendo de réplicas)
```

---

## Fase 2 — Desplegar Online Boutique (~3 min)

```bash
kubectl apply -f manifests/00-base/
kubectl apply -k manifests/01-microservices/

# Esperar a que todo esté Ready
kubectl -n microservices wait --for=condition=Ready pod --all --timeout=300s
```

**Criterio de éxito**: todos los pods en `Running` y `1/1 Ready`. Tarda 3-5 min por las dependencias entre servicios.

```bash
kubectl -n microservices get pods
```

---

## Fase 3 — Generar cert auto-firmado y crear el Secret

Como no tenemos un dominio real, generamos un cert auto-firmado para `shop.example.com` y lo metemos como Secret en los dos namespaces que lo necesitan.

```bash
# Generar par cert+key
openssl req -x509 -newkey rsa:2048 -nodes -days 1 \
  -keyout /tmp/shop.key \
  -out /tmp/shop.crt \
  -subj "/CN=shop.example.com" \
  -addext "subjectAltName=DNS:shop.example.com"

# Crear Secret en namespace de la app (lo usa el Ingress)
kubectl -n microservices create secret tls shop-tls \
  --cert=/tmp/shop.crt --key=/tmp/shop.key

# Crear el namespace gateway-system primero si no existe
kubectl get ns gateway-system >/dev/null 2>&1 || kubectl create ns gateway-system

# Copiar el Secret a gateway-system (lo usa el Gateway)
kubectl -n microservices get secret shop-tls -o yaml \
  | sed 's/namespace: microservices/namespace: gateway-system/' \
  | kubectl apply -f -

# Limpiar archivos temporales
rm -f /tmp/shop.key /tmp/shop.crt
```

**Criterio de éxito**:
```bash
kubectl get secret shop-tls -n microservices
kubectl get secret shop-tls -n gateway-system
# Ambos deben existir
```

---

## Fase 4 — Estado inicial: instalar ingress-nginx + aplicar Ingress (~5 min)

```bash
SKIP_CONFIRM=1 ./scripts/install-ingress-nginx.sh

# Aplicar el Ingress
kubectl apply -f manifests/02-ingress-nginx/

# Obtener el NLB del Ingress (puede tardar 1-2 min en aparecer)
until [ -n "$(kubectl -n ingress-nginx get svc ingress-nginx-controller \
                -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null)" ]; do
  echo "Esperando NLB del Ingress..."; sleep 10
done

export INGRESS_NLB=$(kubectl -n ingress-nginx get svc ingress-nginx-controller \
  -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')
echo "INGRESS_NLB=$INGRESS_NLB"
```

**Criterio de éxito**:
```bash
kubectl get ingress -n microservices
# Debe mostrar el Ingress con HOSTS=shop.example.com
```

---

## Fase 5 — Validar tráfico contra el Ingress (~2 min)

```bash
./scripts/validate-traffic.sh ingress
```

**Criterio de éxito**: todos los paths devuelven `200` o `301/302` (los redirects de HTTP → HTTPS son esperados).

> Si ves `301` en algunos paths, perfecto — significa que `force-ssl-redirect` está funcionando. La validación está siguiendo el flujo correcto.

---

## Fase 6 — Instalar Gateway API + NGF (~3 min)

```bash
SKIP_CONFIRM=1 ./scripts/install-nginx-gateway-fabric.sh
```

**Criterio de éxito**:
```bash
kubectl get crd | grep gateway.networking.k8s.io
# Debe mostrar 5+ CRDs

kubectl get gatewayclass nginx-gateway
# ACCEPTED=True
```

---

## Fase 7 — Aplicar Gateway + HTTPRoutes (~3 min)

```bash
kubectl apply -f manifests/03-gateway-api/

# Esperar a que el Gateway esté Programmed (NGF crea el NLB)
kubectl wait --for=condition=Programmed gateway/boutique-gateway \
  -n gateway-system --timeout=300s

# Obtener el NLB del Gateway
export GATEWAY_NLB=$(kubectl -n gateway-system get svc \
  -l gateway.nginx.org/gateway=boutique-gateway \
  -o jsonpath='{.items[0].status.loadBalancer.ingress[0].hostname}')
echo "GATEWAY_NLB=$GATEWAY_NLB"
```

**Criterio de éxito**:
```bash
kubectl get gateway -n gateway-system
# PROGRAMMED=True

kubectl get httproute -n microservices
# ACCEPTED=True para los dos HTTPRoutes
```

---

## Fase 8 — Validar tráfico contra el Gateway (~2 min)

```bash
./scripts/validate-traffic.sh gateway
```

**Criterio de éxito**: mismo comportamiento que con el Ingress — `200` o `301/302` en todos los paths.

---

## Fase 9 — Comparar ambos endpoints en paralelo (~2 min)

Esta es la fase clave: ambos NLBs deben servir lo mismo.

```bash
./scripts/validate-traffic.sh both

# Si tienes scripts/compare-responses.sh (revisa el código antes de correrlo):
./scripts/compare-responses.sh
```

**Criterio de éxito**:
- Mismos status codes en ambos NLBs
- Latencias en el mismo orden de magnitud
- Diferencias solo en headers volátiles (`Date`, `X-Request-Id`)

---

## Fase 10 — Simulación de cutover sin DNS (~2 min)

En producción aquí cambiaríamos Route 53. En la demo simplemente "decretamos" que el Gateway es el activo y borramos el Ingress:

```bash
# Borrar el Ingress (el Gateway sigue sirviendo)
kubectl delete -f manifests/02-ingress-nginx/ingress.yaml

# Validar que el Gateway sigue funcionando
./scripts/validate-traffic.sh gateway

# Verificar que el Ingress se fue
kubectl get ingress -n microservices
# No resources found
```

**Criterio de éxito**: el Gateway sigue respondiendo con `200`/`301`, y `kubectl get ingress` no devuelve nada.

---

## Fase 11 — Desinstalar ingress-nginx (~2 min)

```bash
helm uninstall ingress-nginx -n ingress-nginx
kubectl delete namespace ingress-nginx

# El NLB del Ingress se destruye automáticamente
# Validar que el Gateway sigue funcionando
./scripts/validate-traffic.sh gateway
```

**Criterio de éxito**: solo queda 1 NLB en AWS (el del Gateway). El servicio sigue 100% funcional.

```bash
aws elbv2 describe-load-balancers --region $REGION \
  --query 'LoadBalancers[].LoadBalancerName' --output table
# Debe quedar 1 NLB (o ninguno si NGF aún no ha provisionado)
```

---

## Fase 12 — Teardown (~10 min, detiene el costo)

```bash
./scripts/teardown-eks-demo-cluster.sh --confirm
```

Esto borra:
1. Services LoadBalancer del cluster (= destruye los NLBs en AWS)
2. El cluster EKS y toda su VPC
3. IAM policy del LB Controller

**Criterio de éxito**: el script termina con "Teardown completo" y no reporta recursos residuales.

> Si el script reporta "NLBs residuales" o "stacks de CloudFormation residuales", bórralos manualmente — son raros pero pueden quedar si algún Service LoadBalancer fue creado fuera de tu visibilidad.

---

## Checklist completo

- [ ] **Fase 0**: preflight OK
- [ ] **Fase 1**: cluster creado, AWS LB Controller corriendo
- [ ] **Fase 2**: Online Boutique desplegada, todos los pods Ready
- [ ] **Fase 3**: Secret `shop-tls` creado en `microservices` y `gateway-system`
- [ ] **Fase 4**: ingress-nginx instalado, Ingress aplicado, NLB asignado
- [ ] **Fase 5**: validate-traffic.sh ingress pasa
- [ ] **Fase 6**: Gateway API CRDs + NGF instalados
- [ ] **Fase 7**: Gateway Programmed=True, HTTPRoutes Accepted=True, segundo NLB asignado
- [ ] **Fase 8**: validate-traffic.sh gateway pasa
- [ ] **Fase 9**: ambos NLBs sirven respuestas equivalentes
- [ ] **Fase 10**: Ingress borrado, Gateway sigue sirviendo
- [ ] **Fase 11**: ingress-nginx desinstalado, NLB viejo destruido
- [ ] **Fase 12**: teardown completo, sin recursos residuales

---

## Troubleshooting rápido

| Síntoma | Causa típica | Solución |
|---------|--------------|----------|
| NLB no aparece después de 5 min | AWS LB Controller no corriendo o sin permisos | `kubectl logs -n kube-system deploy/aws-load-balancer-controller` |
| Pods de Online Boutique en `Pending` | Recursos insuficientes en 2 t3.medium | Aumentar a 3 nodos: `eksctl scale nodegroup ...` |
| `Gateway` queda en `Programmed=False` | Secret `shop-tls` no existe en `gateway-system` | Reaplica la Fase 3 |
| `curl` devuelve `SSL: no alternative certificate subject name matches` | Usaste `-k` mal o el cert se hizo para otro CN | El `--resolve` debe usar `shop.example.com:443:<IP>`, no el hostname del NLB |
| Teardown falla con "DependencyViolation" | NLBs no se borraron antes que la VPC | Borra manualmente los NLBs en la consola y reintenta |

---

## Lo que NO validamos en este modo rápido

Sé honesto sobre los gaps respecto a una migración real:

- **Comportamiento de DNS bajo carga y TTL** — la fase canary del runbook de producción no se ejerce aquí. Los tiempos de propagación y el comportamiento de clientes con caché DNS no se observan.
- **Diferencias semánticas con tráfico real** — `loadgenerator` cubre el flujo principal, pero no edge cases de tu aplicación real.
- **Performance bajo carga sostenida** — el test es de minutos, no de horas. Memory leaks o degradación lenta no se detectarían.
- **Rollback bajo presión** — el script de rollback funciona, pero no se prueba el componente humano de "qué hace el on-call a las 3am".

Para validar todo eso, **necesitas un staging environment con tráfico realista**, no este modo.

---

## Costo total esperado

En eu-west-1, para una sesión de 2-3 horas:

| Recurso | Costo/hora | Tiempo total | Subtotal |
|---------|-----------|--------------|----------|
| EKS control plane | $0.10 | 2-3h | $0.20-0.30 |
| 2× t3.medium nodes | $0.091 | 2-3h | $0.18-0.27 |
| 1-2 NLBs | $0.025-0.050 | 2h promedio | $0.05-0.10 |
| EBS gp3 (2× 30GB) | ~$0.005 | 2-3h | $0.02 |
| Misc (CloudWatch, ENI) | ~$0.01 | 2-3h | $0.05 |
| **TOTAL** | | | **$0.50-0.75** |

Costo a 4h: ~$1. A 8h: ~$2. La regla de oro: **corre el teardown apenas termines**.
