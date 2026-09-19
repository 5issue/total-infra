#!/usr/bin/env bash
set -euo pipefail
set +x

readonly repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
readonly dispatcher="$repo_dir/scripts/publish-workload-secrets.sh"
readonly expected_aws_account_id="596601390909"
readonly -a approved_caller_arns=(
  "arn:aws:iam::596601390909:user/mgmt-automation-user"
  "arn:aws:iam::596601390909:user/infra-jongwon"
  "arn:aws:iam::596601390909:user/infra-youngheon"
  "arn:aws:iam::596601390909:user/infra-mingyu"
  "arn:aws:iam::596601390909:user/infra-jaehyeok"
  "arn:aws:iam::596601390909:user/infra-jiyoon"
  "arn:aws:sts::596601390909:assumed-role/target-infra"
)

fail() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

if (( $# != 1 )); then
  fail "usage: $0 production"
fi

readonly environment="$1"
[[ "$environment" == "production" ]] || \
  fail "unsupported bootstrap environment: $environment"

[[ -f "$dispatcher" ]] || fail "workload publication dispatcher does not exist: $dispatcher"
[[ -x "$dispatcher" ]] || fail "workload publication dispatcher is not executable: $dispatcher"

command -v kubectl >/dev/null 2>&1 || fail "kubectl is required"
command -v jq >/dev/null 2>&1 || fail "jq is required"
command -v aws >/dev/null 2>&1 || fail "aws is required"

readonly kubectl_context="${KUBECTL_CONTEXT:-}"
[[ -n "$kubectl_context" ]] || fail "KUBECTL_CONTEXT is required for production bootstrap"

if ! kubeconfig="$(
  kubectl --context "$kubectl_context" config view --minify -o json
)"; then
  fail "failed to read the requested kubeconfig context: $kubectl_context"
fi

if ! kube_exec_profile="$(
  printf '%s' "$kubeconfig" | jq -er '
    [
      .users[0].user.exec.env[]?
      | select(.name == "AWS_PROFILE")
      | .value
      | select(type == "string" and length > 0)
    ]
    | if length == 1 then .[0] else error("AWS_PROFILE must exist exactly once") end
  '
)"; then
  fail "kubeconfig exec.env.AWS_PROFILE is missing or ambiguous for context: $kubectl_context"
fi
unset kubeconfig
readonly kube_exec_profile

if ! caller_identity="$(
  env \
    -u AWS_ACCESS_KEY_ID \
    -u AWS_SECRET_ACCESS_KEY \
    -u AWS_SESSION_TOKEN \
    -u AWS_SECURITY_TOKEN \
    -u AWS_ROLE_ARN \
    -u AWS_WEB_IDENTITY_TOKEN_FILE \
    -u AWS_PROFILE \
    -u AWS_DEFAULT_PROFILE \
    aws sts get-caller-identity \
      --profile "$kube_exec_profile" \
      --query '[Account,Arn]' \
      --output text
)"; then
  fail "STS caller identity verification failed for the kubeconfig AWS profile"
fi

IFS=$'\t' read -r caller_account caller_arn <<<"$caller_identity"
unset caller_identity
[[ "$caller_account" == "$expected_aws_account_id" ]] || \
  fail "STS caller account is not approved for production bootstrap"

caller_is_approved=false
for approved_caller_arn in "${approved_caller_arns[@]}"; do
  if [[ "$caller_arn" == "$approved_caller_arn"* ]]; then
    caller_is_approved=true
    break
  fi
done
[[ "$caller_is_approved" == "true" ]] || \
  fail "STS caller identity is not approved for production bootstrap"
unset caller_account caller_arn caller_is_approved approved_caller_arn

printf 'Starting workload publication bootstrap: environment=%s\n' "$environment"

printf 'Bootstrap step 1/2: RabbitMQ CA publication\n'
"$dispatcher" "$environment" ca publish

printf 'Bootstrap step 2/2: Redis credential publication\n'
AWS_PROFILE="$kube_exec_profile" \
  "$dispatcher" "$environment" redis-credential publish

printf 'Workload publication bootstrap completed: environment=%s\n' "$environment"
