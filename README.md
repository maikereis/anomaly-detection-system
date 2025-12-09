# Anomaly Detection System

Sistema de detecção de anomalias

---

## Sobre

Este repositório documenta o processo de desenho de um sistema de detecção de anomalias.

## Pré-requisitos

- **Docker**: 29.1.1, build: 0aedba5
- **kubectl**: v1.34.2
- **Kustomize**: v5.7.1
- **Minikube**: v1.37.0, commit: 65318f4
- **Helm**: v3.19.2, commit: 8766e71
- **Git**: 2.43.0
- **GitHub Personal Access Token** com permissões:
  - `repo` (acesso a repositórios privados)
  - `read:packages` (ler imagens do GHCR)

## Instalando as dependências

Você pode instalar as dependências corretas usando o script:

```bash
chmod +x scripts/0-install-dependencies.sh
./scripts/0-install-dependencies.sh
```

## 1. Iniciar Minikube

```bash
# Iniciar cluster (4 CPUs, 8GB RAM)
minikube start --cpus=4 --memory=8192 --driver=docker

# Habilitar addons essenciais
minikube addons enable ingress
minikube addons enable metrics-server
minikube addons enable dashboard

# Verificar status
minikube status
kubectl cluster-info
kubectl get nodes

# Abrir dashboard
minikube dashboard
```

## 2. Instalar Istio

```bash
# Adiciona Istio repo
helm repo add istio https://istio-release.storage.googleapis.com/charts
helm repo update

# Instala base
helm install istio-base istio/base -n istio-system --create-namespace

# Instala istiod (perfil default)
helm install istiod istio/istiod -n istio-system --wait

# Instala o ingress gateway
helm install istio-ingress istio/gateway -n istio-system

# Verifica instalação
kubectl get pods -n istio-system
```

## 3. Instalar Cert-Manager

```bash
# Instala cert-manager (requerido pelo KServe)
kubectl apply -f https://github.com/cert-manager/cert-manager/releases/latest/download/cert-manager.yaml

# Aguardar pods ficarem ready
kubectl wait --for=condition=available --timeout=300s deployment/cert-manager -n cert-manager
kubectl wait --for=condition=available --timeout=300s deployment/cert-manager-webhook -n cert-manager
kubectl wait --for=condition=available --timeout=300s deployment/cert-manager-cainjector -n cert-manager

# Verificar instalação
kubectl get pods -n cert-manager
```

## 4. Instalar KServe

```bash
# Instala o KServe CRDs e controlador
kubectl apply --server-side --force-conflicts -f https://github.com/kserve/kserve/releases/download/v0.16.0/kserve.yaml

# Aguardar pods ficarem ready
kubectl wait --for=condition=available --timeout=300s deployment/kserve-controller-manager -n kserve

# Verifica CRDs
kubectl get crd | grep kserve
```

Você verá algo como:

```bash
clusterservingruntimes.serving.kserve.io     2024-01-01T20:37:20Z
clusterstoragecontainers.serving.kserve.io   2024-01-01T20:37:20Z
inferencegraphs.serving.kserve.io            2024-01-01T20:37:20Z
inferenceservices.serving.kserve.io          2024-01-01T20:37:20Z
servingruntimes.serving.kserve.io            2024-01-01T20:37:21Z
trainedmodels.serving.kserve.io              2024-01-01T20:37:21Z
```

Verifica o controler:

```bash
kubectl get pods -n kserve
```

## 4. Instalar o Knative

```bash
kubectl apply -f https://github.com/knative/serving/releases/download/knative-v1.20.0/serving-crds.yaml

kubectl apply -f https://github.com/knative/serving/releases/download/knative-v1.20.0/serving-core.yaml
```

## 5. Instalar Prometheus Operator

