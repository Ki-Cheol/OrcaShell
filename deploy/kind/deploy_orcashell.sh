#!/bin/bash
# SPDX-License-Identifier: Apache-2.0
# OrcaShell - One-click deployment script
# Deploys OpenShell on kind (Kubernetes in Docker) instead of k3s
#
# Usage:
#   chmod +x deploy-orcashell.sh
#   ./deploy-orcashell.sh
#
# Prerequisites:
#   - Docker running
#   - Internet access (for pulling images)

set -e

CLUSTER_NAME="orcashell"
NAMESPACE="openshell"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ORCASHELL_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
CERT_DIR="/tmp/orcashell-certs"
ARCH=$(uname -m)

# Normalize arch
case "$ARCH" in
    x86_64)  ARCH_SUFFIX="amd64" ;;
    aarch64) ARCH_SUFFIX="arm64" ;;
    *)       echo "Unsupported architecture: $ARCH"; exit 1 ;;
esac

echo "======================================================================"
echo "  OrcaShell Deployment Script"
echo "  Kubernetes (kind) + OpenShell Gateway + Sandbox CRD"
echo "======================================================================"
echo ""
echo "  Architecture: $ARCH ($ARCH_SUFFIX)"
echo "  Cluster name: $CLUSTER_NAME"
echo "  Namespace:    $NAMESPACE"
echo ""

# ===========================================================================
# Step 1: Install prerequisites
# ===========================================================================
echo "[Step 1/7] Checking prerequisites..."

# kind
if ! command -v kind &>/dev/null; then
    echo "  Installing kind..."
    curl -sLo ./kind "https://kind.sigs.k8s.io/dl/latest/kind-linux-${ARCH_SUFFIX}"
    chmod +x ./kind
    sudo mv ./kind /usr/local/bin/kind
fi
echo "  kind: $(kind version)"

