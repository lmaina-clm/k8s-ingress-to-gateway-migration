[English](02-architecture.md) | **Español**

# 02 — Arquitectura y decisiones de diseño

Este documento explica **el porqué** de las decisiones técnicas. Si solo quieres ejecutar la migración, salta a `04-migration-runbook.es.md`.

## La aplicación: Online Boutique

[Online Boutique](https://github.com/GoogleCloudPlatform/microservices-demo) es una app de e-commerce con 11 microservicios. La elegimos porque:

- **Es realista**: múltiples lenguajes (Go, Python, Node.js, C#, Java), comunicación gRPC entre servicios, dependencias asíncronas.
- **Es mantenida activamente** por Google.
- **Tiene un único punto de entrada externo** (`frontend`), pero con comunicación interna rica que ejercita el cluster networking.
- **No es trivial**: te enseña a manejar más que un `hello-world`.

### Topología

```
                          External Traffic (HTTPS)
                                    │
                                    ▼
                        ┌─────────────────────┐
                        │ Ingress / Gateway   │ ← Lo que vamos a migrar
                        └──────────┬──────────┘
                                   │
                                   ▼
                        ┌─────────────────────┐
                        │     frontend        │ (Go, HTTP)
                        └──────────┬──────────┘
                                   │ gRPC interno
        ┌──────────────┬───────────┼────────────┬──────────────┐
        ▼              ▼           ▼            ▼              ▼
   ┌─────────┐   ┌──────────┐ ┌─────────┐ ┌──────────┐  ┌───────────┐
   │ product │   │   cart   │ │ checkout│ │ shipping │  │ currency  │
   │ catalog │   │          │ │         │ │          │  │           │
   │  (Go)   │   │  (C#)    │ │  (Go)   │ │  (Go)    │  │ (Node.js) │
   └─────────┘   └─────┬────┘ └────┬────┘ └──────────┘  └───────────┘
                       │           │
                       ▼           ▼
                 ┌──────────┐ ┌──────────┐
                 │  redis   │ │ payment  │
                 │ (datos)  │ │  (Node)  │
                 └──────────┘ └──────────┘
                                   │
                              ┌────┴────┐
                              ▼         ▼
                         ┌──────┐  ┌─────────┐
                         │email │  │   ads   │
                         │(Py)  │  │  (Java) │
                         └──────┘  └─────────┘
```

**Lo importante para esta migración**: solo `frontend` se expone externamente. Todos los demás son `ClusterIP`. La migración solo toca el borde — el tráfico interno (gRPC entre servicios) no cambia.

Esto es **representativo del 80% de las arquitecturas de microservicios en producción**: un BFF/gateway-de-aplicación que es el único expuesto, y el resto es interno. Si tu caso es distinto (varios servicios expuestos directamente), el patrón escala — solo agregas más `HTTPRoute`s.

## Decisión 1: ¿Por qué NGINX Gateway Fabric y no otra implementación?

| Implementación | Pros | Contras |
|----------------|------|---------|
| **NGINX Gateway Fabric** | Misma familia que `ingress-nginx`, transición conceptual menor. NGINX como dataplane (lo que ya conocemos). Mantenido por F5/NGINX. Soporte comercial disponible. | Más joven que Istio. Algunas features avanzadas (ratelimit, sesión persistente) son recientes. |
| **Istio** | Maduro, ecosistema enorme, service mesh + gateway en uno. | Mucho más complejo. Si solo necesitas el ingress, es over-engineering. |
| **Envoy Gateway** | Envoy es el estándar de facto en service mesh. Excelente performance. | Curva de aprendizaje. Si nunca usaste Envoy, sumas complejidad. |
| **Cilium Gateway API** | Si ya usas Cilium como CNI, integración natural. eBPF dataplane. | Requiere Cilium como CNI; no aplica si usas otro. |
| **AWS Gateway API Controller** | Integración nativa con AWS VPC Lattice. | Lock-in con AWS, modelo de costos distinto. |

**Para un equipo que viene de `ingress-nginx`, NGF es la fricción mínima**: misma compañía, mismo dataplane, mismas mental models de NGINX (workers, upstreams, etc.). Las anotaciones cambian, pero el comportamiento subyacente es predecible.

## Decisión 2: Estrategia de coexistencia (la clave del zero-downtime)

Hay tres enfoques posibles:

### A) Big-bang: borrar Ingress y aplicar Gateway

❌ **No.** Implica downtime garantizado mientras el nuevo controller se inicializa y el NLB se reaprovisiona. Imposible de hacer zero-downtime.

### B) In-place: mismo controller sirve Ingress y Gateway

❌ **No funciona con NGF.** NGF solo entiende Gateway API. `ingress-nginx` solo entiende Ingress. Son binarios distintos.

### C) Coexistencia con dos controllers en paralelo ← **lo que hacemos**

✅ Ambos controllers corren al mismo tiempo, con LoadBalancers separados. Los `Ingress` los sirve uno, los `HTTPRoute` el otro. El cutover se hace **fuera del clúster**, a nivel DNS.

```
         dns.example.com
                │
                ├─ (durante coexistencia) → Route 53 weighted records
                │       ├─ 90% → NLB-A (ingress-nginx)
                │       └─ 10% → NLB-B (nginx-gateway-fabric)
                │
                └─ (post-cutover) → 100% → NLB-B
```

Ventajas:
- **Rollback inmediato** revirtiendo el DNS (limitado por TTL).
- **Tráfico canary controlado** desde el primer momento.
- **Ambos sistemas observables** simultáneamente para comparar.

Desventaja:
- Costo de un NLB extra durante la ventana de migración (~$20/mes en us-east-1, prorrateado a días).
- Más complejidad operativa durante 1-2 semanas.

El costo es trivial comparado con un incidente de downtime.

## Decisión 3: Modelo de namespaces

NGF crea el data-plane (NGINX pods) dinámicamente cuando creas un `Gateway`. Por default, los crea en el **mismo namespace que el `Gateway`**. Recomendación:

- **`nginx-gateway`** — namespace del control-plane de NGF (lo crea Helm).
- **`gateway-system`** — namespace donde vive el recurso `Gateway` y su data-plane asociado.
- **`microservices`** — namespace de la aplicación, donde viven los `HTTPRoute` (con `ParentRefs` cross-namespace al Gateway).

Esto separa responsabilidades:
- Equipo de plataforma controla `gateway-system`.
- Equipo de aplicación controla sus `HTTPRoute` en `microservices`.

El acceso cross-namespace se otorga vía `ReferenceGrant` — Gateway API requiere consentimiento explícito.

## Decisión 4: ¿Qué hacemos con TLS?

Tres opciones para terminar TLS:

| Opción | Donde termina TLS | Cuándo usarla |
|--------|-------------------|---------------|
| Pass-through al pod | En el pod (TCP route) | Cuando necesitas mTLS de extremo a extremo. |
| **Termina en el Gateway** (recomendado por defecto) | En NGF | Caso general; certificados en `Secret`s K8s o cert-manager. |
| Termina en el NLB | En AWS, vía ACM | Si quieres ACM e integración con AWS WAF. |

Este repo asume **terminación en el Gateway** porque es la opción más portable y replica lo que normalmente hacía `ingress-nginx`. Si terminas en el NLB con ACM, los manifiestos son ligeramente distintos — ver sección "TLS en el NLB" en `07-troubleshooting.es.md`.

## Decisión 5: Cómo mapeamos Ingress → HTTPRoute

Online Boutique tiene un solo Ingress que enruta todo a `frontend`. Eso lo hace un caso simple, pero documentamos el mapeo general:

| Concepto Ingress | Equivalente Gateway API |
|------------------|-------------------------|
| `kind: Ingress` | `kind: HTTPRoute` |
| `spec.ingressClassName: nginx` | `spec.parentRefs[].name` (apunta a `Gateway`) |
| `spec.tls[]` (cert) | Configurado en `Gateway.spec.listeners[].tls` |
| `spec.rules[].host` | `HTTPRoute.spec.hostnames[]` |
| `spec.rules[].http.paths[]` | `HTTPRoute.spec.rules[].matches[]` |
| `path.backend.service` | `rules[].backendRefs[]` |
| Anotación `rewrite-target` | Filter `URLRewrite` |
| Anotación `force-ssl-redirect` | Listener HTTP con `HTTPRoute` que hace redirect |
| Anotación `proxy-body-size` | `NginxProxy` resource (NGF-específico) |
| Anotación `auth-url` | No tiene equivalente directo; usar `ExtensionRef` |

La tabla completa con todas las anotaciones de `ingress-nginx` está en `03-ingress-vs-gateway.es.md`.

## Lo que NO cubrimos en esta migración (deliberadamente)

- **Service mesh interno** — Si quieres mTLS entre microservicios, ese es un proyecto aparte. NGF puede ser tu ingress sin tocar lo interno.
- **API Gateway L7 features avanzadas** (rate limiting per-user, JWT validation con introspection). Algunas están en NGF 2.4+, otras necesitan un API Gateway dedicado (Kong, Apigee) detrás del Gateway K8s.
- **Multi-cluster routing** — Posible con Gateway API + Submariner/Linkerd multi-cluster, pero fuera de scope.

---

Siguiente: [`03-ingress-vs-gateway.es.md`](./03-ingress-vs-gateway.es.md) — el mapeo conceptual completo entre los dos mundos.
