**English** | [Español](07-troubleshooting.es.md)

# 07 — Troubleshooting

Problems you'll encounter (or already encountered, which is why you're reading this).

## General diagnostics

Before looking for your specific problem, **always** run:

```bash
# 1. Are the CRDs there?
kubectl get crd | grep gateway.networking.k8s.io

# 2. Is the control plane healthy?
kubectl get pods -n nginx-gateway

# 3. Is the GatewayClass accepted?
kubectl describe gatewayclass nginx-gateway | grep -A5 Conditions

# 4. Is the Gateway programmed?
kubectl describe gateway -n gateway-system boutique-gateway

# 5. Are the HTTPRoutes accepted?
kubectl get httproute -A -o wide
kubectl describe httproute -n microservices boutique-route

# 6. Is the data plane running?
kubectl get pods -n gateway-system

# 7. Control plane logs
kubectl logs -n nginx-gateway -l app.kubernetes.io/name=nginx-gateway-fabric --tail=50

# 8. Data plane (NGINX) logs
kubectl logs -n gateway-system -l gateway.networking.k8s.io/gateway-name=boutique-gateway --tail=50
```

80% of problems are caught by one of these commands.

## Common problems

### The `Gateway` is stuck in `Programmed=False`

**Symptoms**:
```
NAME                CLASS           ADDRESS   PROGRAMMED   AGE
boutique-gateway    nginx-gateway             False        5m
```

**Causes and solutions**:

1. **No GatewayClass**:
   ```bash
   kubectl get gatewayclass nginx-gateway
   ```
   If empty, NGF isn't installed. Go back to phase 2.

2. **TLS Secret doesn't exist in the correct namespace**:
   ```bash
   kubectl get secret -n gateway-system shop-tls
   ```
   Solution: copy the secret to the Gateway's namespace, or use a `ReferenceGrant` to allow cross-namespace reference.

3. **Hostname conflict with another Gateway**:
   ```bash
   kubectl get gateway -A
   ```
   If two Gateways share the same hostname, NGF rejects one.

4. **AWS Load Balancer Controller doesn't respond**:
   ```bash
   kubectl logs -n kube-system deployment/aws-load-balancer-controller --tail=50
   ```
   If there are IAM or subnet errors, the NLB isn't created.

### `HTTPRoute` with `Accepted=False`

**Symptoms**:
```bash
kubectl describe httproute boutique-route -n microservices
# Conditions: Accepted=False
```

**Common cause**: the `parentRef` points to a Gateway that doesn't exist or doesn't allow routes from that namespace.

```yaml
# In the Gateway, review:
spec:
  listeners:
    - name: https
      allowedRoutes:
        namespaces:
          from: Selector
          selector:
            matchLabels:
              gateway-access: "true"
```

Your `microservices` namespace must have the label:

```bash
kubectl label namespace microservices gateway-access=true
```

### `HTTPRoute` with `ResolvedRefs=False`

**Cause**: the `backendRef` points to a service that doesn't exist or is in another namespace without a `ReferenceGrant`.

```bash
kubectl get service -n microservices frontend
kubectl describe httproute boutique-route -n microservices | grep -A3 ResolvedRefs
```

### Traffic reaches the Gateway but returns 502/503

**Symptoms**: `curl` to the NLB → status 502.

**Diagnosis**:

```bash
# 1. View the NGINX data plane logs
kubectl logs -n gateway-system -l gateway.networking.k8s.io/gateway-name=boutique-gateway --tail=100

# 2. View backend Service endpoints
kubectl get endpoints -n microservices frontend
# If "ENDPOINTS" is empty: the Service has no pods. Problem in the deployment.

# 3. Verify the data plane pod can reach the backend pod
kubectl exec -n gateway-system <data-plane-pod> -- \
  curl -v http://frontend.microservices.svc.cluster.local
```

Typical causes:
- **Restrictive NetworkPolicy**: blocks traffic from `gateway-system` to `microservices`. Add a `NetworkPolicy` that allows it.
- **Service on a different port**: the `HTTPRoute` points to `port: 80` but the Service exposes `port: 8080`.
- **Backend down**: the frontend pod is crash-looping.

### Traffic reaches the Gateway NLB but doesn't reach the pod

**Diagnosis**:

```bash
# Does the NLB have healthy targets?
TG_ARN=$(aws elbv2 describe-target-groups --region <region> \
  --load-balancer-arn $(aws elbv2 describe-load-balancers --region <region> \
    --query "LoadBalancers[?contains(LoadBalancerName,'k8s-gateway')].LoadBalancerArn" \
    --output text) \
  --query 'TargetGroups[0].TargetGroupArn' --output text)

aws elbv2 describe-target-health --target-group-arn $TG_ARN --region <region>
```

If targets are `unhealthy`:
- **The NLB Security Group doesn't allow traffic to the nodeport/pod port**.
- **The target group health check points to a path that returns 404**.

### Intermittent `502 Bad Gateway` only in real traffic (not in `curl`)

Typically: **upstream keepalive timeout**. NGINX closes a persistent connection, but the client tries to reuse it.

