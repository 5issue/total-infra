#!/usr/bin/env bash
set -euo pipefail
set +x
umask 077

# Creates the first AWSCURRENT version only. Existing credentials are validated
# and preserved; rotation remains a separate, explicitly approved operation.

readonly EXPECTED_AWS_ACCOUNT_ID="596601390909"
readonly EXPECTED_AWS_REGION="ap-northeast-2"
readonly AWS_PROFILE="${AWS_PROFILE:-target-infra}"
readonly AWS_REGION="${AWS_REGION:-$EXPECTED_AWS_REGION}"

runtime_dir=""
secret_payload=""

log() {
  printf '[rabbitmq-credential-initializer] %s\n' "$*"
}

die() {
  printf '[rabbitmq-credential-initializer] ERROR: %s\n' "$*" >&2
  exit 1
}

cleanup() {
  unset secret_payload
  if [[ -n "$runtime_dir" && -d "$runtime_dir" ]]; then
    rm -f -- "$runtime_dir/password" "$runtime_dir/payload.json"
    rmdir -- "$runtime_dir" 2>/dev/null || true
  fi
}
trap cleanup EXIT

require_command() {
  command -v "$1" >/dev/null 2>&1 || die "필수 명령을 찾을 수 없습니다: $1"
}

configure_aws_environment() {
  unset AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN AWS_SECURITY_TOKEN
  unset AWS_ROLE_ARN AWS_WEB_IDENTITY_TOKEN_FILE AWS_DEFAULT_PROFILE
  export AWS_PROFILE AWS_REGION
  export AWS_DEFAULT_REGION="$AWS_REGION"
  export AWS_PAGER=""
  export AWS_CLI_AUTO_PROMPT="off"
}

identity_contract() {
  local identity="$1"

  case "$identity" in
    backend)
      secret_name="prod/total/rabbitmq-app-credentials"
      expected_username="total-backend"
      ;;
    wms)
      secret_name="prod/total/rabbitmq-wms-credentials"
      expected_username="total-wms"
      ;;
    oms)
      secret_name="prod/total/rabbitmq-oms-credentials"
      expected_username="total-oms"
      ;;
    *)
      die "지원하지 않는 RabbitMQ identity입니다: $identity"
      ;;
  esac
}

validate_payload() {
  local identity="$1"

  if ! printf '%s' "$secret_payload" | jq -e --arg username "$expected_username" '
    type == "object"
    and (keys | sort == ["password", "username"])
    and (.username == $username)
    and (.password | type == "string" and length > 0)
  ' >/dev/null; then
    die "$identity credential payload가 username/password 계약과 일치하지 않습니다."
  fi
}

resolve_current_version() {
  local metadata="$1"

  printf '%s' "$metadata" | jq -er '
    .VersionIdsToStages // {}
    | to_entries
    | map(select(.value | index("AWSCURRENT")))
    | if length == 0 then ""
      elif length == 1 then .[0].key
      else error("AWSCURRENT VersionId must be unique")
      end
  '
}

read_and_validate_version() {
  local identity="$1"
  local version_id="$2"

  if ! secret_payload="$(
    aws secretsmanager get-secret-value \
      --profile "$AWS_PROFILE" \
      --region "$AWS_REGION" \
      --secret-id "$secret_name" \
      --version-id "$version_id" \
      --query SecretString \
      --output text
  )"; then
    die "$identity AWSCURRENT payload 조회에 실패했습니다."
  fi

  validate_payload "$identity"
  unset secret_payload
}

