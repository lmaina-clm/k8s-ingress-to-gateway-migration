# manifests/03-gateway-api — Estado destino

Estado de la arquitectura **después** de la migración:

- NGINX Gateway Fabric 2.6.x instalado (ver `scripts/install-nginx-gateway-fabric.sh`).
- Un `Gateway` con listeners HTTP/443 + HTTP/80 (este último solo para redirect).
- Un `HTTPRoute` que enruta a `frontend` (equivalente al Ingress anterior).
- Un `HTTPRoute` extra que redirecciona HTTP → HTTPS.
- (Opcional) Un `ClientSettingsPolicy` que ajusta el `client_max_body_size`.

## Aplicar

Primero asegúrate de que NGF esté instalado:

```bash
./scripts/install-nginx-gateway-fabric.sh
```

Luego:

```bash
# 1. Asegurarte de que existen los namespaces (00-base)
kubectl apply -f manifests/00-base/

# 2. Copiar el cert al namespace gateway-system (o usar cert-manager)
kubectl get secret shop-tls -n microservices -o yaml \
  | sed 's/namespace: microservices/namespace: gateway-system/' \
  | kubectl apply -f -

# 3. Aplicar los manifiestos del Gateway
kubectl apply -f manifests/03-gateway-api/
```

## Verificar

```bash
# El GatewayClass debe estar Accepted
kubectl get gatewayclass nginx

# El Gateway debe estar Programmed
kubectl get gateway -n gateway-system

# Los HTTPRoutes deben estar Accepted y con ResolvedRefs
kubectl get httproute -n microservices

# El NLB del data plane
kubectl get svc -n gateway-system
```

## Probar

```bash
GW_LB=$(kubectl get svc -n gateway-system \
  -l gateway.nginx.org/gateway=boutique-gateway \
  -o jsonpath='{.items[0].status.loadBalancer.ingress[0].hostname}')

# Sin DNS configurado todavía, simulamos el hostname:
curl -k --resolve shop.example.com:443:$(dig +short $GW_LB | head -1) \
     https://shop.example.com/
```

## Archivos

| Archivo | Propósito |
|---------|-----------|
| `gateway.yaml` | El `Gateway` con listeners HTTP y HTTPS |
| `httproute-main.yaml` | El `HTTPRoute` principal (frontend) |
| `httproute-redirect.yaml` | El `HTTPRoute` que hace HTTP → HTTPS |
| `client-settings.yaml` | Policy NGF para body-size, timeouts (equivalente a anotaciones) |
| `certificate.yaml` | (Opcional) Si usas cert-manager, define el `Certificate` aquí |

## Equivalencia con el Ingress anterior

El `Ingress` de `02-ingress-nginx/ingress.yaml` se mapea así:

```
Ingress.spec.tls         → Gateway.spec.listeners[1].tls
Ingress.spec.rules[0]    → HTTPRoute (main)
nginx.ingress.kubernetes.io/force-ssl-redirect: "true"
                         → HTTPRoute (redirect)
nginx.ingress.kubernetes.io/proxy-body-size: "10m"
                         → ClientSettingsPolicy.spec.body.maxSize
nginx.ingress.kubernetes.io/proxy-read-timeout: "60"
                         → ClientSettingsPolicy.spec.keepAlive...
nginx.ingress.kubernetes.io/proxy-connect-timeout: "10"
                         → (default OK)
```