```bash
# Adicionar repositório Helm
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo update

# Instalar kube-prometheus-stack
helm upgrade --install prometheus-operator prometheus-community/kube-prometheus-stack \
  --namespace monitoring \
  --create-namespace \
  --set prometheus.enabled=true \
  --set grafana.enabled=true \
  --set alertmanager.enabled=false \
  --set prometheusOperator.enabled=true \
  --set prometheus.prometheusSpec.serviceMonitorSelectorNilUsesHelmValues=false \
  --set prometheus.prometheusSpec.podMonitorSelectorNilUsesHelmValues=false \
  --wait \
  --timeout 5m

# Obter senha do Grafana
kubectl --namespace monitoring get secrets prometheus-operator-grafana -o jsonpath="{.data.admin-password}" | base64 -d ; echo

# Verificar instalação
kubectl get pods -n monitoring
kubectl get crd | grep monitoring.coreos.com

# Port-forward para acessar Grafana
export POD_NAME=$(kubectl --namespace monitoring get pod -l "app.kubernetes.io/name=grafana,app.kubernetes.io/instance=prometheus-operator" -oname)
kubectl --namespace monitoring port-forward $POD_NAME 3000
```

## 6. Instalar ArgoCD

```bash
# Criar namespace
kubectl create namespace argocd

# Instalar ArgoCD
kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml

# Aguardar pods ficarem ready
kubectl wait --for=condition=available --timeout=300s deployment/argocd-server -n argocd

# Verificar instalação
kubectl get pods -n argocd
```

Você verá algo como:

```bash
NAME                                        READY   STATUS    RESTARTS   AGE
argocd-application-controller-0             1/1     Running   0          2m36s
argocd-applicationset-controller-xxx        1/1     Running   0          2m37s
argocd-dex-server-xxx                       1/1     Running   0          2m36s
argocd-notifications-controller-xxx         1/1     Running   0          2m36s
argocd-redis-xxx                            1/1     Running   0          2m36s
argocd-repo-server-xxx                      1/1     Running   0          2m36s
argocd-server-xxxx                          1/1     Running   0          2m36s
```

### Obter as credenciais

```bash
# Obter senha inicial
ARGOCD_PASSWORD=$(kubectl -n argocd get secret argocd-initial-admin-secret \
  -o jsonpath="{.data.password}" | base64 -d)
echo "ArgoCD Password: $ARGOCD_PASSWORD"

# Será mostrado no terminal algo como 'ArgoCD Password: j3Awn291h######'

# Port-forward para acessar UI
kubectl port-forward svc/argocd-server -n argocd 8080:443 &
```

Acesse https://localhost:8080 e use as credenciais:

```
User: admin
Pass: <valor de ARGOCD_PASSWORD>
```

## 7. Fazer um fork/clone desse repositório

```bash
git clone https://github.com/<YOUR_USERNAME>/<YOUR_REPO>.git
cd <YOUR_REPO>
```

## 8. Atualizar os arquivos de configuração

Em `manifests/argocd/app-minikube.yaml`:

```yaml
source:
  repoURL: git@github.com:<YOUR_USERNAME>/anomaly-detection-system.git
  
info:
  - name: Contact
    value: your-email@example.com
```

Em `manifests/overlays/minikube/kustomization.yaml`:

```yaml
commonAnnotations:
  contact: your-email@example.com
  documentation: https://github.com/<YOUR_USERNAME>/anomaly-detection-system
```

## 9. Gerar chave SSH

```bash
# Gere um par de chaves
ssh-keygen -t ed25519 -C "argocd@minikube" -f ~/.ssh/argocd_rsa -N ""

# Visualize a chave pública gerada
cat ~/.ssh/argocd_rsa.pub
```

### Adicionar Deploy Key no GitHub

Acesse: `https://github.com/<YOUR_USERNAME>/anomaly-detection-system/settings/keys`

Clique em **Add deploy key** (`https://github.com/<YOUR_USERNAME>/anomaly-detection-system/settings/keys/new`)

```
Title: <Escolha um nome>
Key: <Cole a chave retornada no comando 'cat' anteriormente>
```

### Registrar a chave SSH como Secret no Kubernetes

```bash
# Remover secret existente (se necessário)
# kubectl delete secret repo-anomaly-detection-system-ssh -n argocd

# Criar secret com a chave SSH
kubectl create secret generic repo-anomaly-detection-system-ssh \
  -n argocd \
  --from-literal=type=git \
  --from-literal=url=git@github.com:<YOUR_USERNAME>/anomaly-detection-system.git \
  --from-file=sshPrivateKey=$HOME/.ssh/argocd_rsa

# Adicionar label para o ArgoCD reconhecer
kubectl label secret repo-anomaly-detection-system-ssh \
  -n argocd argocd.argoproj.io/secret-type=repository
```

