# RabbitMQ Credential and Kubernetes Secret Reproduction

이 문서는 EKS 재생성 후 `total-backend`, `total-wms`, `total-oms` RabbitMQ
계정 분리를 동일하게 재현하는 절차를 정의합니다. 실제 credential 값은 출력하거나
Terraform state, Git, 명령행 인자에 저장하지 않습니다.

## 1. 영속 경계

`init/secrets.tf`는 다음 AWS Secrets Manager **컨테이너만** 관리합니다.

| Identity | Secrets Manager | Username |
| --- | --- | --- |
| Backend | `prod/total/rabbitmq-app-credentials` | `total-backend` |
| WMS | `prod/total/rabbitmq-wms-credentials` | `total-wms` |
| OMS | `prod/total/rabbitmq-oms-credentials` | `total-oms` |

SecretVersion과 password는 Terraform이 관리하지 않습니다. EKS만 재생성하고 위
Secrets Manager 리소스를 유지했다면 기존 `AWSCURRENT`도 유지되므로 credential을
다시 발급하지 않습니다.

최초 version이 필요한 경우에만 initializer를 사용합니다. Initializer는 기존
`AWSCURRENT`가 있으면 payload 계약을 확인하고 변경 없이 종료하며, 없는 identity에만
64자리 hex password를 생성해 최초 version을 저장합니다.

```bash
make rabbitmq-credentials-check

# check가 AWSCURRENT 없음으로 실패하고 신규 발급이 승인된 경우에만 실행
make rabbitmq-credentials-initialize
```

두 target은 MFA 인증된 `target-infra` profile, AWS account `596601390909`, region
`ap-northeast-2`를 검증합니다. Password는 권한이 `0700`인 임시 디렉터리 안에서만
생성되고 Secrets Manager 저장 후 제거됩니다.

## 2. Kubernetes Secret 배치

각 source version은 다음 9개 Kubernetes Secret으로 publication됩니다.

| Namespace | Backend | WMS | OMS |
| --- | --- | --- | --- |
| `messaging` | `rabbitmq-app-credentials` | `rabbitmq-wms-credentials` | `rabbitmq-oms-credentials` |
| `backend` | `rabbitmq-app-credentials` | `rabbitmq-wms-credentials` | `rabbitmq-oms-credentials` |
| `dev` | `rabbitmq-app-credentials` | `rabbitmq-wms-credentials` | `rabbitmq-oms-credentials` |

`messaging`의 세 Secret은 RabbitMQ provisioning Job이 사용합니다. `backend`와
`dev`에서는 WMS가 WMS Secret, OMS가 OMS Secret, 나머지 Backend 서비스가 기존
Backend Secret을 사용합니다. 따라서 9개 모두 현재 배포 구조의 소비자 또는
provisioning 입력입니다.

Publisher는 실행 시작 시 identity별 `AWSCURRENT` VersionId를 고정하고 다음을
검증합니다.
`verify`만 실행할 때도 현재 `AWSCURRENT`를 다시 확인합니다.

- payload key가 정확히 `username`, `password`인지
- username이 identity 계약과 일치하는지
- 세 Namespace Secret의 `total.io/source-secret` 및
  `total.io/source-version-id` annotation이 source와 일치하는지
- 세 Namespace가 동일 source VersionId인지

## 3. Fresh EKS 실행 순서

### 사전 조건

1. `init` Terraform stack에 세 Secrets Manager 컨테이너가 존재합니다. 없으면
   `make base-plan`으로 전체 init stack 변경을 검토하고 승인 후 `make base`를
   실행합니다. Secret 컨테이너만을 위한 임의 targeted apply를 표준 절차로 사용하지
   않습니다.
2. MFA 인증된 `target-infra` profile과 대상 EKS ARN context가 준비되어 있습니다.
3. Argo CD가 `messaging`, `backend`, `dev` Namespace와 RabbitMQ 기반 리소스를
   생성했습니다.
4. `rabbitmq-app`이 정상화되어 다음 리소스가 준비되어 있습니다.
   - `messaging/rabbitmq-ca-signing`
   - `messaging/rabbitmq-server-tls`
   - `messaging/rabbitmq-default-user`
   - `RabbitmqCluster/rabbitmq`

### 실행

