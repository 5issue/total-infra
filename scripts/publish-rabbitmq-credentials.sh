#!/usr/bin/env bash
set -euo pipefail
umask 077

# 이 스크립트는 기존 AWSCURRENT SecretVersion만 조회·배포합니다.
# 매 실행마다 AWSCURRENT를 다시 resolve하고, 해당 실행의 두 Namespace에는 같은 VersionId를 사용합니다.
# 최초 SecretVersion 생성과 credential 갱신은 별도 initializer/운영 절차에서 수행해야 합니다.

readonly EXPECTED_AWS_ACCOUNT_ID="596601390909"
readonly EXPECTED_AWS_REGION="ap-northeast-2"
readonly EXPECTED_EKS_CLUSTER_NAME="test-eks"
readonly SECRET_NAME="prod/total/rabbitmq-app-credentials"
readonly KUBERNETES_SECRET_NAME="rabbitmq-app-credentials"
readonly EXPECTED_USERNAME="total-backend"
readonly SOURCE_SECRET_ANNOTATION="total.io/source-secret"
readonly SOURCE_VERSION_ANNOTATION="total.io/source-version-id"
readonly KUBECTL_REQUEST_TIMEOUT="20s"

readonly AWS_PROFILE="${AWS_PROFILE:-target-infra}"
readonly AWS_REGION="${AWS_REGION:-$EXPECTED_AWS_REGION}"
readonly EKS_CLUSTER_NAME="${EKS_CLUSTER_NAME:-$EXPECTED_EKS_CLUSTER_NAME}"

secret_payload=""
source_version_id=""
expected_eks_endpoint=""
verified_version_id=""

cleanup() {
  unset secret_payload
}
trap cleanup EXIT

log() {
  printf '[rabbitmq-credential] %s\n' "$*"
}

die() {
  printf '[rabbitmq-credential] ERROR: %s\n' "$*" >&2
  exit 1
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || die "필수 명령을 찾을 수 없습니다: $1"
}

configure_aws_environment() {
  # kubeconfig의 aws exec plugin도 지정된 profile만 사용하도록 ambient credential을 제거합니다.
  unset AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN AWS_SECURITY_TOKEN
  unset AWS_ROLE_ARN AWS_WEB_IDENTITY_TOKEN_FILE AWS_DEFAULT_PROFILE
  export AWS_PROFILE AWS_REGION
  export AWS_DEFAULT_REGION="$AWS_REGION"
  export AWS_PAGER=""
  export AWS_CLI_AUTO_PROMPT="off"
}

validate_repository_contract() {
  [[ "$AWS_REGION" == "$EXPECTED_AWS_REGION" ]] || \
    die "AWS_REGION이 repository 계약과 다릅니다."
  [[ "$EKS_CLUSTER_NAME" == "$EXPECTED_EKS_CLUSTER_NAME" ]] || \
    die "EKS_CLUSTER_NAME이 repository 계약과 다릅니다."
}

aws_preflight() {
  local caller_identity caller_account caller_arn
  local cluster_identity cluster_arn

  log "AWS preflight: profile=$AWS_PROFILE region=$AWS_REGION"

  if ! caller_identity="$(
    aws sts get-caller-identity \
      --profile "$AWS_PROFILE" \
      --region "$AWS_REGION" \
      --query '[Account,Arn]' \
      --output text
  )"; then
    die "STS caller identity 확인에 실패했습니다."
  fi

  IFS=$'\t' read -r caller_account caller_arn <<<"$caller_identity"
  [[ "$caller_account" == "$EXPECTED_AWS_ACCOUNT_ID" ]] || \
    die "AWS account가 repository 계약과 다릅니다."
  [[ -n "$caller_arn" && "$caller_arn" != "None" ]] || \
    die "AWS principal ARN을 확인할 수 없습니다."

  if ! cluster_identity="$(
    aws eks describe-cluster \
      --profile "$AWS_PROFILE" \
      --region "$AWS_REGION" \
      --name "$EKS_CLUSTER_NAME" \
      --query 'cluster.[arn,endpoint]' \
      --output text
  )"; then
    die "대상 EKS cluster를 확인할 수 없습니다. EKS를 생성하지 않고 종료합니다."
  fi

  IFS=$'\t' read -r cluster_arn expected_eks_endpoint <<<"$cluster_identity"
  [[ "$cluster_arn" == "arn:aws:eks:${EXPECTED_AWS_REGION}:${EXPECTED_AWS_ACCOUNT_ID}:cluster/${EXPECTED_EKS_CLUSTER_NAME}" ]] || \
    die "EKS cluster ARN이 repository 계약과 다릅니다."
  [[ -n "$expected_eks_endpoint" && "$expected_eks_endpoint" != "None" ]] || \
    die "EKS endpoint를 확인할 수 없습니다."

  log "AWS account 및 EKS cluster 확인 완료"
}