## 10. Configurar ArgoCD Application

```bash
# Aplica ArgoCD manifestos (cria Project e Application)
kubectl apply -k manifests/argocd/

# Verifica se a aplicação foi criada
kubectl get application -n argocd

# Aguardar alguns segundos e verificar status
kubectl get application ml-system-minikube -n argocd -o yaml
```

## 11. Deploy da aplicação via ArgoCD

### Opção A: Sync via UI do ArgoCD

1. Acesse https://localhost:8080
2. Login com `admin` e a senha obtida anteriormente
3. Clique na aplicação `ml-system-minikube`
4. Clique em **SYNC** → **SYNCHRONIZE**

### Opção B: Sync via CLI

```bash
# Instalar ArgoCD CLI (se necessário)
# Linux
curl -sSL -o argocd https://github.com/argoproj/argo-cd/releases/latest/download/argocd-linux-amd64
chmod +x argocd
sudo mv argocd /usr/local/bin/

# Login no ArgoCD
argocd login localhost:8080 --username admin --password $ARGOCD_PASSWORD --insecure

# Sincronizar aplicação
argocd app sync ml-system-minikube

# Verificar status
argocd app get ml-system-minikube
```

## 12. Verificar recursos implantados

```bash
# Verificar namespace
kubectl get namespace ml-dev

# Verificar todos os recursos
kubectl get all -n ml-dev

# Verificar recursos específicos
kubectl get pods -n ml-dev
kubectl get svc -n ml-dev
kubectl get pvc -n ml-dev
kubectl get statefulsets -n ml-dev
kubectl get deployments -n ml-dev

# Verificar InferenceService do KServe
kubectl get isvc -n ml-dev
kubectl describe isvc -n ml-dev

# Verificar recursos do Istio
kubectl get gateway -n ml-dev
kubectl get virtualservice -n ml-dev
kubectl get destinationrule -n ml-dev

# Verificar ServiceMonitor (Prometheus)
kubectl get servicemonitor -n ml-dev

# Verificar HPA
kubectl get hpa -n ml-dev
```

## 13. Acessar os serviços

### MLflow UI

```bash
# Port-forward para MLflow
kubectl port-forward -n ml-dev svc/mlflow 5000:5000

# Acessar em: http://localhost:5000
```

### MinIO Console

```bash
# Port-forward para MinIO
kubectl port-forward -n ml-dev svc/minio-mlflow 9001:9001

# Acessar em: http://localhost:9001
# Credenciais estão no secret: kubectl get secret minio-mlflow-secret -n ml-dev -o yaml
```

### Grafana (já configurado anteriormente)

```bash
# Port-forward para Grafana (se não estiver rodando)
export POD_NAME=$(kubectl --namespace monitoring get pod -l "app.kubernetes.io/name=grafana,app.kubernetes.io/instance=prometheus-operator" -oname)
kubectl --namespace monitoring port-forward $POD_NAME 3000

# Acessar em: http://localhost:3000
# User: admin
# Password: obtida anteriormente com o comando na seção 5
```

## 14. Testar InferenceService

```bash
# Obter o endpoint do InferenceService
kubectl get isvc -n ml-dev

# Para ambiente local (Minikube), configurar ingress
# Obter IP do Minikube
minikube ip

# Adicionar entrada no /etc/hosts (substitua <MINIKUBE_IP> pelo IP obtido)
echo "<MINIKUBE_IP> anomaly-detector.local" | sudo tee -a /etc/hosts

# Testar endpoint de health
curl http://anomaly-detector.local/v1/models/anomaly-detector

# Fazer uma predição
curl -X POST http://anomaly-detector.local/v2/models/anomaly-detector/infer \
  -H "Content-Type: application/json" \
  -d '{
    "inputs": [{
      "name": "input-0",
      "shape": [1, 10],
      "datatype": "FP32",
      "data": [[1.0, 2.0, 3.0, 4.0, 5.0, 6.0, 7.0, 8.0, 9.0, 10.0]]
    }]
  }'
```

## 15. Workflow GitOps - Fazendo alterações

### Fluxo de atualização via Git

