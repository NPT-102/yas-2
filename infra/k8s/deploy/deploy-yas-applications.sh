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

wait_for_deployment() {
  local namespace="$1"
  local deployment="$2"
  echo "Waiting for deployment ${deployment} in ${namespace} to be ready..."
  kubectl rollout status deployment/"${deployment}" -n "${namespace}" --timeout=300s
}

wait_for_keycloak() {
  echo "Waiting for Keycloak realm 'Yas' to be ready..."
  until curl -s "http://identity.${DOMAIN}/realms/Yas/.well-known/openid-configuration" | grep -q "issuer"; do
    echo "Keycloak not ready yet... sleeping 10s"
    sleep 10
  done
  echo "Keycloak is ready!"
}

wait_for_postgres() {
  echo "Waiting for PostgreSQL to be ready..."
  kubectl wait pod -l cluster-name=postgresql -n postgres \
    --for=condition=Ready --timeout=300s
  echo "PostgreSQL is ready!"
}

wait_for_kafka() {
  echo "Waiting for Kafka brokers to be ready..."
  kubectl wait pod \
    -l strimzi.io/cluster=kafka-cluster,strimzi.io/component-type=kafka \
    -n kafka --for=condition=Ready --timeout=600s
  echo "Kafka is ready!"
}

wait_for_redis() {
  echo "Waiting for Redis master to be ready..."
  kubectl wait pod \
    -l app.kubernetes.io/name=redis,app.kubernetes.io/component=master \
    -n redis --for=condition=Ready --timeout=300s
  echo "Redis is ready!"
}

wait_for_elasticsearch() {
  echo "Waiting for Elasticsearch to be ready..."
  kubectl wait pod \
    -l common.k8s.elastic.co/type=elasticsearch \
    -n elasticsearch --for=condition=Ready --timeout=600s
  echo "Elasticsearch is ready!"
}

# === Step 1: Label namespaces for sidecar injection ===
label_namespace yas
label_namespace ingress-nginx

# === Step 2: Apply Istio service mesh configs BEFORE any app pods are created ===
# This ensures pods start with the correct mTLS and routing policies already active.
# destination-rule-external.yaml disables mTLS for out-of-mesh services
# (postgres, kafka, redis, elasticsearch, keycloak).
kubectl apply -f "${ISTIO_DIR}/destination-rule-external.yaml"
kubectl apply -f "${ISTIO_DIR}/peer-authentication.yaml"
kubectl apply -f "${ISTIO_DIR}/destination-rule.yaml"
kubectl apply -f "${ISTIO_DIR}/authorization-policy.yaml"
kubectl apply -f "${ISTIO_DIR}/virtual-service-retry.yaml"

# === Step 3: Wait for all infrastructure dependencies ===
wait_for_postgres
wait_for_kafka
wait_for_redis
wait_for_elasticsearch
wait_for_keycloak

# === Step 4: Deploy shared configuration (configmap + secrets) ===
# Must exist before any Spring Boot pod starts (volumeMount dependency).
helm dependency build "${CHARTS_DIR}/yas-configuration"
helm upgrade --install yas-configuration "${CHARTS_DIR}/yas-configuration" \
  --namespace yas --create-namespace

# === Step 5: Restart ingress-nginx to get Istio sidecar ===
restart_ingress_nginx

# === Step 6: Deploy BFF + UI layers ===
deploy_chart backoffice-bff --set backend.ingress.host="backoffice.${DOMAIN}"
deploy_chart backoffice-ui
wait_for_deployment yas backoffice-bff
wait_for_deployment yas backoffice-ui

deploy_chart storefront-bff --set backend.ingress.host="storefront.${DOMAIN}"
deploy_chart storefront-ui
wait_for_deployment yas storefront-bff
wait_for_deployment yas storefront-ui

deploy_chart swagger-ui --set ingress.host="api.${DOMAIN}"
wait_for_deployment yas swagger-ui

# === Step 7: Deploy core backend services ===
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
  wait_for_deployment yas "${chart}"
done

# === Step 8: Install Istio observability addons ===
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
echo "  DestinationRule (internal + external),"
echo "  Retry, Kiali, Prometheus, Grafana"
echo "============================================"
echo ""
echo "Check: kubectl get pods -n yas"
