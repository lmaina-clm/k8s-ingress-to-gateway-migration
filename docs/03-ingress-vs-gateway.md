# 03 — Ingress vs Gateway API: comparación conceptual y mapeo

Este documento es el de referencia rápida durante la migración. Si vienes de `ingress-nginx` y nunca tocaste Gateway API, **empieza aquí**.

## El cambio mental: separación de responsabilidades

`Ingress` mezcla en un solo objeto cosas que pertenecen a personas distintas:

- **Cómo se expone** el clúster (tipo de LB, certificados, listeners) — responsabilidad del equipo de plataforma.
- **Cómo se rutea** el tráfico a la aplicación — responsabilidad del equipo de aplicación.

Gateway API separa esto en **roles**:

```
┌────────────────────────────────────────────────────────────────┐
│  Rol: Infraestructura (Cloud provider)                         │
│  Recurso: GatewayClass                                         │
│  Define: "Soy un controller capaz de servir gateways".         │
└────────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌────────────────────────────────────────────────────────────────┐
│  Rol: Plataforma / SRE                                         │
│  Recurso: Gateway                                              │
│  Define: "Quiero un punto de entrada en :443 con este cert,    │
│           usando esta GatewayClass".                           │
└────────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌────────────────────────────────────────────────────────────────┐
│  Rol: Desarrollador de aplicación                              │
│  Recurso: HTTPRoute                                            │
│  Define: "Pega tu Gateway al servicio frontend cuando el       │
│           path empiece con /api/cart".                         │
└────────────────────────────────────────────────────────────────┘
```

En Ingress clásico, **todos editaban el mismo objeto**, lo que generaba conflictos y problemas de permisos. Gateway API permite que cada rol tenga RBAC propio.

## Comparación lado a lado

### Caso 1: Ingress simple

**Ingress clásico:**

```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: boutique
  namespace: microservices
  annotations:
    nginx.ingress.kubernetes.io/ssl-redirect: "true"
spec:
  ingressClassName: nginx
  tls:
    - hosts: [shop.example.com]
      secretName: shop-tls
  rules:
    - host: shop.example.com
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: frontend
                port:
                  number: 80
```

**Equivalente en Gateway API:**

```yaml
# El Gateway (vive en namespace de plataforma)
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  name: boutique-gateway
  namespace: gateway-system
spec:
  gatewayClassName: nginx
  listeners:
    - name: https
      protocol: HTTPS
      port: 443
      hostname: shop.example.com
      tls:
        mode: Terminate
        certificateRefs:
          - kind: Secret
            name: shop-tls
            namespace: gateway-system
      allowedRoutes:
        namespaces:
          from: Selector
          selector:
            matchLabels:
              gateway-access: "true"
    - name: http
      protocol: HTTP
      port: 80
      hostname: shop.example.com
      allowedRoutes:
        namespaces:
          from: Selector
          selector:
            matchLabels:
              gateway-access: "true"
---
# El HTTPRoute (vive en el namespace de la app)
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: boutique-route
  namespace: microservices
spec:
  parentRefs:
    - name: boutique-gateway
      namespace: gateway-system
      sectionName: https
  hostnames:
    - shop.example.com
  rules:
    - matches:
        - path:
            type: PathPrefix
            value: /
      backendRefs:
        - name: frontend
          port: 80
---
# Y un HTTPRoute extra para forzar redirect HTTP → HTTPS
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: boutique-https-redirect
  namespace: microservices
spec:
  parentRefs:
    - name: boutique-gateway
      namespace: gateway-system
      sectionName: http
  hostnames:
    - shop.example.com
  rules:
    - filters:
        - type: RequestRedirect
          requestRedirect:
            scheme: https
            statusCode: 301
```

Sí, son más líneas. Pero:
- El `Gateway` lo escribes una vez y lo reutilizas en muchos `HTTPRoute`.
- El redirect HTTP→HTTPS es explícito (en Ingress era una anotación oculta).
- El allowedRoutes te protege de que cualquier dev cree un `HTTPRoute` apuntando a tu Gateway sin permiso.

## Mapeo completo de anotaciones `ingress-nginx` → Gateway API

