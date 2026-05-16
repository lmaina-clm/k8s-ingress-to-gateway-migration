**English** | [Español](README.es.md)

# manifests/02-ingress-nginx — Initial state

State of the architecture **before** the migration:

- `ingress-nginx` installed via Helm (see `scripts/install-ingress-nginx.sh`).
- An `Ingress` pointing to the `frontend` service of Online Boutique.
- TLS terminated at the Ingress (self-signed cert by default; replace with your real cert).

## Apply

First the controller:

```bash
./scripts/install-ingress-nginx.sh
```

Then the Ingress resources:

```bash
kubectl apply -f manifests/02-ingress-nginx/
```

## Verify

```bash
# The controller must be Running
kubectl -n ingress-nginx get pods

# The NLB must have an external hostname
kubectl -n ingress-nginx get svc ingress-nginx-controller

# The Ingress must have an ADDRESS assigned
kubectl -n microservices get ingress boutique
```

## Test

With the NLB hostname:

```bash
INGRESS_LB=$(kubectl -n ingress-nginx get svc ingress-nginx-controller \
  -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')

# With no DNS configured yet:
curl -k -H "Host: shop.example.com" https://$INGRESS_LB/
```

Must return the frontend HTML.

## Files

- **`ingress.yaml`**: the main `Ingress` with typical annotations (`force-ssl-redirect`, `proxy-body-size`).
- **`examples/tls-secret.yaml.example`**: TLS Secret template for `shop.example.com`. It is NOT applied automatically with `kubectl apply -f manifests/02-ingress-nginx/` (it lives in `examples/` to avoid overwriting a real Secret with placeholders). For production, generate the Secret via cert-manager or create one with `kubectl create secret tls` before applying the Ingress.
