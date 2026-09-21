# Workload Secret Publication Dispatcher

EKS 재생성 후 필요한 workload Secret publication의 표준 실행 경로를 정의합니다.

현재 다음 publication을 지원합니다.

* RabbitMQ CA trust
* Redis credential

## Bootstrap

Fresh EKS의 기본 진입점입니다.

기존 공통 인증 절차로 MFA 인증된 `target-infra` profile과 해당 profile을
사용하는 EKS kubeconfig context를 먼저 준비합니다. Bootstrap은 이 세션에서
`total-workload-publication` Role을 한 번 Assume하고, 같은 1시간 이하 임시
세션으로 RabbitMQ CA와 Redis credential을 순서대로 publication합니다.
OTP를 다시 요청하거나 `target-infra` profile을 덮어쓰지 않습니다.

```bash
make workload-publication-bootstrap \
  ENV=production \
  KUBECTL_CONTEXT=arn:aws:eks:ap-northeast-2:596601390909:cluster/test-eks
```

다음 순서로 실행합니다.

1. RabbitMQ CA trust publication
2. Redis credential publication

현재 Target:

| Component        | Source                                         | Targets                                                           |
| ---------------- | ---------------------------------------------- | ----------------------------------------------------------------- |
| RabbitMQ CA      | `messaging/rabbitmq-ca-signing/tls.crt`        | `messaging/rabbitmq-ca`, `backend/rabbitmq-ca`, `dev/rabbitmq-ca` |
| Redis credential | Secrets Manager `prod/total/redis-credentials` | `backend/redis-credentials`, `dev/redis-credentials`              |

Redis workload는 `backend` Namespace의 `redis.backend.svc.cluster.local:6379`를 공유합니다.

## 개별 Publication

아래 dispatcher target은 `total-workload-publication` 임시 credential과 해당 credential을 사용하는 kubeconfig가 이미 준비된 경우 사용하는 개별 실행 경로입니다. 일반 운영에서는 직접 실행하지 않고 위 Bootstrap을 표준 경로로 사용합니다.

기본 형식:

```bash
make workload-publication \
  ENV=<environment> \
  COMPONENT=<component> \
  PHASE=<phase> \
  KUBECTL_CONTEXT=<context>
```

RabbitMQ CA:

```bash
make workload-publication \
  ENV=production \
  COMPONENT=ca \
  PHASE=publish \
  KUBECTL_CONTEXT=<context>
```

Redis credential:

```bash
make workload-publication \
  ENV=production \
  COMPONENT=redis-credential \
  PHASE=publish \
  KUBECTL_CONTEXT=<context>
```

Redis publication 상태 확인:

```bash
make workload-publication \
  ENV=production \
  COMPONENT=redis-credential \
  PHASE=verify \
  KUBECTL_CONTEXT=<context>
```

## 지원 범위

| Environment  | Component          | Phase     |
| ------------ | ------------------ | --------- |
| `production` | `ca`               | `publish` |
| `production` | `redis-credential` | `publish` |
| `production` | `redis-credential` | `verify`  |

`production` bootstrap은 production과 dev consumer가 공유하는 workload material을 함께 publication합니다.

## 실행 기준

Bootstrap은 지정된 Kubernetes context와 publication prerequisite를 확인한 후 각 publisher를 순차 실행합니다.

`KUBECTL_CONTEXT`는 EKS cluster ARN 형식이어야 합니다. Account, Region, Cluster
name은 이 ARN과 AWS `DescribeCluster` 결과를 교차 검증하며 별도 publication
상수로 관리하지 않습니다. Bootstrap이 생성하는 임시 kubeconfig에는 credential을
기록하지 않고, 종료 시 제거합니다.

RabbitMQ CA publisher는 Source CA를 기준으로 `messaging`, `backend`, `dev`의 trust Secret을 동일한 상태로 수렴시킵니다.

Redis publisher는 실행 시작 시 Secrets Manager의 `AWSCURRENT` VersionId를 고정하고 동일 credential을 `backend`, `dev`에 publication한 후 두 Target을 검증합니다.

각 publisher는 반복 실행할 수 있으며 일부 Target만 반영된 경우에도 동일 Source 기준으로 다시 수렴합니다.

## 관련 문서

* RabbitMQ CA publication: `total-k8s/workloads/rabbitmq/TRUST-PUBLICATION-RUNBOOK.md`
* RabbitMQ CA rollover: `total-k8s/workloads/rabbitmq/CA-ROLLOVER-RUNBOOK.md`
* Redis credential publication: `total-k8s/workloads/redis/CREDENTIAL-PUBLICATION-RUNBOOK.md`
