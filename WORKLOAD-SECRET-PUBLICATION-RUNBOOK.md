# Workload Secret Publication Dispatcher

`total-infra`에서 EKS 재생성 후 필요한 workload Secret publication을 일관된 진입점으로 실행하기 위한 운영 절차를 정의합니다.

현재 RabbitMQ CA trust와 Redis credential publication을 지원합니다. Fresh EKS에서는 workload publication bootstrap을 통해 필요한 publication을 순차 실행하며, 개별 component는 장애 복구 및 상태 확인 시 별도로 실행할 수 있습니다.

## 1. Production Bootstrap

EKS 재생성 후 workload Secret publication의 기본 진입점은 다음과 같습니다.

```bash
make workload-publication-bootstrap \
  ENV=production \
  KUBECTL_CONTEXT=arn:aws:eks:ap-northeast-2:596601390909:cluster/test-eks
```

현재 bootstrap은 다음 순서로 실행합니다.

1. RabbitMQ CA trust publication
2. Redis credential publication

RabbitMQ CA 단계에서는 `messaging/rabbitmq-ca-signing/tls.crt`를 기준으로 다음 세 trust Secret을 구성합니다.

* `messaging/rabbitmq-ca`
* `backend/rabbitmq-ca`
* `dev/rabbitmq-ca`

Redis 단계에서는 AWS Secrets Manager의 `prod/total/redis-credentials` 현재 `AWSCURRENT`를 `backend/redis-credentials`로 publication합니다.

각 단계는 기존 publisher에 실제 처리를 위임하며, 앞 단계가 성공한 경우 다음 단계로 진행합니다.

## 2. 개별 Publication

기본 형식:

```bash
make workload-publication \
  ENV=<environment> \
  COMPONENT=<component> \
  PHASE=<phase> \
  KUBECTL_CONTEXT=<context>
```

RabbitMQ CA trust만 publication:

```bash
make workload-publication \
  ENV=production \
  COMPONENT=ca \
  PHASE=publish \
  KUBECTL_CONTEXT=arn:aws:eks:ap-northeast-2:596601390909:cluster/test-eks
```

Redis credential publication:

```bash
make workload-publication \
  ENV=production \
  COMPONENT=redis-credential \
  PHASE=publish \
  KUBECTL_CONTEXT=arn:aws:eks:ap-northeast-2:596601390909:cluster/test-eks
```

Redis credential publication 상태 확인:

```bash
make workload-publication \
  ENV=production \
  COMPONENT=redis-credential \
  PHASE=verify \
  KUBECTL_CONTEXT=arn:aws:eks:ap-northeast-2:596601390909:cluster/test-eks
```

`total-k8s`는 기본적으로 형제 디렉터리 `../total-k8s`를 사용하며 별도 checkout 경로가 필요한 경우 `TOTAL_K8S_DIR=<path>`로 지정합니다.

## 3. 지원 기능

| Environment  | Component          | Phase     | 상태 |
| ------------ | ------------------ | --------- | -- |
| `production` | `ca`               | `publish` | 지원 |
| `production` | `redis-credential` | `publish` | 지원 |
| `production` | `redis-credential` | `verify`  | 지원 |

CA publication은 `total-k8s`의 기존 CA publisher에 위임합니다. 해당 publisher가 Source certificate 검증, Target publication 및 결과 검증을 하나의 실행 흐름으로 처리합니다.

Redis credential publication은 `total-infra`의 기존 Redis publisher에 위임합니다. `publish`는 credential publication과 결과 검증을 수행하며, `verify`는 현재 publication 상태를 확인합니다.

현재 RabbitMQ는 `messaging` Namespace의 단일 cluster를 production 및 dev Backend가 함께 사용합니다. 따라서 `dev`는 별도 CA publication environment로 관리하지 않고 동일 RabbitMQ CA의 trust consumer로 관리합니다.

## 4. RabbitMQ CA Trust 계약

