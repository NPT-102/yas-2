#!/bin/bash
set -e

# Fix Kafka volume permissions on Minikube
# Minikube hostPath provisioner creates volumes as 755 root:root
# Kafka runs as uid 1001 (gid 0), so it cannot write to the volume
# This script creates a temporary pod to fix the permissions

echo "=== Fixing Kafka volume permissions ==="

# Wait for PVC to exist
echo "Waiting for PVC data-0-kafka-cluster-dual-role-0 to be bound..."
kubectl wait --for=jsonpath='{.status.phase}'=Bound \
  pvc/data-0-kafka-cluster-dual-role-0 -n kafka --timeout=120s 2>/dev/null || true

# Check if PVC exists
if ! kubectl get pvc data-0-kafka-cluster-dual-role-0 -n kafka &>/dev/null; then
  echo "PVC not found yet. Kafka may not have been deployed. Skipping."
  exit 0
fi

# Create a temporary pod to fix permissions
cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: fix-kafka-permissions
  namespace: kafka
spec:
  restartPolicy: Never
  securityContext:
    runAsUser: 0
  containers:
    - name: fix-perms
      image: quay.io/strimzi/kafka:0.51.0-kafka-4.1.0
      command:
        - /bin/bash
        - -c
        - |
          echo "Current permissions:"
          ls -la /var/lib/kafka/
          chown -R 1001:0 /var/lib/kafka/data-0
          chmod -R 775 /var/lib/kafka/data-0
          echo "Fixed permissions:"
          ls -la /var/lib/kafka/
          echo "Done!"
      volumeMounts:
        - name: data-0
          mountPath: /var/lib/kafka/data-0
  volumes:
    - name: data-0
      persistentVolumeClaim:
        claimName: data-0-kafka-cluster-dual-role-0
EOF

echo "Waiting for fix-kafka-permissions pod to complete..."
kubectl wait --for=condition=Ready pod/fix-kafka-permissions -n kafka --timeout=60s 2>/dev/null || true
sleep 5

# Show result
kubectl logs fix-kafka-permissions -n kafka 2>/dev/null || true

# Wait for completion
kubectl wait --for=jsonpath='{.status.phase}'=Succeeded \
  pod/fix-kafka-permissions -n kafka --timeout=30s 2>/dev/null || true

# Cleanup
kubectl delete pod fix-kafka-permissions -n kafka --ignore-not-found

echo "=== Kafka volume permissions fixed ==="

# Restart Kafka pod to pick up fixed permissions
echo "Restarting Kafka pod..."
kubectl delete pod kafka-cluster-dual-role-0 -n kafka --ignore-not-found 2>/dev/null || true
echo "Kafka pod will be recreated automatically by StatefulSet."