```bash
# 1. Fazer alterações nos manifestos
# Exemplo: alterar réplicas no deployment do MLflow
vim manifests/base/mlflow/deployment.yaml

# 2. Commitar e fazer push
git add .
git commit -m "feat: increase mlflow replicas to 2"
git push origin main

# 3. ArgoCD detecta mudanças automaticamente (polling padrão: 3min)
# Ou forçar sincronização imediata:
argocd app sync ml-system-minikube

# 4. Verificar aplicação das mudanças
kubectl get pods -n ml-dev -w
```

### Fazendo rollback

```bash
# Via ArgoCD CLI
argocd app rollback ml-system-minikube

# Ou via UI: Application → History and Rollback → selecionar revisão anterior
```

### Testando mudanças localmente antes do commit

```bash
# Aplicar manifestos diretamente (sem GitOps)
kubectl apply -k manifests/overlays/minikube/

# Verificar mudanças
kubectl get all -n ml-dev

# Se estiver ok, fazer commit
# Se não, reverter: kubectl delete -k manifests/overlays/minikube/
```

## Estrutura

```
.
├── manifests/                                    # Manifestos Kubernetes gerenciados pelo ArgoCD
│   ├── base/                                     # Recursos base reutilizados por todos os ambientes
│   │   ├── kustomization.yaml                    # Agrega todos os recursos do diretório base
│   │   │
│   │   ├── namespace/
│   │   │   ├── kustomization.yaml                # Indexa o recurso de namespace para o Kustomize
│   │   │   └── namespace.yaml                    # Define o Namespace (isolamento lógico no cluster)
│   │   │
│   │   ├── postgres-mlflow/                      # Postgres database para o Mlflow
│   │   │   ├── configmap.yaml                    # Configurações não sensíveis do Postgres
│   │   │   ├── secret.yaml                       # Credenciais e dados sensíveis do Postgres
│   │   │   ├── kustomization.yaml                # Indexa os recursos do Postgres para o Kustomize
│   │   │   ├── pvc.yaml                          # PersistentVolumeClaim que solicita armazenamento persistente
│   │   │   ├── service.yaml                      # Serviço para expor o Postgres dentro do cluster
│   │   │   └── statefulset.yaml                  # StatefulSet que define o Pod com armazenamento persistente
│   │   │
│   │   ├── minio-mlflow/                         # MinIO utilizado como backend de artefatos do MLflow
│   │   │   ├── configmap.yaml                    # Configurações não sensíveis do MinIO
│   │   │   ├── secret.yaml                       # Credenciais e dados sensíveis do MinIO
│   │   │   ├── kustomization.yaml                # Agrega e indexa todos os recursos do MinIO para o Kustomize
│   │   │   ├── pvc.yaml                          # PersistentVolumeClaim para armazenamento local dos buckets do MinIO
│   │   │   ├── service.yaml                      # Service interno para expor o MinIO dentro do cluster
│   │   │   └── deployment.yaml                   # Deployment do MinIO (container com credenciais montadas via Secret)
│   │   │
│   │   ├── mlflow/                               # MLflow para o gerenciamento de experimentos e model registry
│   │   │   ├── configmap.yaml                    # Configurações não sensíveis do Mlflow
│   │   │   ├── secret.yaml                       # Credenciais e dados sensíveis do Mlflow
│   │   │   ├── kustomization.yaml                # Agrega e indexa todos os recursos do Mlflow para o Kustomize
│   │   │   ├── service.yaml                      # Service interno para expor o Mlflow dentro do cluster
│   │   │   └── deployment.yaml                   # Deployment do Mlflow (container com credenciais montadas via Secret)
│   │   │
│   │   ├── kserve/                               # Inference serving com KServe
│   │   │   ├── kustomization.yaml                # Agrega recursos de serving
│   │   │   ├── serving-runtime.yaml              # Runtime MLflow para carregar modelos
│   │   │   ├── inference-service.yaml            # InferenceService que serve o modelo
│   │   │   ├── hpa.yaml                          # Autoscaling baseado em CPU/memória
│   │   │   └── service-monitor.yaml              # Prometheus metrics collection
│   │   │
│   │   └── istio/                                # Configuração de rede, segurança e roteamento usando Istio Service Mesh
│   │       ├── kustomization.yaml                # Agrega todos os manifests de Istio para o ambiente
│   │       ├── gateway.yaml                      # Gateway de entrada (Ingress Gateway do Istio)
│   │       ├── virtual-service.yaml              # Regras de roteamento L7 (HTTP) aplicadas após o Gateway
│   │       ├── destination-rule.yaml             # Define regras para destinos internos
│   │       ├── peer-authentication.yaml          # Define a política de autenticação mTLS entre pods
│   │       ├── request-authentication.yaml       # Configura como o Istio valida JWTs de requisições externas
│   │       └── authorization-policy.yaml         # Define políticas de autorização (RBAC do Istio)
│   │
│   ├── overlays/
│   │   └── minikube/                             # Overlay para desenvolvimento local
│   │       ├── kustomization.yaml                # Aplica patches e customizações específicas do ambiente Minikube
│   │       ├── namespace-patch.yaml              # Patch que sobrescreve/ajusta o namespace para uso no Minikube
│   │       ├── postgresql-mlflow-statefulset-patch.yaml  # Patch do StatefulSet do Postgres
│   │       ├── postgresql-mlflow-pvc-patch.yaml  # Patch do PVC do Postgres
│   │       ├── minio-mlflow-deployment-patch.yaml # Patch do Deployment do MinIO
│   │       └── minio-mlflow-pvc-patch.yaml       # Patch do PVC do MinIO
│   │
│   └── argocd/                                   # Configurações do ArgoCD
│       ├── kustomization.yaml                    # Agrega e organiza os manifestos de ArgoCD
│       ├── project.yaml                          # ArgoCD Project que define escopo e permissões dos apps
│       ├── app-minikube.yaml                     # Aplicação ArgoCD apontando para o overlay de Minikube
│       └── app-aws.yaml                          # Aplicação ArgoCD apontando para o overlay de produção na AWS
```