RabbitMQ Cluster와 Backend workload가 사용하는 CA trust는 하나의 Source를 기준으로 관리합니다.

| Source                                      | Target                  | Key      | 소비자         |
| ------------------------------------------- | ----------------------- | -------- | ----------- |
| `messaging/rabbitmq-ca-signing` / `tls.crt` | `messaging/rabbitmq-ca` | `ca.crt` | RabbitMQ    |
| `messaging/rabbitmq-ca-signing` / `tls.crt` | `backend/rabbitmq-ca`   | `ca.crt` | Backend     |
| `messaging/rabbitmq-ca-signing` / `tls.crt` | `dev/rabbitmq-ca`       | `ca.crt` | dev Backend |

실제 publication은 다음 `total-k8s` publisher가 담당합니다.

```text
../total-k8s/workloads/rabbitmq/scripts/publish-ca-trust.sh <kubectl-context>
```

publisher는 `messaging/rabbitmq-ca-signing`의 public `tls.crt`만 사용하며 세 Target Secret에는 `ca.crt`만 제공합니다.

CA signing private key와 signing Secret 전체는 trust Target으로 전달하지 않습니다.

dispatcher는 publication 전에 다음 prerequisite를 확인합니다.

* environment / component / phase
* 승인된 kubectl context
* `total-k8s` 경로와 CA publisher
* `messaging`, `backend`, `dev` Namespace
* `messaging/rabbitmq-ca-signing` Source Secret

## 5. Redis Credential 계약

| 항목              | 값                                                  |
| --------------- | -------------------------------------------------- |
| Source of Truth | AWS Secrets Manager `prod/total/redis-credentials` |
| Source Version  | `AWSCURRENT`                                       |
| Target          | `backend/redis-credentials`                        |
| Key             | `password`                                         |
| Publisher       | `scripts/publish-redis-credentials.sh`             |

Redis publisher는 실행 시 Secrets Manager의 현재 `AWSCURRENT` VersionId를 고정하고 해당 version의 credential을 `backend/redis-credentials`에 publication합니다.

`publish`는 다음 흐름을 수행합니다.

1. AWS account 및 `test-eks` identity 확인
2. kubeconfig context와 실제 EKS endpoint 정합성 확인
3. Secrets Manager `AWSCURRENT` VersionId 고정
4. credential payload schema 확인
5. `backend/redis-credentials` publication
6. Target Secret의 source metadata 및 VersionId 검증

`verify`는 현재 `backend/redis-credentials`의 type, key schema, source metadata 및 VersionId가 Secrets Manager의 현재 `AWSCURRENT`와 일치하는지 확인합니다.

기존 개별 운영 진입점도 유지합니다.

```bash
make redis-credential-publish
make redis-credential-verify
```

## 6. Production 실행 Identity

production bootstrap은 다음 context를 승인된 대상으로 사용합니다.

```text
arn:aws:eks:ap-northeast-2:596601390909:cluster/test-eks
```

bootstrap은 지정된 `KUBECTL_CONTEXT`의 kubeconfig `exec.env.AWS_PROFILE`을 확인하고 해당 profile을 실행 identity로 사용합니다.

실행 전 다음 기준을 확인합니다.

1. `KUBECTL_CONTEXT`가 승인된 production context인지 확인
2. kubeconfig에서 `AWS_PROFILE`을 하나의 값으로 확인
3. 해당 profile로 AWS STS caller identity 확인
4. AWS Account가 `596601390909`인지 확인
5. caller ARN이 승인된 인프라 실행 주체인지 확인

승인된 caller identity는 다음과 같습니다.

* `arn:aws:iam::596601390909:user/mgmt-automation-user`
* `arn:aws:iam::596601390909:user/infra-jongwon`
* `arn:aws:iam::596601390909:user/infra-youngheon`
* `arn:aws:iam::596601390909:user/infra-mingyu`
* `arn:aws:iam::596601390909:user/infra-jaehyeok`
* `arn:aws:iam::596601390909:user/infra-jiyoon`