```bash
# 1. 기존 AWSCURRENT 재사용 가능 여부 확인
make rabbitmq-credentials-check

# 2. AWSCURRENT가 없는 identity가 있고 신규 발급이 승인된 경우에만
make rabbitmq-credentials-initialize

# 3. CA/Redis와 RabbitMQ Backend/WMS/OMS credential publication 및 검증
make publish-all-credentials \
  ENV=production \
  KUBECTL_CONTEXT=arn:aws:eks:ap-northeast-2:596601390909:cluster/test-eks

# 4. RabbitMQ Application identity provisioning
argocd app sync rabbitmq-provisioning-app

# 5. Job 완료 확인
kubectl --context arn:aws:eks:ap-northeast-2:596601390909:cluster/test-eks \
  --namespace messaging \
  wait --for=condition=complete \
  job/rabbitmq-application-provisioning \
  --timeout=300s
```

`publish-all-credentials`는 다음 순서로 실행됩니다.

1. RabbitMQ CA trust publication
2. Redis credential publication
3. Backend RabbitMQ credential publish/verify
4. WMS RabbitMQ credential publish/verify
5. OMS RabbitMQ credential publish/verify

위 다섯 단계는 `target-infra` session에서 한 번 Assume한
`total-workload-publication` Role의 동일한 임시 session과 임시 kubeconfig를
사용합니다. 이 target은 Credential initializer를 실행하거나
`rabbitmq-provisioning-app`을 동기화하지 않습니다.

RabbitMQ credential만 개별 확인할 경우에는 Publication Role 임시 credential과
해당 credential을 사용하는 kubeconfig가 이미 준비된 상태에서 Dispatcher target을
사용합니다. 모든 target에 동일한 `KUBECTL_CONTEXT`를 전달합니다.

```bash
make workload-publication ENV=production COMPONENT=rabbitmq-credential PHASE=verify \
  KUBECTL_CONTEXT=<EKS cluster ARN>
make workload-publication ENV=production COMPONENT=wms-credential PHASE=verify \
  KUBECTL_CONTEXT=<EKS cluster ARN>
make workload-publication ENV=production COMPONENT=oms-credential PHASE=verify \
  KUBECTL_CONTEXT=<EKS cluster ARN>
```

Application identity provisioning은 위 publication과 분리하며, 담당자가 Argo CD에서
`rabbitmq-provisioning-app`을 수동 동기화합니다.

## 4. 완료 기준

다음을 모두 확인해야 계정 분리가 재현된 것입니다.

- `rabbitmq-provisioning-app`: `Synced`, `Healthy`
- `rabbitmq-application-provisioning`: `Complete=True`
- `total-prod` vhost 존재
- `total-backend`, `total-wms`, `total-oms` user 존재, management tag 없음
- Backend permission: configure/write/read `.*`
- WMS permission:
  - configure `^(order\.topic\.exchange|session\.topic\.exchange|wms\.topic\.exchange|wms\.inventory\.confirm\.(queue|dlq))$`
  - write `^(amq\.default|session\.topic\.exchange|wms\.topic\.exchange|wms\.inventory\.confirm\.queue)$`
  - read `^(order\.topic\.exchange|wms\.inventory\.confirm\.queue)$`
- WMS topic permission: exchange `wms.topic.exchange`, write
  `^wms\.(inbound\.completed|outbound\.completed|return\.inspected)$`, read `^$`
- OMS permission:
  - configure `^(session\.topic\.exchange|oms\.topic\.exchange|oms\.(order-payment-completed|return-requested|wms-inspected|payment-refunded)\.(queue|dlq))$`
  - write `^(amq\.default|session\.topic\.exchange|oms\.topic\.exchange|oms\.(order-payment-completed|return-requested|wms-inspected|payment-refunded)\.queue)$`
  - read `^(order\.topic\.exchange|payment\.topic\.exchange|oms\.topic\.exchange|wms\.topic\.exchange|oms\.(order-payment-completed|return-requested|wms-inspected|payment-refunded)\.queue)$`
- OMS topic permission: exchange `wms.topic.exchange`, write `^$`, read
  `^wms\.return\.inspected$`
- Backend에는 topic permission이 없고 WMS/OMS에는 위 단일 topic permission만 존재

검증 중 Secret의 `.data`, Secrets Manager `SecretString` 또는 password를 출력하지
않습니다. 실제 메시지 발행·구독 시험은 별도 애플리케이션 검증 절차입니다.
