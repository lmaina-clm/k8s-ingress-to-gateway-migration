[English](05-zero-downtime.md) | **Español**

# 05 — Análisis de zero-downtime

Este documento responde la pregunta del millón: **¿realmente se puede migrar de Ingress a Gateway API sin downtime?**

**Respuesta corta**: Sí, en la mayoría de los casos. Pero hay un puñado de escenarios donde **es imposible** o requiere un tradeoff. Léelos antes de prometérselo a alguien.

## ¿Qué cuenta como "downtime"?

Definamos términos. "Zero-downtime" puede significar cosas distintas:

| Definición | Estricta | Práctica |
|------------|----------|----------|
| Disponibilidad | Ningún request 5xx durante la migración. | < 0.01% de error rate, dentro del SLO. |
| Latencia | p99 nunca aumenta > 10%. | p99 puntual puede subir 2x por <1 min. |
| Sesiones | Ningún usuario es deslogeado. | Pocos usuarios reconectan (clientes resilientes). |
| Conexiones long-lived | Websockets/gRPC streams ininterrumpidos. | Reconexiones automáticas del cliente OK. |

**La definición "práctica" es alcanzable.** La "estricta" requiere supuestos muy fuertes (clientes perfectos, DNS perfecto). Sé honesto con tus stakeholders sobre cuál estás prometiendo.

## ¿Por qué la estrategia con dos controllers paralelos funciona?

El insight clave: **`ingress-nginx` y `nginx-gateway-fabric` son dos controllers independientes**, con:
- Binarios distintos.
- `IngressClass` vs `GatewayClass` distintos.
- LoadBalancers distintos (NLBs separados en AWS).
- Pods distintos en namespaces distintos.

No compiten por recursos. No se interfieren. Cada uno sirve **sus propios recursos** (Ingress vs HTTPRoute) y los demás los ignora.

Esto significa que **agregar el segundo controller no afecta al primero**. El único momento donde el tráfico real cambia es cuando modificas DNS — y eso es **fuera del clúster**, controlable y reversible.

## Los 4 riesgos reales

### Riesgo 1: TTL del DNS

**El problema**: si tu DNS tiene TTL=3600s y haces el cambio, durante una hora algunos clientes seguirán resolviendo al NLB viejo. Si lo decomisionas antes → downtime para esos clientes.

**Mitigación**:
- **Bajar TTL 24h antes del cambio** a 60s (o menos).
- **Esperar 5×TTL antes de decomisionar** el viejo. Idealmente más.
- **Algunos clientes (mobile apps, bots) ignoran TTL** y cachean por horas. Para esos no hay solución que no sea esperar más.

**Impacto residual**: 0.01% - 1% de tráfico, dependiendo de tus clientes. Si tu app tiene retries automáticos, los usuarios no lo notan.

### Riesgo 2: Conexiones HTTP long-lived

**El problema**: HTTP/1.1 keep-alive permite reusar TCP sockets por minutos/horas. HTTP/2 multiplexa requests sobre una sola conexión persistente. Una vez establecida, **un cambio de DNS no afecta esa conexión** — sigue yendo al NLB viejo hasta que se cierre.

**Mitigación**:
- **El NLB del Ingress sigue respondiendo** durante la coexistencia. Los clientes con conexiones abiertas siguen funcionando.
- **Forzar cierre**: hacer un `kubectl rollout restart deployment ingress-nginx-controller` cierra las conexiones del lado del servidor, los clientes reconectan al DNS actual.
- **Esperar timeouts naturales**: la mayoría de clientes cierran tras ~60s de inactividad. Conexiones de larga duración tienen el problema siguiente.

### Riesgo 3: Websockets y gRPC streams

**El problema**: una conexión websocket o gRPC server-streaming puede durar **horas o días**. Cambiar DNS no la afecta. Decomisionar el Ingress sí, **abruptamente**.

**Esto es lo más cerca a "downtime real"** durante la migración.

**Mitigaciones por orden de complejidad**:

1. **Si tu cliente reconecta automáticamente con backoff** (lo correcto en cualquier app moderna): no hay problema. Cuando cierres el Ingress, los clientes reconectan al DNS actual (que ya apunta al Gateway).

2. **Drenar progresivamente antes de cerrar**: hacer scale-down del `ingress-nginx-controller` no es óptimo (NLB termina conexiones bruscamente). Mejor: reducir replicas a 1 y forzar terminación con `preStop` hook que `nginx -s quit` (graceful drain). El NLB sacará de rotación los pods sin réplicas.

3. **Si tienes clientes que NO reconectan** (legacy, hardware): tienes que coordinar el corte con esos clientes. No es zero-downtime real para ellos.

