#!/usr/bin/env bash
set -euo pipefail
set +x
umask 077

readonly repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
readonly dispatcher="$repo_dir/scripts/publish-workload-secrets.sh"
readonly target_infra_role_name="target-infra"
readonly publication_role_name="total-workload-publication"
readonly publication_session_duration=3600

publication_access_key_id=""
publication_secret_access_key=""
publication_session_token=""
runtime_dir=""

fail() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

cleanup() {
  unset publication_access_key_id publication_secret_access_key publication_session_token
  if [[ -n "$runtime_dir" && -d "$runtime_dir" ]]; then
    rm -f -- "$runtime_dir/kubeconfig"
    rmdir -- "$runtime_dir" 2>/dev/null || true
  fi
}
trap cleanup EXIT

run_as_publication_role() {
  env \
    -u AWS_PROFILE \
    -u AWS_DEFAULT_PROFILE \
    -u AWS_ROLE_ARN \
    -u AWS_WEB_IDENTITY_TOKEN_FILE \
    AWS_ACCESS_KEY_ID="$publication_access_key_id" \
    AWS_SECRET_ACCESS_KEY="$publication_secret_access_key" \
    AWS_SESSION_TOKEN="$publication_session_token" \
    AWS_REGION="$cluster_region" \
    AWS_DEFAULT_REGION="$cluster_region" \
    AWS_PAGER="" \
    AWS_CLI_AUTO_PROMPT="off" \
    "$@"
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
if [[ ! "$kubectl_context" =~ ^arn:aws[a-zA-Z-]*:eks:([a-z0-9-]+):([0-9]{12}):cluster/([A-Za-z0-9][A-Za-z0-9_-]*)$ ]]; then
  fail "KUBECTL_CONTEXT must be an EKS cluster ARN"
fi
readonly cluster_region="${BASH_REMATCH[1]}"
readonly cluster_account_id="${BASH_REMATCH[2]}"
readonly cluster_name="${BASH_REMATCH[3]}"

if ! kubeconfig="$(kubectl --context "$kubectl_context" config view --minify -o json)"; then
  fail "failed to read the requested kubeconfig context: $kubectl_context"
fi

if ! target_infra_profile="$(
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
readonly target_infra_profile

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
      --profile "$target_infra_profile" \
      --region "$cluster_region" \
      --query '[Account,Arn]' \
      --output text
)"; then
  fail "STS caller identity verification failed for the kubeconfig AWS profile"
fi

IFS=$'\t' read -r caller_account caller_arn <<<"$caller_identity"
unset caller_identity
[[ "$caller_account" == "$cluster_account_id" ]] || \
  fail "target-infra session and EKS context belong to different AWS accounts"
[[ "$caller_arn" == "arn:aws:sts::${cluster_account_id}:assumed-role/${target_infra_role_name}/"* ]] || \
  fail "the kubeconfig AWS profile is not an active target-infra role session"
unset caller_account caller_arn

if ! publication_role_arn="$(
  env \
    -u AWS_ACCESS_KEY_ID \
    -u AWS_SECRET_ACCESS_KEY \
    -u AWS_SESSION_TOKEN \
    -u AWS_SECURITY_TOKEN \
    -u AWS_ROLE_ARN \
    -u AWS_WEB_IDENTITY_TOKEN_FILE \
    -u AWS_PROFILE \
    -u AWS_DEFAULT_PROFILE \
    aws iam get-role \
      --profile "$target_infra_profile" \
      --role-name "$publication_role_name" \
      --query 'Role.Arn' \
      --output text
)"; then
  fail "failed to resolve the workload publication role"
fi
readonly publication_role_arn
[[ "$publication_role_arn" == "arn:aws:iam::${cluster_account_id}:role/${publication_role_name}" ]] || \
  fail "resolved workload publication role does not match the EKS context account"

if ! publication_session="$(
  env \
    -u AWS_ACCESS_KEY_ID \
    -u AWS_SECRET_ACCESS_KEY \
    -u AWS_SESSION_TOKEN \
    -u AWS_SECURITY_TOKEN \
    -u AWS_ROLE_ARN \
    -u AWS_WEB_IDENTITY_TOKEN_FILE \
    -u AWS_PROFILE \
    -u AWS_DEFAULT_PROFILE \
    aws sts assume-role \
      --profile "$target_infra_profile" \
      --region "$cluster_region" \
      --role-arn "$publication_role_arn" \
      --role-session-name "workload-publication-$(date +%s)" \
      --duration-seconds "$publication_session_duration" \
      --query 'Credentials.[AccessKeyId,SecretAccessKey,SessionToken]' \
      --output text
)"; then
  fail "failed to assume the workload publication role"
fi

IFS=$'\t' read -r publication_access_key_id publication_secret_access_key publication_session_token \
  <<<"$publication_session"
unset publication_session
[[ -n "$publication_access_key_id" && -n "$publication_secret_access_key" && -n "$publication_session_token" ]] || \
  fail "the workload publication role returned incomplete session credentials"

if ! publication_identity="$(
  run_as_publication_role aws sts get-caller-identity --query '[Account,Arn]' --output text
)"; then
  fail "failed to verify the workload publication role session"
fi
IFS=$'\t' read -r publication_account publication_arn <<<"$publication_identity"
unset publication_identity
[[ "$publication_account" == "$cluster_account_id" ]] || \
  fail "workload publication session and EKS context belong to different AWS accounts"
[[ "$publication_arn" == "arn:aws:sts::${cluster_account_id}:assumed-role/${publication_role_name}/"* ]] || \
  fail "the active AWS session is not the workload publication role"
unset publication_account publication_arn

runtime_dir="$(mktemp -d "${TMPDIR:-/tmp}/workload-publication.XXXXXXXX")"
readonly runtime_kubeconfig="$runtime_dir/kubeconfig"
if ! run_as_publication_role aws eks update-kubeconfig \
  --name "$cluster_name" \
  --region "$cluster_region" \
  --alias "$kubectl_context" \
  --kubeconfig "$runtime_kubeconfig" >/dev/null; then
  fail "failed to create an ephemeral kubeconfig for the workload publication role"
fi
export KUBECONFIG="$runtime_kubeconfig"
export KUBECTL_CONTEXT="$kubectl_context"

printf 'Starting workload publication bootstrap: environment=%s role=%s\n' \
  "$environment" "$publication_role_arn"

printf 'Bootstrap step 1/2: RabbitMQ CA publication\n'
run_as_publication_role "$dispatcher" "$environment" ca publish

printf 'Bootstrap step 2/2: Redis credential publication\n'
run_as_publication_role "$dispatcher" "$environment" redis-credential publish

printf 'Workload publication bootstrap completed: environment=%s\n' "$environment"
