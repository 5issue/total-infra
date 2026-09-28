# Workload Secret Publication

Fresh EKS 재생성 후 workload Secret을 동일한 Source 기준으로 재현하고, rotation 또는 장애 복구 시 수동으로 다시 publication하는 표준 실행 경로를 정의합니다.

현재 다음 publication을 지원합니다.

- RabbitMQ CA trust
- Redis credential
- RabbitMQ Backend/WMS/OMS application credential

## 1. Credential Source 및 영속 경계

EKS 재생성과 관계없이 유지해야 하는 workload credential의 Source는 AWS Secrets Manager에서 관리합니다.

| Component | Secrets Manager Source |
| --- | --- |
| Redis | `prod/total/redis-credentials` |
| RabbitMQ Backend | `prod/total/rabbitmq-app-credentials` |
| RabbitMQ WMS | `prod/total/rabbitmq-wms-credentials` |
| RabbitMQ OMS | `prod/total/rabbitmq-oms-credentials` |

RabbitMQ credential의 Secret container는 Terraform으로 관리하지만, 실제 `SecretVersion`과 password는 Terraform state 또는 Git에서 관리하지 않습니다.

EKS만 재생성된 경우 기존 Secrets Manager의 `AWSCURRENT`를 그대로 재사용하며 credential을 다시 발급하지 않습니다.

RabbitMQ credential Source 상태는 다음 명령으로 확인합니다.

```bash
make rabbitmq-credentials-check
```

Backend/WMS/OMS 모두 기존 `AWSCURRENT`가 존재하면 payload 계약을 검증하고 변경 없이 종료합니다.

`AWSCURRENT`가 없는 identity가 있고 신규 credential 발급이 승인된 경우에만 initializer를 실행합니다.

```bash
make rabbitmq-credentials-initialize
```

Initializer는 기존 `AWSCURRENT`가 있는 identity를 변경하지 않으며, version이 없는 identity에만 최초 credential을 생성합니다. Credential 값은 출력하거나 Terraform state, Git, 명령행 인자에 저장하지 않습니다.

## 2. Fresh EKS Publication

Fresh EKS에서 workload credential을 복구할 때는 기존 Secrets Manager Source를 확인한 뒤 workload publication bootstrap을 실행합니다.

사전 조건은 다음과 같습니다.

1. Redis와 RabbitMQ Backend/WMS/OMS Secrets Manager Source가 존재합니다.
2. 각 Source에 유일한 `AWSCURRENT` version이 존재합니다.
3. MFA 인증된 `target-infra` profile이 준비되어 있습니다.
4. 대상 EKS cluster와 kubeconfig context가 준비되어 있습니다.
5. `messaging`, `backend`, `dev` Namespace 및 RabbitMQ 기반 리소스가 생성되어 있습니다.

먼저 RabbitMQ Source를 확인합니다.

```bash
make rabbitmq-credentials-check
```

`AWSCURRENT`가 없는 identity가 있고 신규 발급이 승인된 경우에만 다음 명령을 실행합니다.

```bash
make rabbitmq-credentials-initialize
```

이후 workload credential 전체를 publication하고 검증합니다.

```bash
make publish-all-credentials \
  ENV=production \
  KUBECTL_CONTEXT=arn:aws:eks:ap-northeast-2:596601390909:cluster/test-eks
```

`publish-all-credentials`는 `workload-publication-bootstrap`을 통해 동일한 publication Role session에서 다음 순서로 처리합니다.

1. RabbitMQ CA trust publication
2. Redis credential publication
3. RabbitMQ Backend credential publication 및 검증
4. RabbitMQ WMS credential publication 및 검증
5. RabbitMQ OMS credential publication 및 검증

Bootstrap은 MFA 인증된 `target-infra` session에서 `total-workload-publication` Role을 한 번 Assume하고, 동일한 임시 session과 임시 kubeconfig를 각 publisher에 전달합니다.

Credential initializer는 Bootstrap에 포함하지 않습니다. 기존 `AWSCURRENT`를 재사용하는 것이 기본 동작이며 신규 credential 생성은 명시적으로 분리합니다.

RabbitMQ Application Identity provisioning 또한 credential publication과 분리합니다. Credential publication이 완료된 뒤 담당자가 별도의 RabbitMQ provisioning 절차를 수행합니다.

## 3. Publication Target

### RabbitMQ CA

| Source | Targets |
| --- | --- |
| `messaging/rabbitmq-ca-signing/tls.crt` | `messaging/rabbitmq-ca` |
|  | `backend/rabbitmq-ca` |
|  | `dev/rabbitmq-ca` |

### Redis Credential

| Source | Targets |
| --- | --- |
| `prod/total/redis-credentials` | `backend/redis-credentials` |
|  | `dev/redis-credentials` |

### RabbitMQ Application Credential

| Identity | Source | Kubernetes Secret | Target Namespace |
| --- | --- | --- | --- |
| Backend | `prod/total/rabbitmq-app-credentials` | `rabbitmq-app-credentials` | `messaging`, `backend`, `dev` |
| WMS | `prod/total/rabbitmq-wms-credentials` | `rabbitmq-wms-credentials` | `messaging`, `backend`, `dev` |
| OMS | `prod/total/rabbitmq-oms-credentials` | `rabbitmq-oms-credentials` | `messaging`, `backend`, `dev` |

RabbitMQ credential은 총 9개의 Kubernetes Secret으로 publication됩니다.

`messaging`의 세 credential Secret은 RabbitMQ Application Identity provisioning의 입력으로 사용합니다. `backend`와 `dev`에서는 각 workload가 자신의 Application Identity에 해당하는 credential을 사용합니다.

## 4. Publication 검증 기준