kubernetes_preflight() {
  local current_context current_server kube_exec_command kube_exec_cluster
  local kube_exec_profile kube_exec_role kube_exec_region namespace

  if ! current_context="$(kubectl config current-context 2>/dev/null)"; then
    die "현재 kubeconfig context를 확인할 수 없습니다."
  fi
  [[ -n "$current_context" ]] || die "현재 kubeconfig context가 비어 있습니다."

  current_server="$(kubectl config view --minify -o jsonpath='{.clusters[0].cluster.server}')"
  [[ "$current_server" == "$expected_eks_endpoint" ]] || \
    die "현재 kubeconfig context가 대상 EKS endpoint와 일치하지 않습니다."

  kube_exec_command="$(kubectl config view --minify -o jsonpath='{.users[0].user.exec.command}')"
  [[ "$(basename -- "$kube_exec_command")" == "aws" ]] || \
    die "현재 kubeconfig context가 AWS exec authentication을 사용하지 않습니다."

  kube_exec_cluster="$(
    kubectl config view --minify -o json | jq -r '
      .users[0].user.exec.args as $args
      | ($args | index("--cluster-name")) as $index
      | if $index == null then "" else $args[$index + 1] end
    '
  )"
  [[ "$kube_exec_cluster" == "$EXPECTED_EKS_CLUSTER_NAME" ]] || \
    die "kubeconfig exec cluster가 repository 계약과 다릅니다."

  kube_exec_region="$(
    kubectl config view --minify -o json | jq -r '
      .users[0].user.exec.args as $args
      | ($args | index("--region")) as $index
      | if $index == null then "" else $args[$index + 1] end
    '
  )"
  [[ -z "$kube_exec_region" || "$kube_exec_region" == "$EXPECTED_AWS_REGION" ]] || \
    die "kubeconfig exec region이 repository 계약과 다릅니다."

  kube_exec_profile="$(
    kubectl config view --minify -o json | jq -r '
      [.users[0].user.exec.env[]? | select(.name == "AWS_PROFILE") | .value][0] // ""
    '
  )"
  [[ -z "$kube_exec_profile" || "$kube_exec_profile" == "$AWS_PROFILE" ]] || \
    die "kubeconfig exec profile이 요청된 AWS profile과 다릅니다."

  kube_exec_role="$(
    kubectl config view --minify -o json | jq -r '
      .users[0].user.exec.args as $args
      | ($args | index("--role-arn")) as $index
      | if $index == null then "" else $args[$index + 1] end
    '
  )"
  [[ -z "$kube_exec_role" ]] || \
    die "repository에 정의되지 않은 kubeconfig role override가 있습니다."

  for namespace in messaging backend; do
    if ! kubectl --request-timeout="$KUBECTL_REQUEST_TIMEOUT" get namespace "$namespace" -o name >/dev/null; then
      die "Namespace가 없거나 접근할 수 없습니다: $namespace"
    fi
  done

  log "Kubernetes preflight 완료: context=$current_context"
}

resolve_secret_version() {
  local secret_metadata

  if ! secret_metadata="$(
    aws secretsmanager describe-secret \
      --profile "$AWS_PROFILE" \
      --region "$AWS_REGION" \
      --secret-id "$SECRET_NAME" \
      --output json
  )"; then
    die "RabbitMQ Secrets Manager metadata 조회에 실패했습니다."
  fi

  if ! source_version_id="$(
    printf '%s' "$secret_metadata" | jq -er '
      .VersionIdsToStages
      | to_entries
      | map(select(.value | index("AWSCURRENT")))
      | if length == 1 then .[0].key else error("AWSCURRENT VersionId must be unique") end
    '
  )"; then
    die "AWSCURRENT VersionId가 정확히 하나가 아닙니다. 별도 initializer/운영 절차를 확인하세요."
  fi
  unset secret_metadata

  if ! secret_payload="$(
    aws secretsmanager get-secret-value \
      --profile "$AWS_PROFILE" \
      --region "$AWS_REGION" \
      --secret-id "$SECRET_NAME" \
      --version-id "$source_version_id" \
      --query SecretString \
      --output text
  )"; then
    die "고정된 RabbitMQ SecretVersion payload 조회에 실패했습니다."
  fi

  if ! printf '%s' "$secret_payload" | jq -e --arg expected_username "$EXPECTED_USERNAME" '
    type == "object"
    and has("username")
    and has("password")
    and (.username | type == "string" and . == $expected_username)
    and (.password | type == "string" and length > 0)
  ' >/dev/null; then
    die "RabbitMQ SecretVersion payload schema가 계약과 일치하지 않습니다."
  fi

  log "AWSCURRENT VersionId 고정 및 payload schema 확인 완료"
}

