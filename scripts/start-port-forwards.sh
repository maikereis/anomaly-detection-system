#!/usr/bin/env bash

echo "Starting port-forwards in background..."

# Kill existing port-forwards
pkill -f "kubectl.*port-forward" 2>/dev/null || true
sleep 2

# ArgoCD (8080 -> 443)
kubectl port-forward svc/argocd-server -n argocd 8080:443 > /dev/null 2>&1 &
echo "✓ ArgoCD UI: https://localhost:8080"

# Grafana (3000 -> 80)
kubectl port-forward -n monitoring svc/prometheus-operator-grafana 3000:80 > /dev/null 2>&1 &
echo "✓ Grafana: http://localhost:3000"

# MinIO
kubectl port-forward -n ml-dev svc/minio-mlflow 9000:9000 9001:9001 > /dev/null 2>&1 &
echo "✓ MinIO: http://localhost:9001"

# Prometheus (9090 -> 9090)
kubectl port-forward -n monitoring svc/prometheus-operator-kube-p-prometheus 9090:9090 > /dev/null 2>&1 &
echo "✓ Prometheus: http://localhost:9090"

# Ray-Serve (8265 -> 8265)
kubectl port-forward -n ml-dev svc/anomaly-detector-head-svc 8265:8265 > /dev/null 2>&1 &
echo "✓ Ray-serve: http://localhost:8265"

# Mlflow (5000 -> 5000)
kubectl port-forward -n ml-dev svc/mlflow-server 5000:5000 > /dev/null 2>&1 &
echo "✓ Mlflow: http://localhost:5000"

# Anomaly Detector (8000 -> 8000)
kubectl port-forward -n ml-dev svc/anomaly-detector-serve-svc 8000:8000 > /dev/null 2>&1 &
echo "✓ Anomaly Detector: http://localhost:8000"

# RabbitMQ (15672 -> 15672)
kubectl port-forward -n ml-dev svc/rabbitmq 15672:15672
echo "✓ RabbitMQ: http://localhost:15672"

echo ""
echo "Port-forwards running in background."
echo "To stop: pkill -f 'kubectl.*port-forward'"