# 08 — FAQ

Preguntas que el equipo te va a hacer cuando presentes la migración.

## ¿Por qué tenemos que migrar?

`ingress-nginx` (el proyecto de la comunidad de Kubernetes, no NGINX Inc.) fue **marcado como deprecated en marzo de 2026**. La comunidad recomienda Gateway API como sucesor. Aunque seguirá funcionando un tiempo, no recibirá features nuevos y los fixes de seguridad serán cada vez más lentos.

Postergar la migración es deuda técnica que crece.

## ¿No podemos quedarnos con `ingress-nginx` "para siempre"?

Técnicamente sí, mientras funcione. Pero:
- CVEs sin parche eventualmente.
- Helm chart deja de mantenerse.
- Documentación se vuelve obsoleta.
- Cuando lo tengas que migrar bajo presión, será peor.

## ¿Gateway API es estable?

Sí. Las APIs core (Gateway, GatewayClass, HTTPRoute) están **GA desde v1.0** (Octubre 2023). Actualmente estamos en v1.5.1. Múltiples implementaciones en producción (Google, AWS, NGINX, Istio).

## ¿Por qué NGINX Gateway Fabric y no Istio/Envoy/Cilium?

Ver `02-architecture.md`. Resumen:
- **Conocimiento existente**: tu equipo ya entiende NGINX. NGF mantiene el mismo dataplane y mental model.
- **Soporte comercial**: F5 vende soporte si lo necesitas.
- **Simple**: hace una cosa (Gateway API) y la hace bien. Si necesitas service mesh, esa es otra decisión.

Si tu equipo ya usa Istio en service mesh, **Istio también implementa Gateway API** y puede ser mejor opción para unificar. Si no usas mesh, NGF es el camino simple.

## ¿Cuánto tiempo toma la migración?

Por servicio: **3-5 días de calendario**, con ~5 horas de trabajo activo. La mayor parte del tiempo es ventana de observación entre fases del canary.

Por equipo (varios servicios): puede paralelizarse o secuenciarse. Recomendación: **migra primero un servicio no crítico** para que el equipo aprenda, luego los críticos.

## ¿Podemos hacerlo en una sola noche?

Técnicamente sí (acortar las ventanas de observación). **No lo recomendamos**. Algunos problemas solo se ven con tráfico real durante el ciclo natural de uso (peak / off-peak). Cortar el canary genera más riesgo de lo que ahorra en tiempo.

## ¿Esto afecta cómo los devs despliegan sus servicios?

Sí, pero el cambio es contenido. Lo que cambia para devs:

| Antes | Después |
|-------|---------|
| `kind: Ingress` en su chart | `kind: HTTPRoute` en su chart |
| `ingressClassName: nginx` | `parentRefs: [...gateway...]` |
| Anotaciones para configurar | Filters o policies CRD-based |

El cambio en helm charts / kustomize es **cosmético en el caso simple**. Los casos con muchas anotaciones requieren más trabajo.

## ¿Necesitamos cambiar nuestro CI/CD?

Solo en lo que valida manifiestos:

- Si tienes `kubeval` / `kubeconform` validando schemas, agregar los CRDs de Gateway API a tu config.
- Si tienes plantillas (Helm/Kustomize) hardcoded para Ingress, hay que crear nuevas para HTTPRoute.
- Las pipelines de deploy en sí no cambian: `kubectl apply` sigue funcionando.

## ¿Qué pasa con cert-manager?

Funciona, con dos consideraciones:
- **Versión mínima 1.14** para soporte nativo de Gateway API.
- El `Certificate` puede vivir en el namespace del `Gateway`, no de la app.

Alternativamente puedes seguir usando `Certificate` linkado a un `Ingress` (legacy) hasta que migres, y luego mover al Gateway.

## ¿Qué pasa con `external-dns`?

`external-dns` soporta `Gateway` y `HTTPRoute` desde **v0.14**. Antes de la migración, upgrade tu `external-dns` y configúralo:

```bash
helm upgrade external-dns ... --set sources={service,ingress,gateway-httproute,gateway-grpcroute}
```

Durante la migración, **deshabilita external-dns para el hostname que estás migrando** y maneja DNS manualmente. Reactiva una vez terminado.

## ¿Y si usamos Cloudflare en frente?

Funciona igual. Cloudflare apunta al NLB (Ingress o Gateway). Durante la migración, cambias el record de Cloudflare en lugar de Route 53. La estrategia de canary funciona si configuras dos origin pools (uno por NLB) con pesos.

## ¿Y si usamos un service mesh (Istio/Linkerd)?

Dos opciones:
1. **El mesh maneja el ingress** (Istio Gateway o Linkerd ingress). Migras al Gateway API del mesh, no a NGF.
2. **NGF es el ingress, el mesh es interno**. Funciona, sin problema. El tráfico entra por NGF y el mesh maneja la comunicación intra-cluster.

