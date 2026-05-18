#!/usr/bin/env bash
set -euo pipefail
set -x

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CHARTS_DIR="${SCRIPT_DIR}/../charts"
ISTIO_DIR="${SCRIPT_DIR}/../../istio"
OBSERVABILITY_DIR="${SCRIPT_DIR}/observability"

# Auto restart when change configmap or secret
helm repo add stakater https://stakater.github.io/stakater-charts --force-update
helm repo update

DOMAIN="$(yq -r '.domain' "${SCRIPT_DIR}/cluster-config.yaml")"

label_namespace() {
  local namespace="$1"

  if kubectl get namespace "${namespace}" >/dev/null 2>&1; then
    kubectl label namespace "${namespace}" istio-injection=enabled --overwrite
  fi
}

restart_ingress_nginx() {
  if kubectl get deployment ingress-nginx-controller -n ingress-nginx >/dev/null 2>&1; then
    kubectl rollout restart deployment ingress-nginx-controller -n ingress-nginx
    kubectl wait deployment/ingress-nginx-controller -n ingress-nginx --for=condition=Available --timeout=300s
  fi
}

deploy_chart() {
  local chart_name="$1"
  shift

  helm dependency build "${CHARTS_DIR}/${chart_name}"
  helm upgrade --install "${chart_name}" "${CHARTS_DIR}/${chart_name}" \
    --namespace yas --create-namespace \
    "$@"
}

wait_for_keycloak() {
  echo "Waiting for Keycloak realm 'Yas' to be ready..."
  until curl -s "http://identity.${DOMAIN}/realms/Yas/.well-known/openid-configuration" | grep -q "issuer"; do
    echo "Keycloak not ready yet... sleeping 10s"
    sleep 10
  done
  echo "Keycloak is ready!"
}

label_namespace yas
label_namespace ingress-nginx
restart_ingress_nginx

wait_for_keycloak

deploy_chart backoffice-bff --set backend.ingress.host="backoffice.${DOMAIN}"
deploy_chart backoffice-ui

sleep 60

deploy_chart storefront-bff --set backend.ingress.host="storefront.${DOMAIN}"
deploy_chart storefront-ui

sleep 60

deploy_chart swagger-ui --set ingress.host="api.${DOMAIN}"

sleep 20

CORE_SERVICES=(
  "product"
  "cart"
  "order"
  "customer"
  "inventory"
  "tax"
  "media"
  "search"
)

for chart in "${CORE_SERVICES[@]}"; do
  deploy_chart "${chart}" --set backend.ingress.host="api.${DOMAIN}"
  sleep 60
done

kubectl apply -f "${ISTIO_DIR}/peer-authentication.yaml"
kubectl apply -f "${ISTIO_DIR}/destination-rule.yaml"
kubectl apply -f "${ISTIO_DIR}/authorization-policy.yaml"
kubectl apply -f "${ISTIO_DIR}/virtual-service-retry.yaml"

kubectl apply -f https://raw.githubusercontent.com/istio/istio/release-1.24/samples/addons/prometheus.yaml
kubectl apply -f https://raw.githubusercontent.com/istio/istio/release-1.24/samples/addons/grafana.yaml
kubectl apply -f https://raw.githubusercontent.com/istio/istio/release-1.24/samples/addons/kiali.yaml

kubectl wait --for=condition=Ready pods -n istio-system --all --timeout=600s

kubectl apply -f "${OBSERVABILITY_DIR}/observability-ingress.yaml"

echo ""
echo "============================================"
echo "  Core deploy + service mesh complete!"
echo "  Services: backoffice, storefront, swagger,"
echo "  product, cart, order, customer, inventory,"
echo "  tax, media, search"
echo "  Mesh: mTLS STRICT, AuthorizationPolicy,"
echo "  DestinationRule, Retry, Kiali, Prometheus, Grafana"
echo "============================================"
echo ""
echo "Check: kubectl get pods -n yas"
