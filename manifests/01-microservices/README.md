**English** | [Español](README.es.md)

# manifests/01-microservices

## Online Boutique — the demo application

This folder contains the configuration to deploy [Online Boutique](https://github.com/GoogleCloudPlatform/microservices-demo) in the `microservices` namespace.

## Strategy

Instead of duplicating the upstream manifest (~600 lines), we use **Kustomize** to apply the official v0.10.x manifest and then apply minimal patches:

1. **Namespace**: move everything to the `microservices` namespace (upstream uses `default`).
2. **Public service**: remove `frontend-external` (the upstream's direct LoadBalancer). Public access is handled via Ingress/Gateway.
3. **Labels**: add consistent labels (`app.kubernetes.io/part-of: boutique`).

## Apply

```bash
kubectl apply -k manifests/01-microservices/
```

This:
- Creates ~22 resources (11 Deployments + 11 Services + 1 ServiceAccount).
- Takes 3-5 min for all pods to be `Ready` (some wait on their dependencies).

## Verify

```bash
kubectl -n microservices get pods -w
# Wait until all are Running
```

Expected output (final):

```
NAME                                     READY   STATUS    RESTARTS   AGE
adservice-xxx                            1/1     Running   0          2m
cartservice-xxx                          1/1     Running   0          2m
checkoutservice-xxx                      1/1     Running   0          2m
currencyservice-xxx                      1/1     Running   0          2m
emailservice-xxx                         1/1     Running   0          2m
frontend-xxx                             1/1     Running   0          2m
loadgenerator-xxx                        1/1     Running   0          2m
paymentservice-xxx                       1/1     Running   0          2m
productcatalogservice-xxx                1/1     Running   0          2m
recommendationservice-xxx                1/1     Running   0          2m
redis-cart-xxx                           1/1     Running   0          2m
shippingservice-xxx                      1/1     Running   0          2m
```

## Services and ports

The only externally exposed service is **`frontend`** (HTTP/80). The rest are `ClusterIP`.

| Service | Language | Port | Function |
|---------|----------|------|----------|
| frontend | Go | 80 | Web UI + HTTP API |
| productcatalogservice | Go | 3550 | Product catalog (gRPC) |
| cartservice | C# | 7070 | Cart (gRPC) |
| checkoutservice | Go | 5050 | Checkout flow (gRPC) |
| paymentservice | Node.js | 50051 | Mock payments (gRPC) |
| shippingservice | Go | 50051 | Shipping cost (gRPC) |
| emailservice | Python | 5000 | Mock email (gRPC) |
| currencyservice | Node.js | 7000 | Currency conversion (gRPC) |
| recommendationservice | Python | 8080 | Recommendations (gRPC) |
| adservice | Java | 9555 | Ads (gRPC) |
| redis-cart | Redis | 6379 | Cart storage |

## Test the frontend internally

Before exposing externally, validate the app works:

```bash
kubectl -n microservices port-forward svc/frontend 8080:80
# In another terminal:
curl http://localhost:8080/
# Must return HTML
```

## Notes

- **`loadgenerator`** simulates internal traffic and is useful for having metrics during the migration. If it annoys you, scale to 0:
  ```bash
  kubectl -n microservices scale deployment loadgenerator --replicas=0
  ```
- **`PodSecurityStandards`**: the namespace has `baseline` enforce. The upstream app meets baseline but NOT `restricted`. If your org requires `restricted`, you'll need additional patches (capabilities, explicit runAsNonRoot, etc.).