## 16. Monitoramento e Observabilidade

### Métricas do Prometheus

```bash
# Port-forward Prometheus
kubectl port-forward -n monitoring svc/prometheus-operator-kube-prom-prometheus 9090:9090

# Acessar em: http://localhost:9090
# Queries úteis:
# - up{namespace="ml-dev"}
# - kserve_inference_request_duration_seconds
# - container_cpu_usage_seconds_total{namespace="ml-dev"}
```

### Logs centralizados

```bash
# Logs do MLflow
kubectl logs -n ml-dev -l app=mlflow -f

# Logs do InferenceService (predictor)
kubectl logs -n ml-dev -l serving.kserve.io/inferenceservice=anomaly-detector-predictor -f

# Logs do PostgreSQL
kubectl logs -n ml-dev -l app=postgresql-mlflow -f

# Logs do MinIO
kubectl logs -n ml-dev -l app=minio-mlflow -f

# Todos os logs do namespace
kubectl logs -n ml-dev --all-containers=true -f
```

### Dashboards Grafana

1. Acesse Grafana em http://localhost:3000
2. Dashboards pré-configurados:
   - **Kubernetes / Compute Resources / Namespace (Pods)** - métricas por namespace
   - **Kubernetes / Compute Resources / Workload** - métricas por deployment/statefulset
   - **Prometheus / Stats** - métricas do próprio Prometheus

### Service Mesh (Istio) Observability

```bash
# Kiali (se instalado)
istioctl dashboard kiali

# Métricas de request latency
kubectl exec -n istio-system deployment/istiod -- \
  pilot-agent request GET stats/prometheus | grep istio_request_duration_milliseconds
```

## Documentação

0. [Contexto](docs/00-domain-context.md) - Contexto de domínio
1. [Requisitos](docs/01-requirements.md) - Requisitos funcionais e não-funcionais
2. [Estimativa de Capacidade](docs/02-capacity-estimation.md) - Cálculo de escala
3. [Desenho da API](docs/03-api-design.md) - Contratos de API
4. [Desenho de alto nível](docs/04-high-level-design.md) - Desenho de alto nível

---

## Troubleshooting

### Minikube não inicia

```bash
minikube delete
minikube start --cpus=4 --memory=8192 --driver=docker
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

### KServe InferenceService não fica Ready

```bash
# Verificar status detalhado
kubectl describe isvc -n ml-dev

# Verificar pods do predictor
kubectl get pods -n ml-dev -l serving.kserve.io/inferenceservice=anomaly-detector-predictor

