# 07 — Troubleshooting

Problemas que vas a encontrar (o que ya encontraste y por eso estás leyendo esto).

## Diagnóstico general

Antes de buscar tu problema específico, **siempre** ejecuta:

```bash
# 1. ¿Los CRDs están?
kubectl get crd | grep gateway.networking.k8s.io

# 2. ¿El control plane está sano?
kubectl get pods -n nginx-gateway

# 3. ¿El GatewayClass está aceptado?
kubectl describe gatewayclass nginx | grep -A5 Conditions

# 4. ¿El Gateway está programado?
kubectl describe gateway -n gateway-system boutique-gateway

# 5. ¿Los HTTPRoutes están aceptados?
kubectl get httproute -A -o wide
kubectl describe httproute -n microservices boutique-route

# 6. ¿El data plane está corriendo?
kubectl get pods -n gateway-system

# 7. Logs del control plane
kubectl logs -n nginx-gateway -l app.kubernetes.io/name=nginx-gateway-fabric --tail=50

# 8. Logs del data plane (NGINX)
kubectl logs -n gateway-system -l gateway.nginx.org/gateway=boutique-gateway --tail=50
```

El 80% de los problemas se detectan con uno de estos comandos.

## Problemas comunes

### El `Gateway` se queda en `Programmed=False`

**Síntomas**:
```
NAME                CLASS   ADDRESS   PROGRAMMED   AGE
boutique-gateway    nginx             False        5m
```

**Causas y soluciones**:

1. **No hay GatewayClass**:
   ```bash
   kubectl get gatewayclass nginx
   ```
   Si está vacío, NGF no está instalado. Volver a fase 2.

2. **Secret TLS no existe en el namespace correcto**:
   ```bash
   kubectl get secret -n gateway-system shop-tls
   ```
   Solución: copiar el secret al namespace del Gateway, o usar `ReferenceGrant` para permitir referencia cross-namespace.

3. **Conflicto de hostnames con otro Gateway**:
   ```bash
   kubectl get gateway -A
   ```
   Si dos Gateways comparten el mismo hostname, NGF rechaza uno.

4. **AWS Load Balancer Controller no responde**:
   ```bash
   kubectl logs -n kube-system deployment/aws-load-balancer-controller --tail=50
   ```
   Si hay errores de IAM o subnets, el NLB no se crea.

### `HTTPRoute` con `Accepted=False`

**Síntomas**:
```bash
kubectl describe httproute boutique-route -n microservices
# Conditions: Accepted=False
```

**Causa común**: el `parentRef` apunta a un Gateway que no existe o que no permite routes desde ese namespace.

```yaml
# En el Gateway, revisar:
spec:
  listeners:
    - name: https
      allowedRoutes:
        namespaces:
          from: Selector
          selector:
            matchLabels:
              gateway-access: "true"
```

Tu namespace `microservices` debe tener el label:

```bash
kubectl label namespace microservices gateway-access=true
```

### `HTTPRoute` con `ResolvedRefs=False`

**Causa**: el `backendRef` apunta a un servicio que no existe o está en otro namespace sin `ReferenceGrant`.

```bash
kubectl get service -n microservices frontend
kubectl describe httproute boutique-route -n microservices | grep -A3 ResolvedRefs
```

### Tráfico llega al Gateway pero responde 502/503

**Síntomas**: `curl` al NLB → status 502.

**Diagnóstico**:

```bash
# 1. Ver logs del NGINX data plane
kubectl logs -n gateway-system -l gateway.nginx.org/gateway=boutique-gateway --tail=100

# 2. Ver endpoints del Service backend
kubectl get endpoints -n microservices frontend
# Si "ENDPOINTS" está vacío: el Service no tiene pods. Problema en el deployment.

# 3. Verificar que el pod del data plane puede alcanzar el pod del backend
kubectl exec -n gateway-system <data-plane-pod> -- \
  curl -v http://frontend.microservices.svc.cluster.local
```

Causas típicas:
- **NetworkPolicy restrictiva**: bloquea tráfico desde `gateway-system` hacia `microservices`. Agregar `NetworkPolicy` que lo permita.
- **Service en puerto distinto**: el `HTTPRoute` apunta a `port: 80` pero el Service expone `port: 8080`.
- **Backend caído**: el pod del frontend está crash-looping.

### Tráfico llega al NLB del Gateway pero no al pod

**Diagnóstico**:

```bash
# ¿El NLB tiene target healthy?
TG_ARN=$(aws elbv2 describe-target-groups --region <region> \
  --load-balancer-arn $(aws elbv2 describe-load-balancers --region <region> \
    --query "LoadBalancers[?contains(LoadBalancerName,'k8s-gateway')].LoadBalancerArn" \
    --output text) \
  --query 'TargetGroups[0].TargetGroupArn' --output text)

aws elbv2 describe-target-health --target-group-arn $TG_ARN --region <region>
```

Si los targets están `unhealthy`:
- **Security Group del NLB no permite tráfico al puerto del nodeport/pod**.
- **Health check del target group apunta a un path que devuelve 404**.

### `502 Bad Gateway` intermitente solo en tráfico real (no en `curl`)

Típicamente: **upstream keepalive timeout**. NGINX cierra una conexión persistente, pero el cliente intenta reusar.

**Solución**: configurar el `ClientSettingsPolicy` o el `NginxProxy` con timeouts ajustados.

