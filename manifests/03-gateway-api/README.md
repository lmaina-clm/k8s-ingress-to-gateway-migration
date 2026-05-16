**English** | [Español](README.es.md)

# manifests/03-gateway-api — Target state

State of the architecture **after** the migration:

- NGINX Gateway Fabric 2.6.x installed (see `scripts/install-nginx-gateway-fabric.sh`).
- A `Gateway` with HTTP/443 + HTTP/80 listeners (the latter only for redirect).
- An `HTTPRoute` that routes to `frontend` (equivalent to the previous Ingress).
- An extra `HTTPRoute` that redirects HTTP → HTTPS.
- (Optional) A `ClientSettingsPolicy` that adjusts the `client_max_body_size`.

## Apply

First, make sure NGF is installed:

```bash
./scripts/install-nginx-gateway-fabric.sh
```

Then:

```bash
# 1. Make sure the namespaces exist (00-base)
kubectl apply -f manifests/00-base/

# 2. Copy the cert to the gateway-system namespace (or use cert-manager)
kubectl get secret shop-tls -n microservices -o yaml \
  | sed 's/namespace: microservices/namespace: gateway-system/' \
  | kubectl apply -f -

# 3. Apply the Gateway manifests
kubectl apply -f manifests/03-gateway-api/
```

## Verify

```bash
# The GatewayClass must be Accepted
kubectl get gatewayclass nginx-gateway

# The Gateway must be Programmed
kubectl get gateway -n gateway-system

# The HTTPRoutes must be Accepted with ResolvedRefs
kubectl get httproute -n microservices

# The data plane NLB
kubectl get svc -n gateway-system
```

## Test

```bash
GW_LB=$(kubectl get svc -n gateway-system \
  -l gateway.networking.k8s.io/gateway-name=boutique-gateway \
  -o jsonpath='{.items[0].status.loadBalancer.ingress[0].hostname}')

# With no DNS configured yet, we simulate the hostname:
curl -k --resolve shop.example.com:443:$(dig +short $GW_LB | head -1) \
     https://shop.example.com/
```

## Files

| File | Purpose |
|------|---------|
| `gateway.yaml` | The `Gateway` with HTTP and HTTPS listeners |
| `httproute-main.yaml` | The main `HTTPRoute` (frontend) |
| `httproute-redirect.yaml` | The `HTTPRoute` that does HTTP → HTTPS |
| `client-settings.yaml` | NGF policy for body-size, timeouts (equivalent to annotations) |
| `examples/certificate.yaml.example` | Template for a cert-manager `Certificate`. NOT applied automatically with `kubectl apply -f manifests/03-gateway-api/` because it requires cert-manager installed. Copy and adapt if your cluster has it. |

## Equivalence with the previous Ingress

The `Ingress` from `02-ingress-nginx/ingress.yaml` maps as follows:

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
