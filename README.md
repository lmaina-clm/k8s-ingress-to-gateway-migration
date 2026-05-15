# Migración de NGINX Ingress Controller a Gateway API en EKS

> Guía práctica y manifiestos listos para producción para migrar una arquitectura de microservicios en Kubernetes desde el clásico **NGINX Ingress Controller** hacia **NGINX Gateway Fabric** (Gateway API) — con un plan de **zero-downtime** validado.

## ¿Por qué este repo?

En **marzo de 2025**, el proyecto upstream `ingress-nginx` (el controller que la mayoría de equipos tiene en producción) fue marcado como **deprecated** por la comunidad de Kubernetes, con fecha de retiro definitivo. La sucesora natural es la **Gateway API**, ahora GA, que separa responsabilidades entre infraestructura y aplicación, soporta routing avanzado nativamente, y elimina la dependencia de anotaciones específicas de cada vendor.

Este repositorio te entrega:

1. **Una arquitectura de microservicios funcional** (Google Online Boutique) desplegada en un clúster EKS, expuesta inicialmente con NGINX Ingress Controller.
2. **Un plan de migración paso a paso** hacia NGINX Gateway Fabric usando Gateway API, con estrategia de **coexistencia** para lograr zero-downtime.
3. **Manifiestos completos** de ambos estados (Ingress y Gateway), `HTTPRoute`s equivalentes a cada `Ingress`, y scripts de validación.
4. **Runbook de rollback** porque ningún cambio en producción es completo sin uno.

## ¿Para quién es?

Equipos **DevOps / SRE / Platform Engineering** que:
- Operan uno o más clústeres Kubernetes (este repo usa EKS pero aplica a cualquier distribución).
- Ya usan `ingress-nginx` y necesitan un camino de salida antes del end-of-life.
- Quieren entender Gateway API con un ejemplo realista, no un `hello-world`.

## Arquitectura