# kubectl
if ! command -v kubectl &>/dev/null; then
    echo "  Installing kubectl..."
    KUBE_VERSION=$(curl -sL https://dl.k8s.io/release/stable.txt)
    curl -sLO "https://dl.k8s.io/release/${KUBE_VERSION}/bin/linux/${ARCH_SUFFIX}/kubectl"
    chmod +x kubectl
    sudo mv kubectl /usr/local/bin/kubectl
fi
echo "  kubectl: $(kubectl version --client --short 2>/dev/null || kubectl version --client)"

# helm
if ! command -v helm &>/dev/null; then
    echo "  Installing helm..."
    curl -s https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
fi
echo "  helm: $(helm version --short)"

echo ""

# ===========================================================================
# Step 2: Create kind cluster
# ===========================================================================
echo "[Step 2/7] Creating kind cluster..."

# Check if cluster already exists
if kind get clusters 2>/dev/null | grep -q "^${CLUSTER_NAME}$"; then
    echo "  Cluster '${CLUSTER_NAME}' already exists. Reusing."
else
    # Create kind config
    mkdir -p "${ORCASHELL_ROOT}/deploy/kind"
    cat > "${ORCASHELL_ROOT}/deploy/kind/kind-config.yaml" << 'KINDEOF'
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
name: orcashell
nodes:
- role: control-plane
  extraMounts:
  - hostPath: /dev/nvidia0
    containerPath: /dev/nvidia0
  - hostPath: /dev/nvidiactl
    containerPath: /dev/nvidiactl
  - hostPath: /dev/nvidia-uvm
    containerPath: /dev/nvidia-uvm
KINDEOF

    # Remove GPU mounts if no NVIDIA device exists
    if [ ! -e /dev/nvidia0 ]; then
        echo "  No NVIDIA GPU detected, creating cluster without GPU mounts"
        cat > "${ORCASHELL_ROOT}/deploy/kind/kind-config.yaml" << 'KINDEOF'
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
name: orcashell
nodes:
- role: control-plane
KINDEOF
    fi

    kind create cluster --config "${ORCASHELL_ROOT}/deploy/kind/kind-config.yaml"
fi

kubectl cluster-info --context "kind-${CLUSTER_NAME}"
echo ""

# ===========================================================================
# Step 3: Create namespace
# ===========================================================================
echo "[Step 3/7] Creating namespace..."
kubectl create namespace "${NAMESPACE}" --dry-run=client -o yaml | kubectl apply -f -
echo ""

# ===========================================================================
# Step 4: Generate TLS certificates
# ===========================================================================
echo "[Step 4/7] Generating TLS certificates..."
mkdir -p "${CERT_DIR}"
cd "${CERT_DIR}"

# CA (v3)
openssl genrsa -out ca.key 2048 2>/dev/null
openssl req -x509 -new -key ca.key -days 365 -out ca.crt \
    -subj "/CN=orcashell-ca" \
    -addext "basicConstraints=critical,CA:TRUE" \
    -addext "keyUsage=critical,keyCertSign,cRLSign" 2>/dev/null

# Server cert (v3 + SAN)
cat > v3.ext << 'EXTEOF'
basicConstraints=CA:FALSE
subjectAltName=DNS:openshell.openshell.svc.cluster.local,DNS:openshell,DNS:localhost,IP:127.0.0.1
EXTEOF

openssl genrsa -out server.key 2048 2>/dev/null
openssl req -new -key server.key -out server.csr \
    -subj "/CN=openshell.openshell.svc.cluster.local" 2>/dev/null
openssl x509 -req -in server.csr -CA ca.crt -CAkey ca.key \
    -CAcreateserial -days 365 -out server.crt -extfile v3.ext 2>/dev/null

# Create K8s secrets (idempotent)
kubectl delete secret openshell-server-tls openshell-server-client-ca \
    openshell-client-tls openshell-ssh-handshake \
    -n "${NAMESPACE}" 2>/dev/null || true

kubectl create secret tls openshell-server-tls \
    --cert=server.crt --key=server.key -n "${NAMESPACE}"
kubectl create secret generic openshell-server-client-ca \
    --from-file=ca.crt=ca.crt -n "${NAMESPACE}"
kubectl create secret tls openshell-client-tls \
    --cert=server.crt --key=server.key -n "${NAMESPACE}"
kubectl create secret generic openshell-ssh-handshake \
    --from-literal=secret="$(openssl rand -hex 32)" -n "${NAMESPACE}"

echo "  TLS certificates created"
echo ""

# ===========================================================================
# Step 5: Install Sandbox CRD
# ===========================================================================
echo "[Step 5/7] Installing Sandbox CRD..."
kubectl apply -f "${ORCASHELL_ROOT}/deploy/kube/manifests/agent-sandbox.yaml"
sleep 3
kubectl get crd | grep sandbox
echo ""

# ===========================================================================
# Step 6: Deploy OpenShell Gateway via Helm
# ===========================================================================
echo "[Step 6/7] Deploying OpenShell Gateway..."
helm upgrade --install openshell \
    "${ORCASHELL_ROOT}/deploy/helm/openshell/" \
    --namespace "${NAMESPACE}" \
    --set image.pullPolicy=IfNotPresent \
    --wait --timeout 120s 2>/dev/null || \
helm upgrade --install openshell \
    "${ORCASHELL_ROOT}/deploy/helm/openshell/" \
    --namespace "${NAMESPACE}" \
    --set image.pullPolicy=IfNotPresent

echo "  Waiting for Gateway pod..."
kubectl wait --for=condition=Ready pod/openshell-0 \
    -n "${NAMESPACE}" --timeout=120s 2>/dev/null || true
echo ""

# ===========================================================================
# Step 7: Verify deployment
# ===========================================================================
echo "[Step 7/7] Verifying deployment..."
echo ""
echo "--- Pods ---"
kubectl get pods -A
echo ""
echo "--- Services ---"
kubectl get svc -n "${NAMESPACE}"
echo ""
echo "--- CRDs ---"
kubectl get crd | grep sandbox
echo ""

# Check Gateway status
GATEWAY_STATUS=$(kubectl get pod openshell-0 -n "${NAMESPACE}" -o jsonpath='{.status.phase}' 2>/dev/null || echo "Unknown")

echo "======================================================================"
echo "  OrcaShell Deployment Complete"
echo "======================================================================"
echo ""
echo "  Cluster:     kind-${CLUSTER_NAME} (Kubernetes $(kubectl version --short 2>/dev/null | grep Server | awk '{print $3}' || echo 'v1.35+'))"
echo "  Gateway:     ${GATEWAY_STATUS}"
echo "  Namespace:   ${NAMESPACE}"
echo ""
echo "  Next steps:"
echo "    # Create a test sandbox"
echo "    kubectl apply -f deploy/kind/test-sandbox.yaml"
echo ""
echo "    # Check sandbox status"
echo "    kubectl get sandbox -n ${NAMESPACE}"
echo "    kubectl get pods -n ${NAMESPACE}"
echo ""
echo "    # Deploy HAMI for GPU multi-tenancy"
echo "    kubectl apply -f deploy/kube/gpu-manifests/"
echo ""
echo "    # Destroy cluster"
echo "    kind delete cluster --name ${CLUSTER_NAME}"
echo "======================================================================"#!/bin/bash
# SPDX-License-Identifier: Apache-2.0
# OrcaShell - One-click deployment script
# Deploys OpenShell on kind (Kubernetes in Docker) instead of k3s
#
# Usage:
#   chmod +x deploy-orcashell.sh
#   ./deploy-orcashell.sh
#
# Prerequisites:
#   - Docker running
#   - Internet access (for pulling images)

set -e

CLUSTER_NAME="orcashell"
NAMESPACE="openshell"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ORCASHELL_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
CERT_DIR="/tmp/orcashell-certs"
ARCH=$(uname -m)

# Normalize arch
case "$ARCH" in
    x86_64)  ARCH_SUFFIX="amd64" ;;
    aarch64) ARCH_SUFFIX="arm64" ;;
    *)       echo "Unsupported architecture: $ARCH"; exit 1 ;;
