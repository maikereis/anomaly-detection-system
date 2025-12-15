## Troubleshooting

### Minikube não inicia

```bash
minikube delete
minikube start --cpus=6 --memory=12288 --driver=docker
```

### ArgoCD UI não acessível

```bash
# Verificar se o pod está rodando
kubectl get pods -n argocd

# Refazer port-forward
kubectl port-forward svc/argocd-server -n argocd 8080:443
```

### Problemas com autenticação SSH

```bash
# Verificar se a secret foi criada corretamente
kubectl get secret repo-anomaly-detection-system-ssh -n argocd -o yaml

# Verificar logs do ArgoCD
kubectl logs -n argocd deployment/argocd-repo-server

# Testar conexão SSH manualmente
ssh -i ~/.ssh/argocd_rsa -T git@github.com
```

### Application no ArgoCD fica "OutOfSync"

```bash
# Verificar detalhes da aplicação
argocd app get ml-system-minikube

# Verificar diferenças
argocd app diff ml-system-minikube

# Forçar sincronização
argocd app sync ml-system-minikube --force

# Se persistir, verificar logs
kubectl logs -n argocd deployment/argocd-application-controller
```

### Pods em CrashLoopBackOff

```bash
# Identificar o pod problemático
kubectl get pods -n ml-dev

# Ver logs
kubectl logs -n ml-dev <POD_NAME> --previous

# Descrever pod para ver eventos
kubectl describe pod -n ml-dev <POD_NAME>

# Verificar recursos
kubectl top pods -n ml-dev
```

### PostgreSQL não inicia

```bash
# Verificar PVC
kubectl get pvc -n ml-dev

# Verificar logs
kubectl logs -n ml-dev -l app=postgresql-mlflow

# Verificar configuração
kubectl get configmap postgresql-mlflow-config -n ml-dev -o yaml

# Reiniciar StatefulSet
kubectl rollout restart statefulset postgresql-mlflow -n ml-dev
```

### MinIO não acessível

```bash
# Verificar deployment
kubectl get deployment minio-mlflow -n ml-dev

# Verificar service
kubectl get svc minio-mlflow -n ml-dev

# Verificar logs
kubectl logs -n ml-dev -l app=minio-mlflow

# Verificar credenciais
kubectl get secret minio-mlflow-secret -n ml-dev -o jsonpath='{.data}' | jq
```

### MLflow não conecta ao backend

```bash
# Verificar se PostgreSQL está healthy
kubectl exec -it -n ml-dev postgresql-mlflow-0 -- psql -U mlflow -d mlflow -c "SELECT 1;"

# Verificar se MinIO está healthy
kubectl exec -it -n ml-dev deployment/minio-mlflow -- mc ping local

# Verificar logs do MLflow
kubectl logs -n ml-dev -l app=mlflow -f

# Verificar variáveis de ambiente
kubectl get deployment mlflow -n ml-dev -o yaml | grep -A 20 env:
```

### Ray Cluster não fica Ready

```bash
# Verificar status detalhado
kubectl describe ray-serve -n ml-dev

# Verificar pods do Ray
kubectl get pods -n ml-dev -l ray.io/cluster

# Verificar logs do head node
kubectl logs -n ml-dev -l ray.io/node-type=head

# Verificar logs dos workers
kubectl logs -n ml-dev -l ray.io/node-type=worker

# Verificar recursos disponíveis
kubectl top nodes
kubectl describe node

# Verificar eventos do namespace
kubectl get events -n ml-dev --sort-by='.lastTimestamp'

# Acessar o head node para debug
kubectl exec -it -n ml-dev <ray-head-pod> -- bash
# Dentro do pod:
ray status
python -c "import ray; ray.init(); print(ray.cluster_resources())"
```

### Ray Serve Deployment não funciona

```bash
# Verificar RayService
kubectl get rayservice -n ml-dev
kubectl describe rayservice -n ml-dev

# Verificar serve deployments no dashboard
kubectl port-forward -n ml-dev svc/raycluster-head-svc 8265:8265
# Acessar: http://localhost:8265

# Verificar logs de serve
kubectl logs -n ml-dev -l ray.io/serve=true

# Testar deployment manualmente no head node
kubectl exec -it -n ml-dev <ray-head-pod> -- python
# Python:
import ray
from ray import serve
ray.init(address="auto")
serve.status()

# Verificar configuração do serve
kubectl get cm -n ml-dev | grep serve
kubectl describe cm <serve-config> -n ml-dev
```

### Istio Gateway não roteia tráfego

```bash
# Verificar Gateway
kubectl get gateway -n ml-dev -o yaml

# Verificar VirtualService
kubectl get virtualservice -n ml-dev -o yaml

# Verificar configuração do Istio Proxy
kubectl logs -n ml-dev <POD_NAME> -c istio-proxy

# Verificar se o namespace tem label do Istio
kubectl get namespace ml-dev --show-labels

# Adicionar label se necessário
kubectl label namespace ml-dev istio-injection=enabled

# Reiniciar pods para injetar sidecar
kubectl rollout restart deployment -n ml-dev
```

### Prometheus não coleta métricas

```bash
# Verificar ServiceMonitor
kubectl get servicemonitor -n ml-dev

# Verificar targets no Prometheus
kubectl port-forward -n monitoring svc/prometheus-operator-kube-p-prometheus 9090:9090
# Acessar: http://localhost:9090/targets

# Verificar se o Ray exporta métricas
kubectl exec -it -n ml-dev <ray-head-pod> -- curl localhost:8080/metrics

# Verificar configuração do Prometheus
kubectl get prometheus -n monitoring -o yaml

# Verificar se o ServiceMonitor está sendo detectado
kubectl logs -n monitoring -l app.kubernetes.io/name=prometheus-operator