# Verificar logs do predictor
kubectl logs -n ml-dev -l serving.kserve.io/inferenceservice=anomaly-detector-predictor -c kserve-container

# Verificar logs do storage-initializer (download do modelo)
kubectl logs -n ml-dev -l serving.kserve.io/inferenceservice=anomaly-detector-predictor -c storage-initializer

# Verificar se o modelo existe no MLflow
kubectl port-forward -n ml-dev svc/mlflow 5000:5000
# Acessar: http://localhost:5000

# Verificar eventos do namespace
kubectl get events -n ml-dev --sort-by='.lastTimestamp'
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
```

### Prometheus não coleta métricas

```bash
# Verificar ServiceMonitor
kubectl get servicemonitor -n ml-dev

# Verificar targets no Prometheus
kubectl port-forward -n monitoring svc/prometheus-operator-kube-prom-prometheus 9090:9090
# Acessar: http://localhost:9090/targets

# Verificar configuração do Prometheus
kubectl get prometheus -n monitoring -o yaml

# Verificar se o ServiceMonitor está sendo detectado
kubectl logs -n monitoring -l app.kubernetes.io/name=prometheus-operator
```

### Resources (CPU/Memory) insuficientes

```bash
# Verificar uso de recursos
kubectl top nodes
kubectl top pods -n ml-dev

# Aumentar recursos do Minikube
minikube stop
minikube start --cpus=6 --memory=12288

# Ou ajustar requests/limits nos manifestos
vim manifests/base/mlflow/deployment.yaml
```

### Limpeza completa e restart

```bash
# Deletar aplicação do ArgoCD
argocd app delete ml-system-minikube --cascade

# Ou via kubectl
kubectl delete application ml-system-minikube -n argocd

# Deletar namespace
kubectl delete namespace ml-dev

# Recriar via ArgoCD
kubectl apply -k manifests/argocd/
argocd app sync ml-system-minikube
```

## Quick Reference - Comandos Úteis

### Status do cluster

```bash
# Overview geral
kubectl get all -A
minikube status
kubectl cluster-info

# Uso de recursos
kubectl top nodes
kubectl top pods -A
```

### Acessar serviços rapidamente

```bash
# MLflow
kubectl port-forward -n ml-dev svc/mlflow 5000:5000 &

# MinIO Console
kubectl port-forward -n ml-dev svc/minio-mlflow 9001:9001 &

# Grafana
export POD_NAME=$(kubectl -n monitoring get pod -l "app.kubernetes.io/name=grafana" -oname)
kubectl -n monitoring port-forward $POD_NAME 3000 &

# ArgoCD
kubectl port-forward svc/argocd-server -n argocd 8080:443 &

# Prometheus
kubectl port-forward -n monitoring svc/prometheus-operator-kube-prom-prometheus 9090:9090 &
```

### Debugging rápido

```bash
# Logs em tempo real de todo namespace
kubectl logs -n ml-dev --all-containers=true -f --max-log-requests=20

# Entrar em pod para debug
kubectl exec -it -n ml-dev <POD_NAME> -- /bin/bash

# Eventos recentes
kubectl get events -n ml-dev --sort-by='.lastTimestamp' | tail -20

# Status de todos os recursos
kubectl get all,pvc,cm,secret,isvc,gateway,vs -n ml-dev
```

### ArgoCD

```bash
# Status de todas aplicações
argocd app list

# Sync forçado
argocd app sync ml-system-minikube --force --prune

# Ver logs de sync
argocd app logs ml-system-minikube -f

# Histórico de deploys
argocd app history ml-system-minikube
```

### Restart de componentes

```bash
# Restart deployment
kubectl rollout restart deployment mlflow -n ml-dev

# Restart statefulset
kubectl rollout restart statefulset postgresql-mlflow -n ml-dev

# Deletar pod (recriação automática)
kubectl delete pod <POD_NAME> -n ml-dev
```

### Backup e restore

```bash
# Backup de configurações
kubectl get all,pvc,cm,secret -n ml-dev -o yaml > backup-ml-dev.yaml

# Backup do GitOps
tar -czf argocd-backup.tar.gz manifests/

# Restore
kubectl apply -f backup-ml-dev.yaml
```

## Licença

[Especificar licença do projeto]

## Contato

[Seu email ou informações de contato]