RabbitMQ credential publisher는 실행 시 identity별 현재 Secrets Manager `AWSCURRENT` VersionId를 확인합니다.

다음을 검증합니다.

- payload key가 `username`, `password` 계약과 일치하는지
- username이 Backend/WMS/OMS identity 계약과 일치하는지
- Target Secret의 `total.io/source-secret` annotation이 Source와 일치하는지
- Target Secret의 `total.io/source-version-id`가 현재 `AWSCURRENT` VersionId와 일치하는지
- `messaging`, `backend`, `dev`의 동일 identity Secret이 같은 Source VersionId를 사용하는지

`verify`를 별도로 실행하는 경우에도 현재 `AWSCURRENT`를 다시 확인하므로, 과거에 publication된 VersionId가 현재 Source와 달라진 상태를 정상으로 판단하지 않습니다.

Credential 값 자체를 로그나 검증 출력에 노출하지 않습니다.

## 5. 개별 Publication

Rotation 또는 일부 Target의 장애 복구처럼 전체 Bootstrap이 필요하지 않은 경우 dispatcher target을 사용할 수 있습니다.

이 경로는 `total-workload-publication` 임시 credential과 해당 credential을 사용하는 kubeconfig가 이미 준비된 상태를 전제로 합니다.

기본 형식:

```bash
make workload-publication \
  ENV=production \
  COMPONENT=<component> \
  PHASE=<phase> \
  KUBECTL_CONTEXT=<EKS cluster ARN>
```

RabbitMQ CA:

```bash
make workload-publication \
  ENV=production \
  COMPONENT=ca \
  PHASE=publish \
  KUBECTL_CONTEXT=<EKS cluster ARN>
```

Redis credential:

```bash
make workload-publication \
  ENV=production \
  COMPONENT=redis-credential \
  PHASE=publish \
  KUBECTL_CONTEXT=<EKS cluster ARN>

make workload-publication \
  ENV=production \
  COMPONENT=redis-credential \
  PHASE=verify \
  KUBECTL_CONTEXT=<EKS cluster ARN>
```

RabbitMQ Backend credential:

```bash
make workload-publication \
  ENV=production \
  COMPONENT=rabbitmq-credential \
  PHASE=publish \
  KUBECTL_CONTEXT=<EKS cluster ARN>

make workload-publication \
  ENV=production \
  COMPONENT=rabbitmq-credential \
  PHASE=verify \
  KUBECTL_CONTEXT=<EKS cluster ARN>
```

RabbitMQ WMS credential:

```bash
make workload-publication \
  ENV=production \
  COMPONENT=wms-credential \
  PHASE=publish \
  KUBECTL_CONTEXT=<EKS cluster ARN>

make workload-publication \
  ENV=production \
  COMPONENT=wms-credential \
  PHASE=verify \
  KUBECTL_CONTEXT=<EKS cluster ARN>
```

RabbitMQ OMS credential:

```bash
make workload-publication \
  ENV=production \
  COMPONENT=oms-credential \
  PHASE=publish \
  KUBECTL_CONTEXT=<EKS cluster ARN>

make workload-publication \
  ENV=production \
  COMPONENT=oms-credential \
  PHASE=verify \
  KUBECTL_CONTEXT=<EKS cluster ARN>
```

## 6. 지원 범위

| Environment | Component | Phase |
| --- | --- | --- |
| `production` | `ca` | `publish` |
| `production` | `redis-credential` | `publish`, `verify` |
| `production` | `rabbitmq-credential` | `publish`, `verify` |
| `production` | `wms-credential` | `publish`, `verify` |
| `production` | `oms-credential` | `publish`, `verify` |

`production` publication은 production과 dev consumer가 공유하는 workload material을 함께 publication합니다.

## 7. 실행 안전장치

`KUBECTL_CONTEXT`는 대상 EKS cluster를 명시적으로 지정합니다.

Publisher는 AWS account, region, EKS cluster 및 Kubernetes context가 repository 계약과 일치하는지 사전 검증합니다.

Bootstrap이 생성하는 임시 kubeconfig에는 장기 credential을 기록하지 않으며 종료 시 제거합니다.

각 publisher는 반복 실행할 수 있으며 일부 Target만 반영된 경우에도 동일 Source 기준으로 다시 수렴합니다.

RabbitMQ credential publisher는 Secrets Manager Source가 삭제 예약 상태이면 실행을 중단합니다.

불완전한 AWS session credential 환경도 거부하며, Bootstrap이 전달한 publication Role session 또는 명시된 AWS profile을 사용합니다.

## 8. RabbitMQ Application Identity Provisioning과의 경계

이 문서의 완료 범위는 **credential Source 확인 → Kubernetes Secret publication → Source Version 검증**까지입니다.

RabbitMQ runtime의 다음 항목은 Application Identity provisioning 단계에서 처리합니다.

- `total-prod` vhost
- `total-backend`
- `total-wms`
- `total-oms`
- Resource Permission
- Topic Permission
- management tag 검증

따라서 Kubernetes Secret publication 성공만으로 RabbitMQ 계정 분리가 완료된 것으로 판단하지 않습니다.

Fresh EKS에서는 publication 완료 후 `rabbitmq-provisioning-app`을 동기화하고 provisioning Job의 최종 검증을 별도로 완료해야 합니다.

## 9. 관련 문서

- RabbitMQ CA publication: `total-k8s/workloads/rabbitmq/TRUST-PUBLICATION-RUNBOOK.md`
- RabbitMQ CA rollover: `total-k8s/workloads/rabbitmq/CA-ROLLOVER-RUNBOOK.md`
- RabbitMQ Application Identity 및 연결 계약: `total-k8s/workloads/rabbitmq/README.md`
- Redis credential 및 연결 계약: `total-k8s/workloads/redis/README.md`
