#!/usr/bin/env bash
set -euo pipefail
set +x

readonly SOURCE_SECRET="rabbitmq-ca-signing"
readonly TARGET_CA_SCRIPT_RELATIVE="workloads/rabbitmq/scripts/publish-ca-trust.sh"
readonly APPROVED_PRODUCTION_CONTEXT="arn:aws:eks:ap-northeast-2:596601390909:cluster/test-eks"
readonly repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
readonly redis_credential_publisher="$repo_dir/scripts/publish-redis-credentials.sh"

usage() {
  cat >&2 <<'USAGE'
Usage: publish-workload-secrets.sh <environment> <component> <phase>

Supported:
  production ca publish
  production redis-credential publish
  production redis-credential verify

Production CA requires:
  KUBECTL_CONTEXT=arn:aws:eks:ap-northeast-2:596601390909:cluster/test-eks

Known but unsupported components:
  rabbitmq-credential, wms-credential, oms-credential

CA standalone preflight and verify phases are unsupported. The CA publisher
performs source validation, publication, and target verification as one action.
The Redis credential publisher performs its own preflight for both supported
phases.
USAGE
}

fail() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

fail_usage() {
  printf 'ERROR: %s\n\n' "$*" >&2
  usage
  exit 2
}

if (( $# != 3 )); then
  fail_usage "environment, component, and phase are all required"
fi

readonly environment="$1"
readonly component="$2"
readonly phase="$3"

[[ -n "$environment" && -n "$component" && -n "$phase" ]] || \
  fail_usage "environment, component, and phase must not be empty"

case "$environment" in
  production|dev) ;;
  *) fail_usage "unsupported environment: $environment" ;;
esac

case "$component" in
  ca|redis-credential|rabbitmq-credential|wms-credential|oms-credential) ;;
  *) fail_usage "unknown component: $component" ;;
esac

case "$phase" in
  preflight|publish|verify) ;;
  *) fail_usage "unknown phase: $phase" ;;
esac

case "$environment:$component:$phase" in
  production:ca:publish)
    ;;
  production:redis-credential:publish|production:redis-credential:verify)
    [[ -f "$redis_credential_publisher" ]] || \
      fail "Redis credential publisher does not exist: $redis_credential_publisher"
    [[ -x "$redis_credential_publisher" ]] || \
      fail "Redis credential publisher is not executable: $redis_credential_publisher"

    printf 'Invoking the Redis credential publisher: environment=%s phase=%s\n' \
      "$environment" "$phase"
    exec "$redis_credential_publisher" "$phase"
    ;;
  *)
    fail "unsupported publication capability: environment=$environment component=$component phase=$phase"
    ;;
esac

command -v kubectl >/dev/null 2>&1 || fail "kubectl is required"

kubectl_context="${KUBECTL_CONTEXT:-}"
if [[ "$environment" == "production" ]]; then
  [[ -n "$kubectl_context" ]] || \
    fail "KUBECTL_CONTEXT is required for production publication"
  [[ "$kubectl_context" == "$APPROVED_PRODUCTION_CONTEXT" ]] || \
    fail "production kubectl context is not approved: $kubectl_context"
elif [[ -z "$kubectl_context" ]]; then
  kubectl_context="$(kubectl config current-context 2>/dev/null || true)"
fi
[[ -n "$kubectl_context" ]] || fail "kubectl context is empty; set KUBECTL_CONTEXT or select a current context"
readonly kubectl_context

configured_context="$(kubectl config get-contexts "$kubectl_context" -o name 2>/dev/null || true)"
[[ "$configured_context" == "$kubectl_context" ]] || \
  fail "kubectl context does not exist: $kubectl_context"

if [[ "$environment" == "production" ]]; then
  context_cluster="$(
    kubectl --context "$kubectl_context" config view --minify \
      -o 'jsonpath={.contexts[0].context.cluster}' 2>/dev/null || true
  )"
  [[ -n "$context_cluster" ]] || \
    fail "approved production context has no cluster reference: $kubectl_context"

  cluster_entry="$(
    kubectl --context "$kubectl_context" config view --minify \
      -o 'jsonpath={.clusters[0].name}' 2>/dev/null || true
  )"
  [[ -n "$cluster_entry" && "$cluster_entry" == "$context_cluster" ]] || \
    fail "approved production context references a missing cluster entry: $context_cluster"

  cluster_server="$(
    kubectl --context "$kubectl_context" config view --minify \
      -o 'jsonpath={.clusters[0].cluster.server}' 2>/dev/null || true
  )"
  [[ -n "$cluster_server" ]] || \
    fail "approved production cluster entry has an empty server: $cluster_entry"
fi

total_k8s_dir="${TOTAL_K8S_DIR:-$repo_dir/../total-k8s}"
[[ -d "$total_k8s_dir" ]] || fail "total-k8s directory does not exist: $total_k8s_dir"
total_k8s_dir="$(cd "$total_k8s_dir" && pwd -P)"
readonly total_k8s_dir

readonly ca_publisher="$total_k8s_dir/$TARGET_CA_SCRIPT_RELATIVE"
[[ -f "$ca_publisher" ]] || fail "CA publisher does not exist: $ca_publisher"
[[ -x "$ca_publisher" ]] || fail "CA publisher is not executable: $ca_publisher"

case "$environment" in
  production)
    readonly source_namespace="messaging"
    readonly -a required_namespaces=("messaging" "backend" "dev")
    ;;
esac

for namespace in "${required_namespaces[@]}"; do
  if ! kubectl --context "$kubectl_context" get namespace "$namespace" -o name >/dev/null 2>&1; then
    fail "required namespace is unavailable: $namespace (environment=$environment)"
  fi
done

if ! kubectl --context "$kubectl_context" --namespace "$source_namespace" \
  get secret "$SOURCE_SECRET" -o name >/dev/null 2>&1; then
  fail "required source Secret is unavailable: $source_namespace/$SOURCE_SECRET"
fi

printf 'Validated CA publication prerequisites: environment=%s context=%s\n' \
  "$environment" "$kubectl_context"
printf 'Invoking the total-k8s CA publisher; it will validate, publish, and verify targets.\n'

"$ca_publisher" "$kubectl_context" --mode "$environment"
