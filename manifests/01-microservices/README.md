# manifests/01-microservices

## Online Boutique — la aplicación de demostración

Esta carpeta contiene la configuración para desplegar [Online Boutique](https://github.com/GoogleCloudPlatform/microservices-demo) en el namespace `microservices`.

## Estrategia

En lugar de duplicar el manifiesto upstream (~600 líneas), usamos **Kustomize** para aplicar el manifiesto oficial v0.10.x y luego le aplicamos parches mínimos:

1. **Namespace**: lo movemos al namespace `microservices` (el upstream usa `default`).
2. **Servicio público**: removemos `frontend-external` (LoadBalancer directo del upstream). El acceso público lo manejamos vía Ingress/Gateway.
3. **Labels**: agregamos labels consistentes (`app.kubernetes.io/part-of: boutique`).

## Aplicar

```bash
kubectl apply -k manifests/01-microservices/
```

Esto:
- Crea ~22 recursos (11 Deployments + 11 Services + 1 ServiceAccount).
- Tarda 3-5 min en que todos los pods estén `Ready` (algunos esperan a sus dependencias).

## Verificar

```bash
kubectl -n microservices get pods -w
# Esperar a que todos estén Running
```

Salida esperada (final):

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

## Servicios y puertos

El único servicio expuesto externamente es **`frontend`** (HTTP/80). Los demás son `ClusterIP`.

| Servicio | Lenguaje | Puerto | Función |
|----------|----------|--------|---------|
| frontend | Go | 80 | UI web + API HTTP |
| productcatalogservice | Go | 3550 | Catálogo de productos (gRPC) |
| cartservice | C# | 7070 | Carrito (gRPC) |
| checkoutservice | Go | 5050 | Checkout flow (gRPC) |
| paymentservice | Node.js | 50051 | Cobro mock (gRPC) |
| shippingservice | Go | 50051 | Cálculo de envío (gRPC) |
| emailservice | Python | 5000 | Email mock (gRPC) |
| currencyservice | Node.js | 7000 | Conversión moneda (gRPC) |
| recommendationservice | Python | 8080 | Recomendaciones (gRPC) |
| adservice | Java | 9555 | Ads (gRPC) |
| redis-cart | Redis | 6379 | Storage del carrito |

## Test del frontend internamente

Antes de exponer al exterior, valida que la app funciona:

```bash
kubectl -n microservices port-forward svc/frontend 8080:80
# En otra terminal:
curl http://localhost:8080/
# Debe devolver HTML
```

## Notas

- **El `loadgenerator`** simula tráfico interno y es útil para tener métricas durante la migración. Si te molesta, escalalo a 0:
  ```bash
  kubectl -n microservices scale deployment loadgenerator --replicas=0
  ```
- **`PodSecurityStandards`**: el namespace tiene `baseline` enforce. La app upstream cumple con baseline pero NO con `restricted`. Si tu org requiere `restricted`, necesitarás patches adicionales (capabilities, runAsNonRoot explícito, etc.).
