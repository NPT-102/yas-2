#!/bin/bash
set -x

###############################################################################
# deploy-yas-minimal.sh
# Chỉ deploy 13 services thiết yếu (bỏ location, payment-paypal, promotion,
# rating, recommendation, webhook, sampledata).
# Dùng thay deploy-yas-applications.sh khi muốn tiết kiệm RAM trên Minikube.
###############################################################################

# Auto restart when change configmap or secret
helm repo add stakater https://stakater.github.io/stakater-charts
helm repo update

read -rd '' DOMAIN \
< <(yq -r '.domain' ./cluster-config.yaml)

echo "Waiting for Keycloak realm 'Yas' to be ready..."
until curl -s http://identity.$DOMAIN/realms/Yas/.well-known/openid-configuration | grep -q "issuer"; do
  echo "Keycloak not ready yet... sleeping 10s"
  sleep 10
done
echo "Keycloak is ready!"

# --- BFF + UI ---
helm dependency build ../charts/backoffice-bff
helm upgrade --install backoffice-bff ../charts/backoffice-bff \
  --namespace yas --create-namespace \
  --set backend.ingress.host="backoffice.$DOMAIN"

helm dependency build ../charts/backoffice-ui
helm upgrade --install backoffice-ui ../charts/backoffice-ui \
  --namespace yas --create-namespace

sleep 60

helm dependency build ../charts/storefront-bff
helm upgrade --install storefront-bff ../charts/storefront-bff \
  --namespace yas --create-namespace \
  --set backend.ingress.host="storefront.$DOMAIN"

helm dependency build ../charts/storefront-ui
helm upgrade --install storefront-ui ../charts/storefront-ui \
  --namespace yas --create-namespace

sleep 60

# --- Swagger UI ---
helm upgrade --install swagger-ui ../charts/swagger-ui \
  --namespace yas --create-namespace \
  --set ingress.host="api.$DOMAIN"

sleep 20

# --- Backend services (chỉ 8 service cần thiết) ---
# Bỏ: location, payment-paypal, promotion, rating, recommendation, webhook, sampledata
MINIMAL_SERVICES=(
  "product"
  "cart"
  "order"
  "customer"
  "inventory"
  "tax"
  "media"
  "search"
)

for chart in "${MINIMAL_SERVICES[@]}"; do
  helm dependency build ../charts/"$chart"
  helm upgrade --install "$chart" ../charts/"$chart" \
    --namespace yas --create-namespace \
    --set backend.ingress.host="api.$DOMAIN"
  sleep 60
done

# --- Fix DNS alias: storefront-bff hardcode 'storefront-nextjs' nhưng service tên 'storefront-ui' ---
cat <<'EOF' | kubectl apply -f -
apiVersion: v1
kind: Service
metadata:
  name: storefront-nextjs
  namespace: yas
spec:
  type: ExternalName
  externalName: storefront-ui.yas.svc.cluster.local
EOF

echo ""
echo "============================================"
echo "  Minimal deploy hoàn tất! (13 services)"
echo "  Bỏ qua: location, payment, payment-paypal,"
echo "  promotion, rating, recommendation,"
echo "  webhook, sampledata"
echo "============================================"
echo ""
echo "Kiểm tra: kubectl get pods -n yas"