```yaml
apiVersion: gateway.nginx.org/v1alpha1
kind: NginxProxy
metadata:
  name: boutique-proxy
spec:
  ipFamily: dual
  telemetry:
    serviceName: boutique
  # Ajustar timeouts si los defaults no encajan
```

### `502` solo en POST con body grande

Causa: `client_max_body_size` por defecto en NGF es 1MB.

**Solución**:

```yaml
apiVersion: gateway.nginx.org/v1alpha1
kind: ClientSettingsPolicy
metadata:
  name: large-body
  namespace: gateway-system
spec:
  targetRef:
    group: gateway.networking.k8s.io
    kind: Gateway
    name: boutique-gateway
  body:
    maxSize: "10m"
```

### Latencia p99 más alta que con `ingress-nginx`

**Causas posibles**:

1. **NGF aún no tiene el cache calentado** — primeros minutos. Esperar.
2. **El NLB nuevo está en zonas de disponibilidad distintas que los pods**. Verificar:
   ```bash
   kubectl get svc -n gateway-system -o wide
   # Comparar las zonas con las de los pods backend
   ```
3. **Más hops**: NGF tiene control-plane separado del data-plane. Esto no afecta requests (no van por el control-plane), pero los TLS handshakes pueden ser ligeramente más lentos.
4. **Buffering distinto**: `proxy_buffering` en NGF puede tener defaults distintos. Ajustar con `ProxySettingsPolicy` si tienes streaming.

### El DNS no actualiza tras cambiar el weighted record

```bash
# Forzar resolución sin caché
dig +nocache shop.example.com

# Probar contra varios resolvers
dig @8.8.8.8 shop.example.com
dig @1.1.1.1 shop.example.com
```

Si Route 53 ya tiene el nuevo valor pero los clientes no lo ven: **caché DNS local** del cliente. Esperar TTL.

### `cert-manager` no emite cert para el Gateway

Si usas cert-manager < v1.14, **no entiende `Gateway` aún**. Upgrade a 1.14+.

Con cert-manager 1.14+:

```yaml
# El Certificate apunta al Secret que referenciará el Gateway
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: shop-tls
  namespace: gateway-system
spec:
  secretName: shop-tls
  dnsNames:
    - shop.example.com
  issuerRef:
    name: letsencrypt-prod
    kind: ClusterIssuer
```

Y referencias el secret en el `Gateway.spec.listeners[].tls.certificateRefs`.

## Observabilidad: nombres de métricas

Mapeo de métricas Prometheus de `ingress-nginx` a NGF:

| `ingress-nginx` | NGINX Gateway Fabric |
|-----------------|----------------------|
| `nginx_ingress_controller_requests` | `nginxplus_http_requests_total` (con NGINX Plus) o `nginx_http_requests_total` |
| `nginx_ingress_controller_request_duration_seconds_bucket` | `nginxplus_http_request_duration_seconds_bucket` |
| `nginx_ingress_controller_response_size_bucket` | `nginxplus_http_response_size_bytes_bucket` |
| `nginx_ingress_controller_nginx_process_*` | `nginx_process_*` |

Para tener métricas, NGF expone un endpoint Prometheus en el data plane. Configura tu `ServiceMonitor`:

```yaml
apiVersion: monitoring.coreos.com/v1
kind: ServiceMonitor
metadata:
  name: nginx-gateway-fabric
  namespace: gateway-system
spec:
  selector:
    matchLabels:
      gateway.nginx.org/gateway: boutique-gateway
  endpoints:
    - port: metrics
      interval: 30s
```

## Upgrade NGF 1.x → 2.x

Si por algún motivo tienes NGF 1.x ya instalado: el upgrade requiere desinstalación y reinstalación porque cambia el modelo de instalación (separación control/data plane es 2.x).

```bash
# 1. Backup completo
kubectl get gateway,httproute,grpcroute -A -o yaml > /tmp/ngf-backup.yaml

# 2. Desinstalar 1.x (mantiene CRDs)
helm uninstall nginx-gateway -n nginx-gateway

# 3. Instalar 2.6.x
./scripts/install-nginx-gateway-fabric.sh

# 4. Restaurar recursos
kubectl apply -f /tmp/ngf-backup.yaml
```

**Importante**: durante este upgrade hay **downtime** del Gateway. Por eso lo mejor es hacerlo antes de la migración productiva, no como parte de ella.

## TLS en el NLB (ACM en lugar del Gateway)

Si prefieres terminar TLS en el NLB con AWS ACM:

1. El listener del Gateway es **HTTP**, no HTTPS.
2. El NLB se configura con anotaciones del AWS Load Balancer Controller para terminar TLS.

```yaml
# En el Service del data plane (NGF lo crea, pero puedes overridelo via Helm values):
apiVersion: v1
kind: Service
metadata:
  annotations:
    service.beta.kubernetes.io/aws-load-balancer-ssl-cert: arn:aws:acm:...
    service.beta.kubernetes.io/aws-load-balancer-ssl-ports: "443"
    service.beta.kubernetes.io/aws-load-balancer-backend-protocol: tcp
```

Pros: ACM auto-renueva, integración con AWS WAF.
Contras: TLS termina en el NLB, así que el Gateway no ve el SNI ni puede hacer routing por hostname con cert distinto.

---

Siguiente: [`08-faq.md`](./08-faq.md)