검증된 kubeconfig profile은 Redis publication 단계에도 동일하게 전달합니다. 이를 통해 EKS 접근 identity와 credential publication identity를 일관되게 유지합니다.

Redis publisher는 추가로 AWS에서 조회한 `test-eks` ARN 및 endpoint와 kubeconfig context의 endpoint를 대조합니다.

## 7. 실패 및 재실행

Bootstrap은 identity 및 prerequisite 검증을 완료한 뒤 publication을 시작합니다.

RabbitMQ CA publisher는 Target Secret을 create-or-patch 방식으로 구성합니다. 일부 Target 반영 후 실패한 경우 원인을 해결한 뒤 동일 publication을 재실행하여 `messaging`, `backend`, `dev`의 CA trust를 동일 Source 기준으로 수렴시킵니다.

CA 단계가 실패하면 Redis credential publication으로 진행하지 않습니다.

Redis credential publication은 Secrets Manager의 현재 `AWSCURRENT`를 기준으로 재실행할 수 있습니다. 재실행 후 `verify`를 통해 Target Secret의 source metadata 및 VersionId 정합성을 확인합니다.

상세 절차:

* RabbitMQ CA trust publication 및 복구: `total-k8s/workloads/rabbitmq/TRUST-PUBLICATION-RUNBOOK.md`
* RabbitMQ CA rollover: `total-k8s/workloads/rabbitmq/CA-ROLLOVER-RUNBOOK.md`
* Redis credential publication 및 복구: `total-k8s/workloads/redis/CREDENTIAL-PUBLICATION-RUNBOOK.md`

## 8. Fresh EKS Runtime Validation

2026-09-18 Fresh `test-eks`에서 production workload publication bootstrap을 실제 실행하여 다음 경로를 확인했습니다.

* 현재 kubeconfig AWS profile 계승 및 승인 caller identity 검증
* `messaging/rabbitmq-ca` publication
* `backend/rabbitmq-ca` publication
* `dev/rabbitmq-ca` publication
* `backend/redis-credentials` publication 및 `AWSCURRENT` VersionId 검증
* Redis StatefulSet `1/1 Ready`, `redis-0` `2/2 Running`
* RabbitMQ Cluster `AllReplicasReady=True`, `ReconcileSuccess=True`, 3개 Pod `1/1 Running`
* `dev/rabbitmq-ca` 부재로 `FailedMount` 상태였던 dev workload가 CA publication 이후 별도 Pod 재생성 없이 volume mount 및 container start 단계로 자연 수렴

RabbitMQ runtime 과정에서는 On-Demand Node의 CPU request capacity 부족으로 초기 scheduling이 지연되었습니다. dev stateless workload 일부를 임시 재배치하여 capacity를 확보한 뒤 RabbitMQ 3개 replica가 On-Demand Node에 배치되고 정상 수렴하는 것을 확인했습니다. 이 scheduling 문제는 workload Secret publication과 분리하여 배포 순서 및 placement 정책의 후속 범위로 관리합니다.

Backend Application E2E는 runtime credential injection과 WMS/OMS Application Identity 최소권한 구성이 완료된 이후 별도로 검증합니다.

## 9. 확장 원칙

Workload Secret publication은 다음 기준으로 dispatcher에 추가합니다.

* Source of Truth와 Target Secret 계약이 정의된 workload
* Secret 값을 Git 또는 실행 로그에 노출하지 않는 publication 경로
* 실행 대상과 component가 명시적으로 구분되는 publication 경로
* prerequisite 검증 후 publication을 수행하는 fail-closed 흐름

WMS/OMS RabbitMQ Application Identity는 서비스별 계정 분리와 최소권한 적용 구조를 기준으로 확장합니다. Exchange, Queue, Binding, Routing Key 등 최종 메시징 리소스 값을 반영하여 credential publication 및 permission provisioning을 추가합니다.
