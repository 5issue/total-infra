### 실행 순서

```bash

total-infra에서 실행
make apply

total-k8s에서 실행
kubectl apply -f k8s/argocd/ -f k8s/frontend/ -f k8s/grafana/
```


### ingress

kubectl get ingress -A
