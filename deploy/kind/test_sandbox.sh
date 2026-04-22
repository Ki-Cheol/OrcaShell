# OrcaShell test sandbox
# Usage: kubectl apply -f deploy/kind/test-sandbox.yaml
apiVersion: agents.x-k8s.io/v1alpha1
kind: Sandbox
metadata:
  name: test-sandbox
  namespace: openshell
spec:
  podTemplate:
    spec:
      containers:
      - name: sandbox
        image: ghcr.io/nvidia/openshell-community/sandboxes/base:latest
        command: ["sleep", "infinity"]
 
