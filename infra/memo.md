### 실행 순서

```bash

total-infra에서 실행
make apply

total-k8s에서 실행
kubectl apply -f k8s/argocd/ -f k8s/frontend/ -f k8s/grafana/
```

### ingress
kubectl get ingress -A


### Auto Scaling Group 크기를 0으로 강제 축소
```bash
ASG_NAME=$(aws autoscaling describe-auto-scaling-groups --region ap-northeast-2 --query "AutoScalingGroups[?contains(AutoScalingGroupName, 'worker_node') || contains(Tags[?Key=='eks:cluster-name'].Value, 'test-eks')].AutoScalingGroupName" --output text)

if [ -n "$ASG_NAME" ]; then
    echo "대상 ASG 발견: $ASG_NAME. 크기를 0으로 조정합니다."
    aws autoscaling update-auto-scaling-group --auto-scaling-group-name "$ASG_NAME" --min-size 0 --max-size 0 --desired-capacity 0 --region ap-northeast-2
else
    echo "ASG를 찾지 못했습니다."
fi
```

### 기존 인스턴스 즉시 종료 (재생성 방지됨)
```bash
INSTANCE_IDS=$(aws ec2 describe-instances --region ap-northeast-2 --filters "Name=tag:eks:cluster-name,Values=test-eks" "Name=instance-state-name,Values=pending,running" --query "Reservations[*].Instances[*].InstanceId" --output text)

if [ -n "$INSTANCE_IDS" ]; then
    aws ec2 terminate-instances --instance-ids $INSTANCE_IDS --region ap-northeast-2
    echo "기존 인스턴스 강제 종료 완료!"
fi
```

### workload-publication
```bash
make workload-publication-bootstrap \
  ENV=dev \
  KUBECTL_CONTEXT=$(kubectl config current-context)
``