esac

echo "======================================================================"
echo "  OrcaShell Deployment Script"
echo "  Kubernetes (kind) + OpenShell Gateway + Sandbox CRD"
echo "======================================================================"
echo ""
echo "  Architecture: $ARCH ($ARCH_SUFFIX)"
echo "  Cluster name: $CLUSTER_NAME"
echo "  Namespace:    $NAMESPACE"
echo ""

# ===========================================================================
# Step 1: Install prerequisites
# ===========================================================================
echo "[Step 1/7] Checking prerequisites..."

# kind
if ! command -v kind &>/dev/null; then
    echo "  Installing kind..."
    curl -sLo ./kind "https://kind.sigs.k8s.io/dl/latest/kind-linux-${ARCH_SUFFIX}"
    chmod +x ./kind
    sudo mv ./kind /usr/local/bin/kind
fi
echo "  kind: $(kind version)"

# kubectl
if ! command -v kubectl &>/dev/null; then
    echo "  Installing kubectl..."
    KUBE_VERSION=$(curl -sL https://dl.k8s.io/release/stable.txt)
    curl -sLO "https://dl.k8s.io/release/${KUBE_VERSION}/bin/linux/${ARCH_SUFFIX}/kubectl"
    chmod +x kubectl
    sudo mv kubectl /usr/local/bin/kubectl
fi
echo "  kubectl: $(kubectl version --client --short 2>/dev/null || kubectl version --client)"

# helm
if ! command -v helm &>/dev/null; then
    echo "  Installing helm..."
    curl -s https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
fi
echo "  helm: $(helm version --short)"

echo ""

# ===========================================================================
# Step 2: Create kind cluster
# ===========================================================================
echo "[Step 2/7] Creating kind cluster..."

# Check if cluster already exists
if kind get clusters 2>/dev/null | grep -q "^${CLUSTER_NAME}$"; then
    echo "  Cluster '${CLUSTER_NAME}' already exists. Reusing."
else
    # Create kind config
    mkdir -p "${ORCASHELL_ROOT}/deploy/kind"
    cat > "${ORCASHELL_ROOT}/deploy/kind/kind-config.yaml" << 'KINDEOF'
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
name: orcashell
nodes:
- role: control-plane
  extraMounts:
  - hostPath: /dev/nvidia0
    containerPath: /dev/nvidia0
  - hostPath: /dev/nvidiactl
    containerPath: /dev/nvidiactl
  - hostPath: /dev/nvidia-uvm
    containerPath: /dev/nvidia-uvm
KINDEOF

    # Remove GPU mounts if no NVIDIA device exists
    if [ ! -e /dev/nvidia0 ]; then
        echo "  No NVIDIA GPU detected, creating cluster without GPU mounts"
        cat > "${ORCASHELL_ROOT}/deploy/kind/kind-config.yaml" << 'KINDEOF'
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
name: orcashell
nodes:
- role: control-plane
KINDEOF
    fi

    kind create cluster --config "${ORCASHELL_ROOT}/deploy/kind/kind-config.yaml"
fi

kubectl cluster-info --context "kind-${CLUSTER_NAME}"
echo ""

# ===========================================================================
# Step 3: Create namespace
# ===========================================================================
echo "[Step 3/7] Creating namespace..."
kubectl create namespace "${NAMESPACE}" --dry-run=client -o yaml | kubectl apply -f -
echo ""

# ===========================================================================
# Step 4: Generate TLS certificates
# ===========================================================================
echo "[Step 4/7] Generating TLS certificates..."
mkdir -p "${CERT_DIR}"
cd "${CERT_DIR}"

# CA (v3)
openssl genrsa -out ca.key 2048 2>/dev/null
openssl req -x509 -new -key ca.key -days 365 -out ca.crt \
    -subj "/CN=orcashell-ca" \
    -addext "basicConstraints=critical,CA:TRUE" \
    -addext "keyUsage=critical,keyCertSign,cRLSign" 2>/dev/null

# Server cert (v3 + SAN)
cat > v3.ext << 'EXTEOF'
basicConstraints=CA:FALSE
subjectAltName=DNS:openshell.openshell.svc.cluster.local,DNS:openshell,DNS:localhost,IP:127.0.0.1
EXTEOF

openssl genrsa -out server.key 2048 2>/dev/null
openssl req -new -key server.key -out server.csr \
    -subj "/CN=openshell.openshell.svc.cluster.local" 2>/dev/null
openssl x509 -req -in server.csr -CA ca.crt -CAkey ca.key \
    -CAcreateserial -days 365 -out server.crt -extfile v3.ext 2>/dev/null

# Create K8s secrets (idempotent)
kubectl delete secret openshell-server-tls openshell-server-client-ca \
    openshell-client-tls openshell-ssh-handshake \
    -n "${NAMESPACE}" 2>/dev/null || true

kubectl create secret tls openshell-server-tls \
    --cert=server.crt --key=server.key -n "${NAMESPACE}"
kubectl create secret generic openshell-server-client-ca \
    --from-file=ca.crt=ca.crt -n "${NAMESPACE}"
kubectl create secret tls openshell-client-tls \
    --cert=server.crt --key=server.key -n "${NAMESPACE}"
kubectl create secret generic openshell-ssh-handshake \
    --from-literal=secret="$(openssl rand -hex 32)" -n "${NAMESPACE}"

echo "  TLS certificates created"
echo ""

# ===========================================================================
# Step 5: Install Sandbox CRD
# ===========================================================================
echo "[Step 5/7] Installing Sandbox CRD..."
kubectl apply -f "${ORCASHELL_ROOT}/deploy/kube/manifests/agent-sandbox.yaml"
sleep 3
kubectl get crd | grep sandbox
echo ""

# ===========================================================================
# Step 6: Deploy OpenShell Gateway via Helm
# ===========================================================================
echo "[Step 6/7] Deploying OpenShell Gateway..."
helm upgrade --install openshell \
    "${ORCASHELL_ROOT}/deploy/helm/openshell/" \
    --namespace "${NAMESPACE}" \
    --set image.pullPolicy=IfNotPresent \
    --wait --timeout 120s 2>/dev/null || \
helm upgrade --install openshell \
    "${ORCASHELL_ROOT}/deploy/helm/openshell/" \
    --namespace "${NAMESPACE}" \
    --set image.pullPolicy=IfNotPresent

echo "  Waiting for Gateway pod..."
kubectl wait --for=condition=Ready pod/openshell-0 \
    -n "${NAMESPACE}" --timeout=120s 2>/dev/null || true
echo ""

# ===========================================================================
# Step 7: Verify deployment
# ===========================================================================
echo "[Step 7/7] Verifying deployment..."
echo ""
echo "--- Pods ---"
kubectl get pods -A
echo ""
echo "--- Services ---"
kubectl get svc -n "${NAMESPACE}"
echo ""
echo "--- CRDs ---"
kubectl get crd | grep sandbox
echo ""

# Check Gateway status
GATEWAY_STATUS=$(kubectl get pod openshell-0 -n "${NAMESPACE}" -o jsonpath='{.status.phase}' 2>/dev/null || echo "Unknown")

echo "======================================================================"
echo "  OrcaShell Deployment Complete"
echo "======================================================================"
echo ""
echo "  Cluster:     kind-${CLUSTER_NAME} (Kubernetes $(kubectl version --short 2>/dev/null | grep Server | awk '{print $3}' || echo 'v1.35+'))"
echo "  Gateway:     ${GATEWAY_STATUS}"
echo "  Namespace:   ${NAMESPACE}"
echo ""
echo "  Next steps:"
echo "    # Create a test sandbox"
echo "    kubectl apply -f deploy/kind/test-sandbox.yaml"
echo ""
echo "    # Check sandbox status"
echo "    kubectl get sandbox -n ${NAMESPACE}"
echo "    kubectl get pods -n ${NAMESPACE}"
echo ""
echo "    # Deploy HAMI for GPU multi-tenancy"
echo "    kubectl apply -f deploy/kube/gpu-manifests/"
echo ""
echo "    # Destroy cluster"
echo "    kind delete cluster --name ${CLUSTER_NAME}"
echo "======================================================================"