| Anotación `ingress-nginx` | Equivalente Gateway API | Notas |
|---------------------------|--------------------------|-------|
| `nginx.ingress.kubernetes.io/rewrite-target` | `HTTPRoute` filter `URLRewrite` | Nativo, mucho más limpio. |
| `nginx.ingress.kubernetes.io/ssl-redirect` | `HTTPRoute` filter `RequestRedirect` con `scheme: https` | Explícito en una ruta. |
| `nginx.ingress.kubernetes.io/force-ssl-redirect` | Igual ↑ | Mismo patrón. |
| `nginx.ingress.kubernetes.io/use-regex` | `path.type: RegularExpression` | NGF lo soporta desde 2.3+. |
| `nginx.ingress.kubernetes.io/backend-protocol` | `backendRefs` con `appProtocol` en el Service, o `GRPCRoute` para gRPC | Para gRPC, usa `GRPCRoute` (no `HTTPRoute`). |
| `nginx.ingress.kubernetes.io/proxy-body-size` | `NginxProxy` resource (CRD de NGF) | Específico de NGF, no estándar de Gateway API. |
| `nginx.ingress.kubernetes.io/proxy-read-timeout` | `NginxProxy` resource | Idem. |
| `nginx.ingress.kubernetes.io/proxy-connect-timeout` | `NginxProxy` resource | Idem. |
| `nginx.ingress.kubernetes.io/limit-rps` / `limit-rpm` | `ObservabilityPolicy` + `RateLimitPolicy` (NGF 2.4+) | Soportado desde 2.4. |
| `nginx.ingress.kubernetes.io/auth-url` | No hay equivalente directo. Usar `ExtensionRef` o un sidecar (oauth2-proxy). | Cambio de paradigma. |
| `nginx.ingress.kubernetes.io/auth-tls-secret` (mTLS cliente) | `Gateway.spec.listeners[].tls` + `FrontendTLS` (NGF 2.6+) | Nuevo en 2.6. |
| `nginx.ingress.kubernetes.io/cors-*` | `HTTPRoute` con `ResponseHeaderModifier` filter o `NginxProxy` | Más manual. |
| `nginx.ingress.kubernetes.io/server-snippet` | NO HAY equivalente. Custom snippets son antipattern en Gateway API. | Refactoriza a recursos nativos. |
| `nginx.ingress.kubernetes.io/configuration-snippet` | NO HAY equivalente. | Idem. |
| `nginx.ingress.kubernetes.io/canary` | Pesos en `backendRefs[].weight` | Mucho más limpio, parte del spec. |
| `nginx.ingress.kubernetes.io/affinity` (sticky) | `SessionPersistence` policy (NGF 2.4+) | Sticky cookie soportado. |
| `nginx.ingress.kubernetes.io/load-balance` | `BackendLBPolicy` (NGF 2.4+, custom) | Limited a round-robin/least-conn. |

### Anotaciones sin equivalente directo

Si tu Ingress tiene alguna de estas, **revisa antes de migrar**:

- `server-snippet` / `configuration-snippet` — Gateway API es deliberadamente estricto: no permite inyectar NGINX config arbitrario. Considéralo una oportunidad de refactor.
- `auth-url` / `auth-signin` — Para esto, NGF tiene el filter `ExtensionRef` que apunta a un `ExternalAuth` policy, pero es complejidad adicional. La alternativa más común es **mover auth a la aplicación** o usar un sidecar (`oauth2-proxy`).
- `permanent-redirect` con regex complejos — Funciona, pero la sintaxis cambia. Validar uno por uno.

## Diferencias semánticas importantes

### 1. `pathType`

| Ingress | Gateway API |
|---------|-------------|
| `Exact` | `Exact` |
| `Prefix` | `PathPrefix` |
| `ImplementationSpecific` | `RegularExpression` (más explícito) |

**Trampa común**: `Prefix: /foo` en Ingress matchea `/foo` y `/foo/bar`. En Gateway API `PathPrefix: /foo` matchea **solo `/foo` y `/foo/...`** (con `/` después). Para matchear `/foobar`, necesitas regex. Este es un gotcha conocido — testéalo en el canary.

### 2. Múltiples hosts

En Ingress: un objeto puede tener N hosts en `rules`. En Gateway API: un `HTTPRoute` también puede tener múltiples `hostnames`, **pero deben ser un subset de los hostnames del `Gateway`**. Si tu Ingress sirve `a.example.com` y `b.example.com`, el `Gateway` necesita ambos en `listeners`.

### 3. TLS por host

Ingress permite `tls[]` con un cert por host. Gateway API: cada `listener` tiene su propio cert. Si tienes 5 hosts con 5 certs, son 5 listeners (o uno con SNI y `certificateRefs` múltiple — soportado).

### 4. Status y observabilidad

Gateway API tiene un modelo de `status` mucho más rico. Cada recurso reporta:
- `Accepted`: el controller lo entendió.
- `Programmed`: el dataplane ya tiene la config aplicada.
- `ResolvedRefs`: los `backendRefs` apuntan a servicios que existen.

```bash
kubectl get httproute -n microservices boutique-route -o yaml | yq '.status'
```

Esto te dice **exactamente** si tu route está activa o por qué no. En `ingress-nginx`, había que leer logs del controller.

## ¿Y si necesito algo que Gateway API no soporta nativamente?

Tres caminos en orden de preferencia:

1. **Usar una policy estándar** (`BackendTLSPolicy`, `RateLimitPolicy`, etc.) — son parte del spec extendido.
2. **Usar una policy específica de NGF** (`NginxProxy`, `ClientSettingsPolicy`, `ObservabilityPolicy`). Te ata a NGF pero es lo más cercano a las anotaciones de `ingress-nginx`.
3. **Refactorizar a otra capa** (sidecar, service mesh, app code). A veces lo más sano.

---

Siguiente: [`04-migration-runbook.md`](./04-migration-runbook.md) — el runbook ejecutable.
