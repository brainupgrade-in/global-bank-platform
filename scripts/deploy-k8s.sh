#!/usr/bin/env bash
#
# Deploy the fleet to a Kubernetes cluster, in the global-bank namespace.
#
#   ./scripts/deploy-k8s.sh              apply everything and wait for rollout
#   APP_HOST=<host> ./scripts/deploy-k8s.sh --ingress   also apply the Ingress
#   ./scripts/deploy-k8s.sh --status     what is running
#   ./scripts/deploy-k8s.sh --forward    port-forward the UI to localhost:8080
#   ./scripts/deploy-k8s.sh --delete     remove the namespace and everything in it
#
# Images come from ./scripts/build-images.sh. To run without a cluster at all,
# use ./scripts/local.sh instead — it needs neither Docker nor Kubernetes.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
K8S="$(cd "$HERE/../k8s" && pwd)"
NS=global-bank

c_grn=$'\033[32m'; c_red=$'\033[31m'; c_dim=$'\033[2m'; c_off=$'\033[0m'
ok()  { printf '  %s✓%s %s\n' "$c_grn" "$c_off" "$*"; }
die() { printf '  %s✗%s %s\n' "$c_red" "$c_off" "$*" >&2; exit 1; }

command -v kubectl >/dev/null || die "kubectl not found"
kubectl cluster-info >/dev/null 2>&1 || die "no reachable cluster — check your kubeconfig context ($(kubectl config current-context 2>/dev/null || echo none))"

DEPLOYMENTS=(auth customer account transaction rules frontend)

apply_all() {
  echo "Deploying to namespace $NS  ${c_dim}(context: $(kubectl config current-context))${c_off}"
  echo

  # The JWT signing key is generated on first deploy and then left alone. It is
  # deliberately NOT a manifest: an applied placeholder would silently reset the
  # key on every redeploy, invalidating every token already issued.
  kubectl apply -f "$K8S/00-namespace.yaml" >/dev/null
  if kubectl -n "$NS" get secret auth-secrets >/dev/null 2>&1; then
    ok "secret/auth-secrets already present — left untouched"
  else
    kubectl -n "$NS" create secret generic auth-secrets \
      --from-literal=JWT_SECRET="$(openssl rand -base64 48)" >/dev/null \
      && ok "secret/auth-secrets created with a generated key"
  fi

  # Ordered by filename: namespace, then config, then workloads. The Ingress is
  # opt-in because it needs a controller the cluster may not have.
  for f in "$K8S"/0*.yaml "$K8S"/1*.yaml "$K8S"/2*.yaml "$K8S"/3*.yaml; do
    kubectl apply -f "$f" >/dev/null || die "failed applying $(basename "$f")"
    ok "applied $(basename "$f")"
  done

  if [[ "${1:-}" == "--ingress" ]]; then
    # The hostname is not committed: this repo is public and the URL is given to
    # participants directly. Supply it at apply time.
    if [[ -z "${APP_HOST:-}" ]]; then
      die "APP_HOST is not set. export APP_HOST=<host> before applying the Ingress."
    fi
    sed "s|APP_HOST_PLACEHOLDER|${APP_HOST}|" "$K8S/40-ingress.yaml" \
      | kubectl apply -f - >/dev/null && ok "applied 40-ingress.yaml for ${APP_HOST}"
  else
    printf '  %s· skipped 40-ingress.yaml (pass --ingress to apply it)%s\n' "$c_dim" "$c_off"
  fi

  echo
  echo "Waiting for rollout"
  local failed=0
  for d in "${DEPLOYMENTS[@]}"; do
    if kubectl -n "$NS" rollout status "deploy/$d" --timeout=180s >/dev/null 2>&1; then
      ok "$(printf '%-12s' "$d") ready"
    else
      printf '  %s✗%s %-12s not ready\n' "$c_red" "$c_off" "$d"
      kubectl -n "$NS" get pods -l "app=$d" --no-headers 2>/dev/null | sed 's/^/      /'
      failed=1
    fi
  done

  echo
  if [[ $failed -eq 0 ]]; then
    echo "  ${c_grn}Fleet is up in $NS.${c_off}"
    echo "  ${c_dim}Open the UI:  $0 --forward   then http://localhost:8080${c_off}"
    [[ -n "${APP_HOST:-}" ]] && echo "  ${c_dim}Or:           https://${APP_HOST}${c_off}"
  else
    echo "  ${c_red}Some deployments did not become ready.${c_off}"
    echo "  ${c_dim}Most often the image is missing: run ./scripts/build-images.sh first,${c_off}"
    echo "  ${c_dim}and make sure the cluster can pull it (kind load / minikube image load).${c_off}"
    exit 1
  fi
}

case "${1:-apply}" in
  --status)
    kubectl -n "$NS" get deploy,pod,svc 2>/dev/null || die "namespace $NS not found"
    ;;
  --forward)
    echo "Forwarding svc/frontend to http://localhost:8080 — Ctrl-C to stop"
    kubectl -n "$NS" port-forward svc/frontend 8080:80
    ;;
  --delete)
    read -rp "Delete namespace $NS and everything in it? [y/N] " a
    [[ "$a" == "y" || "$a" == "Y" ]] || { echo "  cancelled"; exit 0; }
    kubectl delete namespace "$NS" && ok "namespace $NS deleted"
    ;;
  apply|--ingress)
    apply_all "${1:-}"
    ;;
  *)
    sed -n '3,14p' "${BASH_SOURCE[0]}" | sed 's/^# \?//'
    ;;
esac
