**English** | [Español](README.es.md)

# manifests/00-base

Resources shared across all phases:

- **`namespaces.yaml`**: creates the `microservices` and `gateway-system` namespaces, with the labels required by the Gateway's `allowedRoutes`. Does NOT depend on Gateway API CRDs, so it can be applied at any time.
- **`reference-grant.yaml`**: the `ReferenceGrant` that allows `HTTPRoute`s in `microservices` to reference the `Gateway` in `gateway-system`. **Requires Gateway API CRDs installed** — apply AFTER installing NGF.

## Apply

```bash
# Before installing Gateway API (anytime)
kubectl apply -f manifests/00-base/namespaces.yaml

# After installing Gateway API CRDs + NGF
kubectl apply -f manifests/00-base/reference-grant.yaml
```

## Verify

```bash
kubectl get namespace microservices gateway-system
kubectl get referencegrant -n gateway-system
```

Both namespaces must exist; the `ReferenceGrant` too, after installing Gateway API.
