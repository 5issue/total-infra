# Workload Secret Publication Dispatcher

EKS 재생성 후 필요한 workload Secret publication의 표준 실행 경로를 정의합니다.

현재 다음 publication을 지원합니다.

* RabbitMQ CA trust
* Redis credential

## Bootstrap

Fresh EKS의 기본 진입점입니다.

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

RabbitMQ CA publisher는 Source CA를 기준으로 `messaging`, `backend`, `dev`의 trust Secret을 동일한 상태로 수렴시킵니다.

Redis publisher는 실행 시작 시 Secrets Manager의 `AWSCURRENT` VersionId를 고정하고 동일 credential을 `backend`, `dev`에 publication한 후 두 Target을 검증합니다.

각 publisher는 반복 실행할 수 있으며 일부 Target만 반영된 경우에도 동일 Source 기준으로 다시 수렴합니다.

## 관련 문서

* RabbitMQ CA publication: `total-k8s/workloads/rabbitmq/TRUST-PUBLICATION-RUNBOOK.md`
* RabbitMQ CA rollover: `total-k8s/workloads/rabbitmq/CA-ROLLOVER-RUNBOOK.md`
* Redis credential publication: `total-k8s/workloads/redis/CREDENTIAL-PUBLICATION-RUNBOOK.md`
