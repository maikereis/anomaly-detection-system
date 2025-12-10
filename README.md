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

## Setup Automatizado

Para setup completo do ambiente, use o script automatizado:

```bash
chmod +x scripts/1-config-cluster.sh
./scripts/1-config-cluster.sh
```

Este script irá:
- Iniciar o Minikube
- Instalar Istio
- Instalar Cert-Manager
- Instalar KubeRay Operator
- Instalar Prometheus Stack
- Instalar ArgoCD
---

## Setup Manual (Passo a Passo)

### 1. Iniciar Minikube

```bash
# Iniciar cluster (6 CPUs, 12GB RAM)
minikube start --cpus=6 --memory=12288 --driver=docker

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

### 2. Instalar Istio

```bash
# Adiciona Istio repo
helm repo add istio https://istio-release.storage.googleapis.com/charts
helm repo update

# Instala base
helm install istio-base istio/base -n istio-system --create-namespace --version 1.28.0

# Instala istiod
helm install istiod istio/istiod -n istio-system --version 1.28.0 --wait

# Instala o ingress gateway
helm install istio-ingress istio/gateway -n istio-system --version 1.28.0 --wait

# Verifica instalação
kubectl get pods -n istio-system
```

### 3. Instalar Cert-Manager

```bash
# Instala cert-manager (requerido para certificados TLS)
kubectl apply -f https://github.com/cert-manager/cert-manager/releases/download/v1.19.1/cert-manager.yaml

# Aguardar pods ficarem ready
kubectl wait --for=condition=available --timeout=300s deployment/cert-manager -n cert-manager
kubectl wait --for=condition=available --timeout=300s deployment/cert-manager-webhook -n cert-manager
kubectl wait --for=condition=available --timeout=300s deployment/cert-manager-cainjector -n cert-manager

# Verificar instalação
kubectl get pods -n cert-manager
```

### 4. Instalar KubeRay Operator

```bash
# Adicionar repositório KubeRay
helm repo add kuberay https://ray-project.github.io/kuberay-helm/
helm repo update

# Instalar KubeRay operator
helm install kuberay-operator kuberay/kuberay-operator \
  --namespace ray-system \
  --create-namespace \
  --version v1.5.1 \
  --wait

# Aguardar pods ficarem ready
kubectl wait --for=condition=available --timeout=300s deployment/kuberay-operator -n ray-system

# Verifica CRDs
kubectl get crd | grep ray.io
```

Você verá algo como:

```bash
rayclusters.ray.io                               2024-12-09T20:37:20Z
rayjobs.ray.io                                   2024-12-09T20:37:20Z
rayservices.ray.io                               2024-12-09T20:37:21Z
```

Verifica o operator:

```bash
kubectl get pods -n ray-system
```

### 5. Instalar Prometheus Operator

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

### 6. Instalar ArgoCD

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

#### Obter as credenciais

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

### 7. Fazer um fork/clone desse repositório

```bash
git clone https://github.com/<YOUR_USERNAME>/<YOUR_REPO>.git
cd <YOUR_REPO>
```

### 8. Atualizar os arquivos de configuração

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

### 9. Gerar chave SSH

```bash
# Gere um par de chaves
ssh-keygen -t ed25519 -C "argocd@minikube" -f ~/.ssh/argocd_rsa -N ""

# Visualize a chave pública gerada
cat ~/.ssh/argocd_rsa.pub
```

#### Adicionar Deploy Key no GitHub

Acesse: `https://github.com/<YOUR_USERNAME>/anomaly-detection-system/settings/keys`

Clique em **Add deploy key** (`https://github.com/<YOUR_USERNAME>/anomaly-detection-system/settings/keys/new`)

```
Title: <Escolha um nome>
Key: <Cole a chave retornada no comando 'cat' anteriormente>
```

#### Registrar a chave SSH como Secret no Kubernetes

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

### 10. Configurar ArgoCD Application

```bash
# Aplica ArgoCD manifestos (cria Project e Application)
kubectl apply -k manifests/argocd/

# Verifica se a aplicação foi criada
kubectl get application -n argocd

# Aguardar alguns segundos e verificar status
kubectl get application ml-system-minikube -n argocd -o yaml
```

### 11. Deploy da aplicação via ArgoCD

#### Opção A: Sync via UI do ArgoCD

1. Acesse https://localhost:8080
2. Login com `admin` e a senha obtida anteriormente
3. Clique na aplicação `ml-system-minikube`
4. Clique em **SYNC** → **SYNCHRONIZE**

#### Opção B: Sync via CLI

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

### 12. Verificar recursos implantados

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

# Verificar Ray Cluster
kubectl get raycluster -n ml-dev
kubectl describe raycluster -n ml-dev

# Verificar Ray Services (quando implantados)
kubectl get rayservice -n ml-dev
kubectl describe rayservice -n ml-dev

# Verificar recursos do Istio
kubectl get gateway -n ml-dev
kubectl get virtualservice -n ml-dev
kubectl get destinationrule -n ml-dev

