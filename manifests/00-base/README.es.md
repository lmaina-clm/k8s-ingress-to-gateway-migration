[English](README.md) | **Español**

# manifests/00-base

Recursos compartidos por todas las fases:

- **`namespaces.yaml`**: crea los namespaces `microservices` y `gateway-system`, con los labels que necesitan los `allowedRoutes` del Gateway. NO depende de los CRDs de Gateway API, así que se puede aplicar en cualquier momento.
- **`reference-grant.yaml`**: el `ReferenceGrant` que permite que los `HTTPRoute` de `microservices` referencien al `Gateway` en `gateway-system`. **Requiere los CRDs de Gateway API instalados** — aplicar DESPUÉS de instalar NGF.

## Aplicar

```bash
# Antes de instalar Gateway API (cualquier momento)
kubectl apply -f manifests/00-base/namespaces.yaml

# Después de instalar Gateway API CRDs + NGF
kubectl apply -f manifests/00-base/reference-grant.yaml
```

## Verificar

```bash
kubectl get namespace microservices gateway-system
kubectl get referencegrant -n gateway-system
```

Ambos namespaces deben existir; el `ReferenceGrant` también, después de instalar Gateway API.
