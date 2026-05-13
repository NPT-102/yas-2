#!/bin/bash
set -e

echo "============================================"
echo "  YAS Cluster Pod Fix Script"
echo "============================================"
echo ""

# ========================================
# STEP 1: Fix firewalld blocking pod networking
# ========================================
echo "=== STEP 1: Fixing firewalld (root cause) ==="
echo "firewalld is ACTIVE and blocking pod-to-service traffic (10.42.x.x <-> 10.43.x.x)"
echo ""

# Option A: Add K8s interfaces/subnets to trusted zone (recommended)
echo "Adding cni0 and K8s subnets to trusted zone..."
sudo firewall-cmd --permanent --zone=trusted --add-interface=cni0 2>/dev/null || true
sudo firewall-cmd --permanent --zone=trusted --add-source=10.42.0.0/16 2>/dev/null || true
sudo firewall-cmd --permanent --zone=trusted --add-source=10.43.0.0/16 2>/dev/null || true

# Also trust the Flannel/VXLAN interface if it exists  
sudo firewall-cmd --permanent --zone=trusted --add-interface=flannel.1 2>/dev/null || true
sudo firewall-cmd --permanent --zone=trusted --add-interface=flannel-wg 2>/dev/null || true

# Allow masquerade for NAT
sudo firewall-cmd --permanent --add-masquerade 2>/dev/null || true

# Reload firewalld to apply changes
sudo firewall-cmd --reload 2>/dev/null || true

echo "Firewalld rules updated."
echo ""

# ========================================
# STEP 2: Restart CoreDNS (critical - DNS for all pods)
# ========================================
echo "=== STEP 2: Restarting CoreDNS ==="
kubectl rollout restart deployment coredns -n kube-system
echo "Waiting for CoreDNS to become ready..."
kubectl rollout status deployment coredns -n kube-system --timeout=120s || true
sleep 10

# Verify CoreDNS is working
echo "Verifying DNS resolution..."
kubectl run dns-test --image=busybox:1.36 --rm -i --restart=Never --timeout=30s -- nslookup kubernetes.default.svc.cluster.local 2>/dev/null && echo "DNS OK!" || echo "DNS still not working, check firewalld"
echo ""

# ========================================
# STEP 3: Restart metrics-server
# ========================================
echo "=== STEP 3: Restarting metrics-server ==="
kubectl rollout restart deployment metrics-server -n kube-system
kubectl rollout status deployment metrics-server -n kube-system --timeout=120s || true
echo ""

# ========================================
# STEP 4: Restart ingress-nginx
# ========================================
echo "=== STEP 4: Restarting ingress-nginx ==="
kubectl rollout restart deployment ingress-nginx-controller -n ingress-nginx
kubectl rollout status deployment ingress-nginx-controller -n ingress-nginx --timeout=120s || true
echo ""

# ========================================
# STEP 5: Restart infrastructure operators
# ========================================
echo "=== STEP 5: Restarting infrastructure operators ==="

# Strimzi Kafka operator
kubectl rollout restart deployment strimzi-cluster-operator -n kafka 2>/dev/null || true
kubectl rollout status deployment strimzi-cluster-operator -n kafka --timeout=180s || true

# Keycloak operator
kubectl rollout restart deployment keycloak-operator -n keycloak 2>/dev/null || true
kubectl rollout status deployment keycloak-operator -n keycloak --timeout=120s || true

# Staging reloader
kubectl rollout restart deployment yas-reloader -n staging 2>/dev/null || true

# Postgres operator
kubectl rollout restart deployment postgres-operator -n postgres 2>/dev/null || true

echo ""

# ========================================
# STEP 6: Restart Keycloak (depends on PostgreSQL)
# ========================================
echo "=== STEP 6: Restarting Keycloak ==="
# Wait for PostgreSQL to be fully ready first
echo "Checking PostgreSQL is ready..."
kubectl wait --for=condition=ready pod/postgresql-0 -n postgres --timeout=60s || true

kubectl rollout restart statefulset keycloak -n keycloak 2>/dev/null || true
echo "Waiting for Keycloak to start (depends on PostgreSQL)..."
sleep 15
echo ""

# ========================================
# STEP 7: Restart Kafka ecosystem
# ========================================
echo "=== STEP 7: Restarting Kafka ecosystem ==="

# Wait for strimzi operator to be ready
echo "Waiting for Strimzi operator..."
kubectl rollout status deployment strimzi-cluster-operator -n kafka --timeout=180s || true

# Restart entity operator (managed by strimzi, just delete and let it recreate)
kubectl delete pod -n kafka -l strimzi.io/name=kafka-cluster-entity-operator 2>/dev/null || true

# Restart debezium connect
kubectl rollout restart statefulset debezium-connect-cluster-connect -n kafka 2>/dev/null || true

# Restart AKHQ
kubectl rollout restart deployment akhq -n kafka 2>/dev/null || true

echo ""

# ========================================
# STEP 8: Restart Elasticsearch ecosystem
# ========================================
echo "=== STEP 8: Restarting Elasticsearch ecosystem ==="
# Restart standalone elasticsearch
kubectl rollout restart statefulset elasticsearch-standalone -n elasticsearch 2>/dev/null || true
sleep 10

# Note: Kibana v8.8.1 is incompatible with Elasticsearch v9.2.3
# This requires either upgrading Kibana or downgrading Elasticsearch
echo "WARNING: Kibana v8.8.1 is incompatible with Elasticsearch v9.2.3!"
echo "You need to either upgrade Kibana to v9.x or downgrade Elasticsearch to v8.x"
echo ""

# ========================================
# STEP 9: Restart YAS application services
# ========================================
echo "=== STEP 9: Restarting all YAS application services ==="

# Get all deployments in yas namespace and restart them
for deploy in $(kubectl get deployments -n yas -o name 2>/dev/null); do
  echo "Restarting $deploy..."
  kubectl rollout restart "$deploy" -n yas 2>/dev/null || true
done

echo ""
echo "Waiting 30s for services to initialize..."
sleep 30

# ========================================
# STEP 10: Check results
# ========================================
echo ""
echo "============================================"
echo "  Final Status Check"
echo "============================================"
echo ""
kubectl get pods --all-namespaces | grep -v "Running\|Completed" | grep -v "NAMESPACE"
echo ""
echo "=== Pods still not running (above) ==="
echo ""
echo "If pods are still crashing:"
echo "  1. Check if firewalld rules took effect: sudo firewall-cmd --list-all --zone=trusted"
echo "  2. Verify DNS: kubectl run test --image=busybox:1.36 --rm -it -- nslookup postgresql.postgres"
echo "  3. Check specific pod logs: kubectl logs -n <namespace> <pod-name>"
echo ""
echo "KNOWN ISSUES TO FIX MANUALLY:"
echo "  - Kibana v8.8.1 is INCOMPATIBLE with Elasticsearch v9.2.3"
echo "  - Node 'quoctan' is NotReady (Kubelet stopped posting status)"
echo "============================================"