process_identity() {
  local mode="$1"
  local identity="$2"
  local metadata current_version created_version confirmed_version

  identity_contract "$identity"

  if ! metadata="$(
    aws secretsmanager describe-secret \
      --profile "$AWS_PROFILE" \
      --region "$AWS_REGION" \
      --secret-id "$secret_name" \
      --output json
  )"; then
    die "$identity Secret container를 조회할 수 없습니다. init Terraform 적용을 먼저 확인하세요."
  fi

  if [[ "$(printf '%s' "$metadata" | jq -r '.DeletedDate // empty')" != "" ]]; then
    die "$identity Secret container가 삭제 예약 상태입니다."
  fi

  if ! current_version="$(resolve_current_version "$metadata")"; then
    die "$identity AWSCURRENT가 둘 이상입니다. 수동 점검이 필요합니다."
  fi
  unset metadata

  if [[ -n "$current_version" ]]; then
    read_and_validate_version "$identity" "$current_version"
    log "$identity: 기존 AWSCURRENT payload 계약 확인 완료; 변경하지 않음"
    return
  fi

  [[ "$mode" == "initialize" ]] || \
    die "$identity: AWSCURRENT가 없습니다. initialize를 승인된 운영 절차로 실행하세요."

  runtime_dir="$(mktemp -d "${TMPDIR:-/tmp}/rabbitmq-credential.XXXXXXXX")"
  openssl rand -hex -out "$runtime_dir/password" 32
  jq -n \
    --arg username "$expected_username" \
    --rawfile password "$runtime_dir/password" \
    '{username: $username, password: ($password | sub("\\n$"; ""))}' \
    >"$runtime_dir/payload.json"

  if ! created_version="$(
    aws secretsmanager put-secret-value \
      --profile "$AWS_PROFILE" \
      --region "$AWS_REGION" \
      --secret-id "$secret_name" \
      --secret-string "file://$runtime_dir/payload.json" \
      --query VersionId \
      --output text
  )"; then
    die "$identity 최초 SecretVersion 생성에 실패했습니다."
  fi

  rm -f -- "$runtime_dir/password" "$runtime_dir/payload.json"
  rmdir -- "$runtime_dir" 2>/dev/null || true
  runtime_dir=""

  if ! metadata="$(
    aws secretsmanager describe-secret \
      --profile "$AWS_PROFILE" \
      --region "$AWS_REGION" \
      --secret-id "$secret_name" \
      --output json
  )" || ! confirmed_version="$(resolve_current_version "$metadata")"; then
    die "$identity 생성 후 AWSCURRENT 확인에 실패했습니다."
  fi
  unset metadata
  [[ "$confirmed_version" == "$created_version" ]] || \
    die "$identity 생성 version과 AWSCURRENT가 다릅니다. 동시 실행 여부를 확인하세요."

  read_and_validate_version "$identity" "$confirmed_version"
  log "$identity: 최초 AWSCURRENT 생성 및 payload 계약 확인 완료"
}

main() {
  local mode="${1:-}"
  local requested_identity="${2:-all}"
  local caller_account
  local -a identities

  (( $# == 1 || $# == 2 )) || die "사용법: $0 <check|initialize> [backend|wms|oms|all]"
  [[ "$mode" == "check" || "$mode" == "initialize" ]] || \
    die "사용법: $0 <check|initialize> [backend|wms|oms|all]"
  [[ "$AWS_REGION" == "$EXPECTED_AWS_REGION" ]] || die "AWS_REGION이 repository 계약과 다릅니다."

  case "$requested_identity" in
    all) identities=(backend wms oms) ;;
    backend|wms|oms) identities=("$requested_identity") ;;
    *) die "지원하지 않는 identity입니다: $requested_identity" ;;
  esac

  require_command aws
  require_command jq
  require_command openssl
  configure_aws_environment

  if ! caller_account="$(
    aws sts get-caller-identity \
      --profile "$AWS_PROFILE" \
      --region "$AWS_REGION" \
      --query Account \
      --output text
  )"; then
    die "STS caller identity 확인에 실패했습니다."
  fi
  [[ "$caller_account" == "$EXPECTED_AWS_ACCOUNT_ID" ]] || \
    die "AWS account가 repository 계약과 다릅니다."

  for identity in "${identities[@]}"; do
    process_identity "$mode" "$identity"
  done
}

main "$@"
