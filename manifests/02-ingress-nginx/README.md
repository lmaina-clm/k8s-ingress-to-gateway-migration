# manifests/02-ingress-nginx — Estado inicial

Estado de la arquitectura **antes** de la migración:

- `ingress-nginx` instalado vía Helm (ver `scripts/install-ingress-nginx.sh`).
- Un `Ingress` apuntando al servicio `frontend` de Online Boutique.
- TLS terminado en el Ingress (cert auto-firmado por defecto; sustituye con tu cert real).

## Aplicar

Primero el controller:

```bash
./scripts/install-ingress-nginx.sh
```

Luego los recursos Ingress:

```bash
kubectl apply -f manifests/02-ingress-nginx/
```

## Verificar

```bash
# El controller debe estar Running
kubectl -n ingress-nginx get pods

# El NLB debe tener un hostname externo
kubectl -n ingress-nginx get svc ingress-nginx-controller

# El Ingress debe tener una ADDRESS asignada
kubectl -n microservices get ingress boutique
```

## Probar

Con el hostname del NLB:

```bash
INGRESS_LB=$(kubectl -n ingress-nginx get svc ingress-nginx-controller \
  -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')

# Sin DNS configurado todavía:
curl -k -H "Host: shop.example.com" https://$INGRESS_LB/
```

Debe devolver el HTML del frontend.

## Archivos

- **`tls-secret.yaml`**: Secret con cert self-signed para `shop.example.com`. Reemplazar con un cert real para producción (vía cert-manager u otro método).
- **`ingress.yaml`**: el `Ingress` principal con anotaciones típicas (`force-ssl-redirect`, `proxy-body-size`).