publish_secret() {
  local namespace="$1"

  if ! printf '%s' "$secret_payload" | jq -c \
    --arg namespace "$namespace" \
    --arg secret_name "$KUBERNETES_SECRET_NAME" \
    --arg source_secret "$SECRET_NAME" \
    --arg source_version "$source_version_id" \
    --arg source_secret_annotation "$SOURCE_SECRET_ANNOTATION" \
    --arg source_version_annotation "$SOURCE_VERSION_ANNOTATION" '
      {
        apiVersion: "v1",
        kind: "Secret",
        metadata: {
          name: $secret_name,
          namespace: $namespace,
          annotations: {
            ($source_secret_annotation): $source_secret,
            ($source_version_annotation): $source_version
          }
        },
        type: "Opaque",
        data: {
          username: (.username | @base64),
          password: (.password | @base64)
        }
      }
    ' | kubectl --request-timeout="$KUBECTL_REQUEST_TIMEOUT" apply \
      --server-side \
      --field-manager=rabbitmq-credential-publisher \
      -f - >/dev/null; then
    die "Kubernetes Secret publication에 실패했습니다: ${namespace}/${KUBERNETES_SECRET_NAME}"
  fi

  log "Kubernetes Secret publication 완료: ${namespace}/${KUBERNETES_SECRET_NAME}"
}

verify_secret() {
  local namespace="$1"
  local expected_version_id="${2:-}"
  local summary secret_type source_secret source_version has_username has_password

  if ! summary="$(
    kubectl --request-timeout="$KUBECTL_REQUEST_TIMEOUT" \
      get secret "$KUBERNETES_SECRET_NAME" \
      --namespace "$namespace" \
      -o json | jq -er \
        --arg source_secret_annotation "$SOURCE_SECRET_ANNOTATION" \
        --arg source_version_annotation "$SOURCE_VERSION_ANNOTATION" '
          [
            (.type // ""),
            (.metadata.annotations[$source_secret_annotation] // ""),
            (.metadata.annotations[$source_version_annotation] // ""),
            ((.data | type == "object") and (.data | has("username")) | tostring),
            ((.data | type == "object") and (.data | has("password")) | tostring)
          ] | join("|")
        '
  )"; then
    die "Kubernetes Secret 검증 조회에 실패했습니다: ${namespace}/${KUBERNETES_SECRET_NAME}"
  fi

  IFS='|' read -r secret_type source_secret source_version has_username has_password <<<"$summary"
  [[ "$secret_type" == "Opaque" ]] || die "Secret type 검증 실패: $namespace"
  [[ "$source_secret" == "$SECRET_NAME" ]] || die "source-secret annotation 검증 실패: $namespace"
  [[ -n "$source_version" ]] || die "source-version-id annotation이 없습니다: $namespace"
  [[ "$has_username" == "true" ]] || die "username key가 없습니다: $namespace"
  [[ "$has_password" == "true" ]] || die "password key가 없습니다: $namespace"
  [[ -z "$expected_version_id" || "$source_version" == "$expected_version_id" ]] || \
    die "고정한 source VersionId와 publication 결과가 다릅니다: $namespace"

  verified_version_id="$source_version"
  log "Kubernetes Secret metadata/key 검증 완료: ${namespace}/${KUBERNETES_SECRET_NAME}"
}

publish() {
  resolve_secret_version

  publish_secret messaging
  verify_secret messaging "$source_version_id"

  publish_secret backend
  verify_secret backend "$source_version_id"

  log "동일한 source VersionId의 RabbitMQ credential publication 완료"
}

verify() {
  local messaging_version backend_version

  verify_secret messaging
  messaging_version="$verified_version_id"

  verify_secret backend
  backend_version="$verified_version_id"

  [[ "$messaging_version" == "$backend_version" ]] || \
    die "두 Namespace의 source-version-id가 일치하지 않습니다."

  log "두 Namespace의 RabbitMQ Secret publication 상태가 일치합니다."
}

main() {
  local mode="${1:-}"

  [[ "$#" -eq 1 ]] || die "사용법: $0 <publish|verify>"
  [[ "$mode" == "publish" || "$mode" == "verify" ]] || \
    die "사용법: $0 <publish|verify>"

  require_command aws
  require_command jq
  require_command kubectl
  validate_repository_contract
  configure_aws_environment
  aws_preflight
  kubernetes_preflight

  case "$mode" in
    publish) publish ;;
    verify) verify ;;
  esac
}

main "$@"