### Riesgo 4: Diferencias semánticas no detectadas

**El problema**: Gateway API se comporta ligeramente distinto a Ingress en algunos casos sutiles. Si tu app depende de un comportamiento específico, el cambio puede romper cosas **sin error 5xx** — solo bugs sutiles.

**Ejemplos reales que hemos visto**:

- **`Prefix` semantics**: `Prefix: /api` en Ingress matchea `/api`, `/api/`, `/api/v1`, **y también `/apiv1`** (esto último depende del controller). En Gateway API `PathPrefix: /api` matchea `/api`, `/api/`, `/api/v1` pero **NO** `/apiv1`. Si tu cliente usa el path mal escrito, dejará de funcionar.

- **Headers reescritos**: `ingress-nginx` agrega `X-Forwarded-For`, `X-Real-IP`. NGF también, pero la sintaxis exacta puede diferir (especialmente si tienes proxies en cadena).

- **gRPC**: si tu Ingress tenía `backend-protocol: GRPC`, en Gateway API necesitas un `GRPCRoute` (no `HTTPRoute`). Usar `HTTPRoute` para gRPC parece funcionar pero falla en casos edge (trailing headers, streaming).

- **CORS**: si las anotaciones de CORS de `ingress-nginx` se traducen a `ResponseHeaderModifier`, las reglas pueden no ser idénticas (especialmente para preflights).

**Mitigación**:
- `scripts/compare-responses.sh` hace diff de respuestas entre los dos NLBs **para una lista de paths**. Asegúrate de que esa lista cubre tus endpoints críticos.
- **Canary largo**: no pases del 10% en menos de 1 hora. Da tiempo a que las diferencias sutiles aparezcan en métricas.

## Escenarios donde NO se puede hacer zero-downtime

Sé honesto. Estos escenarios existen:

### Escenario A: Clientes con DNS hardcoded a una IP

Si tu app es consumida por integraciones B2B que **hardcodearon la IP del NLB** en su firewall, el cambio de NLB ES un cambio de IP. Cero-downtime requiere o:
- Negociar con el cliente que cambie su firewall (puede ser semanas).
- Mantener el NLB viejo apuntando al Gateway via un mecanismo de proxy externo (over-engineering masivo).

### Escenario B: Single-replica del Ingress controller con conexiones críticas

Si por alguna razón solo tienes 1 replica de `ingress-nginx-controller`, el drain forzado va a cortar conexiones abruptamente. Antes de la migración, **escala a 3+ replicas y migra gradualmente**.

### Escenario C: Mutual TLS con client certs específicos del controller

Si tu Ingress tenía mTLS con configuración muy específica (`auth-tls-secret`, validación custom), NGF tiene equivalente desde 2.6 pero **los certificados de los clientes pueden necesitar re-rotación si confían en el cert del Ingress**. Esto raramente es problema, pero validar.

### Escenario D: Aplicaciones que NO toleran ver dos backends durante el cutover

Muy raro, pero existe. Por ejemplo, si tu app tiene un **rate limit por IP del cliente** y el Gateway expone una IP distinta a la del Ingress viejo, durante el canary algunos clientes podrían verse con "límites duplicados". Solución: rate limit en la app, no en el ingress (que es lo correcto de todas formas).

## ¿Y si fallo el zero-downtime?

Si en la fase de canary detectas errores 5xx **antes** del 50%, revertir DNS es prácticamente instantáneo (limitado por TTL, que es 60s).

Si los errores aparecen **después** del cutover y el `ingress-nginx` ya fue decomisionado, el rollback es:
1. Reinstalar `ingress-nginx`.
2. Reaplicar los Ingress (los tienes en Git).
3. Esperar a que se cree el NLB nuevo (~3-5 min en AWS).
4. Actualizar DNS al NLB nuevo.

Esto **no es zero-downtime para el rollback**, son ~10 minutos de degradación. Por eso decomisionar al final es deliberadamente lento.

## Resumen ejecutivo

**Lo que prometemos**: con el runbook seguido, una migración con menos de 0.1% de error rate adicional durante la ventana, y zero pérdida de usuarios con clientes resilientes.

**Lo que NO prometemos**: literalmente cero requests fallidos. Eso solo es posible con clientes perfectos y DNS perfecto.

**El requisito clave del cliente**: retries automáticos con backoff. Si tu cliente hace eso (cualquier librería HTTP moderna), no notarás absolutamente nada.

---

Siguiente: [`06-rollback.es.md`](./06-rollback.es.md) — plan detallado de rollback en cada fase.