La aplicación de demostración es **Online Boutique** de Google: 10 microservicios en distintos lenguajes (Go, Python, Node.js, C#, Java) que simulan un e-commerce. Toda la API externa entra por un único punto:

```
                 ┌────────────────────────────────────────┐
                 │           AWS NLB (público)            │
                 └────────────────────┬───────────────────┘
                                      │
            ┌─────────────────────────┴──────────────────────────┐
            │                                                    │
   ESTADO INICIAL                                       ESTADO FINAL
            │                                                    │
            ▼                                                    ▼
  ┌──────────────────┐                              ┌──────────────────────┐
  │ ingress-nginx    │                              │ NGINX Gateway Fabric │
  │ Controller       │                              │ (Gateway API)        │
  │ + Ingress objs   │                              │ + HTTPRoutes         │
  └────────┬─────────┘                              └──────────┬───────────┘
           │                                                   │
           ▼                                                   ▼
   ┌───────────────┐                                  ┌───────────────┐
   │ frontend Svc  │                                  │ frontend Svc  │
   └───────┬───────┘                                  └───────┬───────┘
           │                                                  │
   ┌───────┴────────────┐                          ┌──────────┴─────────┐
   │ 9 microservicios   │  ← idénticos en ambos →  │ 9 microservicios   │
   │ (cart, checkout,   │                          │ (cart, checkout,   │
   │  payment, etc.)    │                          │  payment, etc.)    │
   └────────────────────┘                          └────────────────────┘
```

Durante la migración, **ambos controllers corren en paralelo** con LoadBalancers separados. El cambio se hace a nivel DNS, lo que permite rollback rápido y zero-downtime real.

## Estructura del repo

```
.
├── README.md                          ← estás aquí
├── docs/
│   ├── 01-prerequisites.md            ← qué necesitas antes de empezar
│   ├── 02-architecture.md             ← decisiones de diseño y por qué
│   ├── 03-ingress-vs-gateway.md       ← comparación conceptual y mapeo 1:1
│   ├── 04-migration-runbook.md        ← el runbook paso a paso ← EMPIEZA AQUÍ
│   ├── 05-zero-downtime.md            ← análisis y estrategia
│   ├── 06-rollback.md                 ← plan de reversión
│   ├── 07-troubleshooting.md          ← problemas comunes
│   └── 08-faq.md
├── manifests/
│   ├── 00-base/                       ← namespace, recursos compartidos
│   ├── 01-microservices/              ← Online Boutique (Deployments + Services)
│   ├── 02-ingress-nginx/              ← estado inicial: controller + Ingress
│   ├── 03-gateway-api/                ← estado final: GatewayClass + Gateway + HTTPRoutes
│   └── 04-migration/                  ← recursos de coexistencia y validación
├── scripts/
│   ├── install-ingress-nginx.sh
│   ├── install-nginx-gateway-fabric.sh
│   ├── validate-traffic.sh            ← smoke tests durante la migración
│   ├── compare-responses.sh           ← diff entre Ingress y Gateway
│   └── rollback.sh
└── .github/workflows/
    └── validate-manifests.yml         ← lint y dry-run en CI
```

## Quick start (modo impaciente)

Si solo quieres ver esto funcionando en tu clúster de pruebas:

```bash
# 1. Despliega los microservicios
kubectl apply -f manifests/00-base/
kubectl apply -f manifests/01-microservices/

# 2. Estado inicial con Ingress
./scripts/install-ingress-nginx.sh
kubectl apply -f manifests/02-ingress-nginx/

# 3. Verifica que funciona
./scripts/validate-traffic.sh ingress

# 4. Instala Gateway API CRDs y NGINX Gateway Fabric
./scripts/install-nginx-gateway-fabric.sh
kubectl apply -f manifests/03-gateway-api/

# 5. Verifica que AMBOS endpoints funcionan en paralelo
./scripts/validate-traffic.sh both

# 6. Cuando estés listo, corta tráfico vía DNS (ver runbook)
# 7. Limpia el Ingress
kubectl delete -f manifests/02-ingress-nginx/
```

## Quick start (modo responsable)

Lee, en orden:

1. **`docs/01-prerequisites.md`** — confirma que tu entorno cumple los requisitos.
2. **`docs/03-ingress-vs-gateway.md`** — entiende qué cambia conceptualmente.
3. **`docs/04-migration-runbook.md`** — el runbook ejecutable, con checkpoints y criterios de éxito en cada fase.
4. **`docs/05-zero-downtime.md`** — entiende los riesgos reales y cómo mitigarlos antes de tocar producción.

## ¿Zero-downtime es realmente posible?

Sí, **con los siguientes supuestos cumplidos**:

- Tu aplicación tolera que el mismo request pueda llegar por dos data-planes distintos durante la ventana de cambio (es decir, no asume sticky sessions a nivel de Ingress — y si lo hace, hay un patrón documentado para resolverlo).
- Controlas el DNS público que apunta al servicio.
- Tus TTLs de DNS son razonables (≤300s ideal, 60s mejor).
- No tienes conexiones long-lived críticas (websockets, gRPC streams largos) sin reconexión automática del cliente.

Si alguno de estos no se cumple, **`docs/05-zero-downtime.md`** documenta los workarounds y el costo de cada uno. La estrategia base es la siguiente:

| Fase | Tiempo | Tráfico vía Ingress | Tráfico vía Gateway |
|------|--------|---------------------|---------------------|
| 1. Preparación | T-0 | 100% | 0% (no existe) |
| 2. Despliegue paralelo | T+1d | 100% | 0% (existe pero sin DNS) |
| 3. Validación interna | T+2d | 100% | 0% (probado con `Host:` header) |
| 4. Weighted DNS — canary | T+3d | 90% → 50% | 10% → 50% |
| 5. Cutover | T+4d | 0% (drenando) | 100% |
| 6. Decomisión | T+5d | eliminado | 100% |

## Versiones y compatibilidad

Probado y documentado contra:

| Componente | Versión |
|------------|---------|
| Kubernetes (EKS) | 1.30, 1.31, 1.32 |
| ingress-nginx | v1.11.x (último antes del EOL) |
| Gateway API CRDs | v1.4.1 |
| NGINX Gateway Fabric | 2.6.x |
| Online Boutique | v0.10.x |
| AWS Load Balancer Controller | v2.8.x |

Las versiones anteriores de NGF (1.x) usan un esquema de instalación distinto. Si estás en 1.x, ver `docs/07-troubleshooting.md` para el upgrade path.

## Licencia

MIT. Úsalo, adáptalo, rómpelo, mejóralo. PRs bienvenidos.

## Créditos

- [Google Cloud Platform — Online Boutique](https://github.com/GoogleCloudPlatform/microservices-demo) — aplicación de demostración.
- [NGINX Gateway Fabric](https://github.com/nginx/nginx-gateway-fabric) — implementación de Gateway API que usamos como destino.
- La comunidad de Kubernetes Gateway API por el trabajo en el spec.
