# manifests/00-base

Recursos compartidos por todas las fases:

- **`namespaces.yaml`**: crea `microservices` y `gateway-system`, con los labels que necesitan los `allowedRoutes` del Gateway. Incluye el `ReferenceGrant` que permite que los `HTTPRoute` de `microservices` referencien al `Gateway` en `gateway-system`.

## Aplicar

```bash
kubectl apply -f manifests/00-base/
```

## Verificar

```bash
kubectl get namespace microservices gateway-system
kubectl get referencegrant -n gateway-system
```

Ambos namespaces deben existir, el `ReferenceGrant` también. Esto se aplica **antes** de cualquier `Gateway` o `HTTPRoute`.