## ¿Soporta gRPC?

Sí, vía `GRPCRoute` (kind separado de `HTTPRoute`). Sintaxis muy similar. NGF lo soporta desde 2.0.

```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: GRPCRoute
metadata:
  name: my-grpc
spec:
  parentRefs: [...]
  rules:
    - matches:
        - method:
            service: my.package.MyService
            method: MyMethod
      backendRefs:
        - name: my-grpc-service
          port: 50051
```

## ¿Soporta WebSockets?

Sí, sin configuración especial. NGF detecta el upgrade HTTP→WS automáticamente. **Pero los WebSockets son el caso más complicado para zero-downtime** — ver `05-zero-downtime.md`.

## ¿Soporta rate limiting?

Sí, desde NGF 2.4 vía `RateLimitPolicy`. Antes no había soporte nativo y había que usar un componente externo.

```yaml
apiVersion: gateway.nginx.org/v1alpha1
kind: RateLimitPolicy
metadata:
  name: api-ratelimit
spec:
  targetRef:
    kind: HTTPRoute
    name: api-route
  limits:
    - limit: 100
      duration: 1m
      key:
        type: SourceIP
```

## ¿Es más caro que `ingress-nginx`?

Marginalmente. Costos extra:
- **+1 NLB durante migración** (~$20/mes prorrateado a días).
- **+ pods del control plane** de NGF (~100MB RAM total, despreciable).

Post-migración: aproximadamente lo mismo que `ingress-nginx`.

Si comparas con **NGINX Plus** (la versión comercial), NGF puede usar tanto OSS como Plus. Plus añade features (live monitoring, mejores algoritmos de LB) pero tiene costo de licencia.

## ¿Y si quiero rollback definitivo después de meses?

Posible pero requiere planificación inversa:
1. Reinstalar `ingress-nginx`.
2. Re-crear los Ingress objects (los tienes en Git histórico).
3. Hacer el canary inverso.

Sin embargo, después de meses operando con Gateway API, lo más probable es que hayas adoptado features (filters, policies) que **no tienen equivalente directo en Ingress**. El rollback puede requerir refactor de las apps. **No lo recomendamos** salvo casos extremos.

## ¿Esto rompe nuestros dashboards/alertas existentes?

Sí, los específicos de `ingress-nginx`. Los nombres de métricas cambian. Tienes que recrearlos contra las métricas de NGF antes del cutover. Ver `07-troubleshooting.md` sección "Observabilidad".

## ¿Qué hacemos con las anotaciones que NO tienen equivalente?

Tres opciones, en orden de preferencia:

1. **Refactor**: si la anotación era para algo que debería estar en la app (auth, rate-limit per-user complejo), muévelo a la app. Es la oportunidad de pagar deuda.
2. **NginxProxy/policies de NGF**: para configs específicas de NGINX (timeouts, buffers), NGF tiene CRDs equivalentes.
3. **Sidecar**: para auth o features complejas, un sidecar (oauth2-proxy, envoy filter) puede hacer el trabajo.

## ¿Quién es dueño del `Gateway`?

Decisión organizacional. Recomendación:
- **`Gateway` es de plataforma**: el equipo de SRE/Platform lo gestiona, define listeners, hostnames, certs.
- **`HTTPRoute` es del equipo de aplicación**: cada equipo gestiona sus rutas, en su namespace.

Esto es **exactamente lo que Gateway API fue diseñada para hacer**. Aprovéchalo.

## ¿Tenemos que migrar todos los servicios al mismo tiempo?

No. **Tampoco lo recomendamos**. Migra uno por uno:
1. Servicio no crítico primero (aprender).
2. Servicios secundarios.
3. Servicios críticos al final, con el equipo curtido.

Durante la transición conviven Ingress + Gateway. No hay problema.

## ¿Qué pasa si fallan los DNS de los clientes?

Si Route 53 falla, tu DNS deja de responder y los clientes nuevos no resuelven. **Es un problema independiente de la migración** — pasaría igual sin Gateway API. La diferencia: con migración activa, podrías tener algunos clientes resolviendo al viejo NLB y otros al nuevo, durante el outage de DNS. Cuando DNS vuelve, todo normaliza al estado actual de Route 53.

## ¿Y si nuestro Gateway falla?

Mismo análisis que para `ingress-nginx`: NGF data-plane tiene N replicas con HPA. Si el NLB sigue saludable y al menos 1 pod responde, no hay outage. Si todos los pods fallan: outage del Gateway, igual que sería con `ingress-nginx` en circunstancias equivalentes.

NGF **no introduce nuevos puntos de falla** vs. `ingress-nginx`. El control-plane no está en el path crítico de requests (solo lee/escribe config a NGINX).

---

¿Tu pregunta no está? Abre un issue en el repo o pinguea al canal del equipo.
