#!/usr/bin/env bash
# End-to-end Kubernetes demo on kind: cluster, ingress, metrics-server, deploy v1,
# zero-downtime rolling update to v2 under load, then `kubectl rollout undo`.
# Run from the repo root. Needs docker; installs kind/kubectl into ./bin if missing.
set -euo pipefail

KIND_VERSION="v0.25.0"
KUBECTL_VERSION="v1.31.4"
CLUSTER="devops-task"
NS="devops-task"
HOSTNAME_HDR="devops-task.localtest.me"
mkdir -p bin; export PATH="$PWD/bin:$PATH"

command -v docker >/dev/null || { echo "docker is required" >&2; exit 1; }
if ! command -v kind >/dev/null; then
  curl -fsSLo bin/kind "https://kind.sigs.k8s.io/dl/${KIND_VERSION}/kind-linux-amd64"; chmod +x bin/kind
fi
if ! command -v kubectl >/dev/null; then
  curl -fsSLo bin/kubectl "https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/linux/amd64/kubectl"; chmod +x bin/kubectl
fi

kind get clusters | grep -qx "$CLUSTER" || kind create cluster --name "$CLUSTER" --config k8s/kind-config.yaml
kubectl cluster-info --context "kind-$CLUSTER" >/dev/null

echo "== ingress-nginx + metrics-server =="
kubectl apply -f "https://raw.githubusercontent.com/kubernetes/ingress-nginx/controller-v1.12.0/deploy/static/provider/kind/deploy.yaml"
kubectl apply -f "https://github.com/kubernetes-sigs/metrics-server/releases/download/v0.7.2/components.yaml"
kubectl -n kube-system patch deployment metrics-server --type=json \
  -p='[{"op":"add","path":"/spec/template/spec/containers/0/args/-","value":"--kubelet-insecure-tls"}]'
kubectl -n ingress-nginx wait --for=condition=ready pod -l app.kubernetes.io/component=controller --timeout=180s

echo "== build + load images v1 and v2 =="
for v in 1.0.0 2.0.0; do
  docker build -q -t "devops-task:$v" --build-arg "APP_VERSION=$v" app
  kind load docker-image "devops-task:$v" --name "$CLUSTER"
done

echo "== deploy v1 =="
kubectl apply -k k8s/
kubectl -n "$NS" set image deployment/devops-task app=devops-task:1.0.0
kubectl -n "$NS" rollout status deployment/devops-task --timeout=120s
kubectl -n "$NS" get pods,svc,ingress,hpa

probe() { curl -s -o /dev/null -w '%{http_code}\n' -H "Host: $HOSTNAME_HDR" http://localhost/ || echo 000; }
LOAD_OUT=$(mktemp)
( while true; do probe; sleep 0.1; done ) > "$LOAD_OUT" &
LOAD_PID=$!
trap 'kill $LOAD_PID 2>/dev/null || true' EXIT

echo "== rolling update to v2 (traffic running) =="
kubectl -n "$NS" set image deployment/devops-task app=devops-task:2.0.0
kubectl -n "$NS" rollout status deployment/devops-task --timeout=120s
curl -s -H "Host: $HOSTNAME_HDR" http://localhost/; echo
kubectl -n "$NS" rollout history deployment/devops-task

echo "== rollback =="
kubectl -n "$NS" rollout undo deployment/devops-task
kubectl -n "$NS" rollout status deployment/devops-task --timeout=120s
curl -s -H "Host: $HOSTNAME_HDR" http://localhost/; echo

kill "$LOAD_PID" 2>/dev/null || true
echo "== availability during update + rollback =="
sort "$LOAD_OUT" | uniq -c
echo "(only 200 expected; any other code means dropped requests)"