**Solution**: configure `ClientSettingsPolicy` or `NginxProxy` with adjusted timeouts.

```yaml
apiVersion: gateway.nginx.org/v1alpha1
kind: NginxProxy
metadata:
  name: boutique-proxy
spec:
  ipFamily: dual
  telemetry:
    serviceName: boutique
  # Adjust timeouts if the defaults don't fit
```

### `502` only on POST with large body

Cause: `client_max_body_size` default in NGF is 1MB.

**Solution**:

```yaml
apiVersion: gateway.nginx.org/v1alpha1
kind: ClientSettingsPolicy
metadata:
  name: large-body
  namespace: gateway-system
spec:
  targetRef:
    group: gateway.networking.k8s.io
    kind: Gateway
    name: boutique-gateway
  body:
    maxSize: "10m"
```

### Higher p99 latency than with `ingress-nginx`

**Possible causes**:

1. **NGF cache isn't warmed yet** — first minutes. Wait.
2. **The new NLB is in different availability zones than the pods**. Verify:
   ```bash
   kubectl get svc -n gateway-system -o wide
   # Compare the zones with those of the backend pods
   ```
3. **More hops**: NGF has the control-plane separate from the data-plane. This doesn't affect requests (they don't go through the control-plane), but TLS handshakes can be slightly slower.
4. **Different buffering**: `proxy_buffering` in NGF can have different defaults. Adjust with `ProxySettingsPolicy` if you have streaming.

### DNS doesn't update after changing the weighted record

```bash
# Force resolution without cache
dig +nocache shop.example.com

# Test against multiple resolvers
dig @8.8.8.8 shop.example.com
dig @1.1.1.1 shop.example.com
```

If Route 53 already has the new value but clients don't see it: **local DNS cache** on the client. Wait for TTL.

### `cert-manager` doesn't emit a cert for the Gateway

If you use cert-manager < v1.14, **it doesn't understand `Gateway` yet**. Upgrade to 1.14+.

With cert-manager 1.14+:

```yaml
# The Certificate points to the Secret that the Gateway will reference
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: shop-tls
  namespace: gateway-system
spec:
  secretName: shop-tls
  dnsNames:
    - shop.example.com
  issuerRef:
    name: letsencrypt-prod
    kind: ClusterIssuer
```

And reference the secret in `Gateway.spec.listeners[].tls.certificateRefs`.

## Observability: metric names

Prometheus metric mapping from `ingress-nginx` to NGF:

| `ingress-nginx` | NGINX Gateway Fabric |
|-----------------|----------------------|
| `nginx_ingress_controller_requests` | `nginxplus_http_requests_total` (with NGINX Plus) or `nginx_http_requests_total` |
| `nginx_ingress_controller_request_duration_seconds_bucket` | `nginxplus_http_request_duration_seconds_bucket` |
| `nginx_ingress_controller_response_size_bucket` | `nginxplus_http_response_size_bytes_bucket` |
| `nginx_ingress_controller_nginx_process_*` | `nginx_process_*` |

To get metrics, NGF exposes a Prometheus endpoint on the data plane. Configure your `ServiceMonitor`:

```yaml
apiVersion: monitoring.coreos.com/v1
kind: ServiceMonitor
metadata:
  name: nginx-gateway-fabric
  namespace: gateway-system
spec:
  selector:
    matchLabels:
      gateway.networking.k8s.io/gateway-name: boutique-gateway
  endpoints:
    - port: metrics
      interval: 30s
```

## Upgrade NGF 1.x → 2.x

If for some reason you have NGF 1.x already installed: the upgrade requires uninstall and reinstall because the installation model changes (control/data plane separation is 2.x).

```bash
# 1. Full backup
kubectl get gateway,httproute,grpcroute -A -o yaml > /tmp/ngf-backup.yaml

# 2. Uninstall 1.x (keeps CRDs)
helm uninstall nginx-gateway -n nginx-gateway

# 3. Install 2.6.x
./scripts/install-nginx-gateway-fabric.sh

# 4. Restore resources
kubectl apply -f /tmp/ngf-backup.yaml
```

**Important**: during this upgrade there is **downtime** for the Gateway. That's why it's best to do it before the productive migration, not as part of it.

## TLS at the NLB (ACM instead of the Gateway)

If you prefer to terminate TLS at the NLB with AWS ACM:

1. The Gateway listener is **HTTP**, not HTTPS.
2. The NLB is configured with AWS Load Balancer Controller annotations to terminate TLS.

```yaml
# On the data plane Service (NGF creates it, but you can override via Helm values):
apiVersion: v1
kind: Service
metadata:
  annotations:
    service.beta.kubernetes.io/aws-load-balancer-ssl-cert: arn:aws:acm:...
    service.beta.kubernetes.io/aws-load-balancer-ssl-ports: "443"
    service.beta.kubernetes.io/aws-load-balancer-backend-protocol: tcp
```

Pros: ACM auto-renews, AWS WAF integration.
Cons: TLS terminates at the NLB, so the Gateway doesn't see SNI nor can it route by hostname with different certs.

---

Next: [`08-faq.md`](./08-faq.md)