# Verificar ServiceMonitor (Prometheus)
kubectl get servicemonitor -n ml-dev

# Verificar HPA
kubectl get hpa -n ml-dev
```

### 13. Acessar os serviços

#### MLflow UI

```bash
# Port-forward para MLflow
kubectl port-forward -n ml-dev svc/mlflow 5000:5000

# Acessar em: http://localhost:5000
```

#### MinIO Console

```bash
# Port-forward para MinIO
kubectl port-forward -n ml-dev svc/minio-mlflow 9001:9001

# Acessar em: http://localhost:9001
# Credenciais estão no secret: kubectl get secret minio-mlflow-secret -n ml-dev -o yaml
```

#### Ray Dashboard

```bash
# Port-forward para Ray Dashboard (quando cluster estiver rodando)
kubectl port-forward -n ml-dev svc/ray-serve 8265:8265

# Acessar em: http://localhost:8265
# Dashboard mostra:
# - Status do cluster Ray
# - Métricas de recursos (CPU, memória, GPU)
# - Jobs em execução
# - Deployments do Ray Serve
# - Logs dos workers
```

#### Grafana (já configurado anteriormente)

```bash
# Port-forward para Grafana (se não estiver rodando)
export POD_NAME=$(kubectl --namespace monitoring get pod -l "app.kubernetes.io/name=grafana,app.kubernetes.io/instance=prometheus-operator" -oname)
kubectl --namespace monitoring port-forward $POD_NAME 3000

# Acessar em: http://localhost:3000
# User: admin
# Password: obtida anteriormente com o comando na seção 5
```

### 14. Testar Ray Serve Deployment

```bash
# Obter o endpoint do Ray Serve
kubectl get svc -n ml-dev | grep ray

# Para ambiente local (Minikube), configurar ingress
# Obter IP do Minikube
minikube ip

# Adicionar entrada no /etc/hosts (substitua <MINIKUBE_IP> pelo IP obtido)
echo "<MINIKUBE_IP> anomaly-detector.local" | sudo tee -a /etc/hosts

# Testar endpoint de health (exemplo)
curl http://anomaly-detector.local/health

# Fazer uma predição (exemplo - ajuste conforme sua API)
curl -X POST http://anomaly-detector.local/predict \
  -H "Content-Type: application/json" \
  -d '{
    "data": [[1.0, 2.0, 3.0, 4.0, 5.0, 6.0, 7.0, 8.0, 9.0, 10.0]]
  }'

# Acessar métricas do Ray Serve
curl http://anomaly-detector.local/metrics
```

### 15. Workflow GitOps - Fazendo alterações

#### Fluxo de atualização via Git

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

#### Fazendo rollback

```bash
# Via ArgoCD CLI
argocd app rollback ml-system-minikube

# Ou via UI: Application → History and Rollback → selecionar revisão anterior
```

#### Testando mudanças localmente antes do commit

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
│   │   ├── ray-cluster/                          # Ray Cluster para computação distribuída e serving
│   │   │   ├── kustomization.yaml                # Agrega todos os manifestos do Ray
│   │   │   ├── raycluster.yaml                   # Define o RayCluster (head + workers)
│   │   │   ├── service.yaml                      # Services para head node (dashboard, serve)
│   │   │   └── servicemonitor.yaml               # ServiceMonitor para métricas do Prometheus
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
│   │       ├── minio-mlflow-pvc-patch.yaml       # Patch do PVC do MinIO
│   │       └── raycluster-patch.yaml             # Patch do RayCluster (recursos reduzidos)
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
kubectl port-forward -n monitoring svc/prometheus-operator-kube-p-prometheus 9090:9090


# Acessar em: http://localhost:9090
# Queries úteis:
# - up{namespace="ml-dev"}
# - ray_serve_deployment_request_counter
# - ray_serve_deployment_processing_latency_ms
# - container_cpu_usage_seconds_total{namespace="ml-dev"}
# - ray_cluster_active_nodes
```

### Ray Dashboard Metrics

O Ray Dashboard (port 8265) fornece:
- **Cluster**: Status dos nodes (head + workers)
- **Jobs**: Jobs em execução e histórico
- **Serve**: Deployments ativos, réplicas, latência
- **Actors**: Atores Ray em execução
- **Logs**: Logs centralizados de todos os nodes

### Logs centralizados

```bash
# Logs do MLflow
kubectl logs -n ml-dev -l app=mlflow -f

# Logs do Ray head node
kubectl logs -n ml-dev -l ray.io/node-type=head -f

# Logs dos Ray workers
kubectl logs -n ml-dev -l ray.io/node-type=worker -f

# Logs de um Ray Serve deployment específico
kubectl logs -n ml-dev -l ray.io/serve=true -f

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
   - **Ray Dashboard** - importar dashboard do Ray (ID: 17096)

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

## Troubleshooting

  [Me ajude!](TROUBLESHOOTING.md)