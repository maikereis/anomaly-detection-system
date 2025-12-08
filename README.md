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


## Instalando as dendencias

Você pode instalar as dependências corretas usando o script:

```bash
chmod +x scripts/0-install-dependencies.sh
./scripts/0-install-dependencies.sh
```

## Iniciar Minikube

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

## Instalar ArgoCD

```bash
# Criar namespace
kubectl create namespace argocd

# Instalar ArgoCD
kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml

# Aguardar pods ficarem ready
kubectl wait --for=condition=available --timeout=300s \
  deployment/argocd-server -n argocd

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

Obter as credenciais:

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

## Estrutura

```tree
├── manifests/                         # Manifestos Kubernetes gerenciados pelo ArgoCD
│   ├── base/                          # Recursos base reutilizados por todos os ambientes
│   │   ├── kustomization.yaml         # Agrega todos os recursos do diretório base
│   │   │
│   │   ├── namespace/
│   │   │   ├── kustomization.yaml     # Indexa o recurso de namespace para o Kustomize
│   │   │   └── namespace.yaml         # Define o Namespace (isolamento lógico no cluster)
│   │   │
│   │   ├── postgres-mlflow/           # Postgres database para o Mlflow
│   │   │   ├── configmap.yaml         # Configurações não sensíveis do Postgres
│   │   │   ├── secret.yaml            # Credenciais e dados sensíveis do Postgres
│   │   │   ├── kustomization.yaml     # Indexa os recursos do Postgres para o Kustomize
│   │   │   ├── pvc.yaml               # PersistentVolumeClaim que solicita armazenamento persistente
│   │   │   ├── service.yaml           # Serviço para expor o Postgres dentro do cluster
│   │   │   └── statefulset.yaml       # StatefulSet que define o Pod com armazenamento persistente
│   │   │
│   │   ├── minio-mlflow/              # MinIO utilizado como backend de artefatos do MLflow
│   │   │   ├── configmap.yaml         # Configurações não sensíveis do MinIO
│   │   │   ├── secret.yaml            # Credenciais e dados sensíveis do MinIO
│   │   │   ├── kustomization.yaml     # Agrega e indexa todos os recursos do MinIO para o Kustomize
│   │   │   ├── pvc.yaml               # PersistentVolumeClaim para armazenamento local dos buckets do MinIO
│   │   │   ├── service.yaml           # Service interno para expor o MinIO dentro do cluster
│   │   │   └── deployment.yaml        # Deployment do MinIO (container com credenciais montadas via Secret)
│   │   │
│   │   └── mlflow/                    # MLflow para o gerenciamento de experimentos e model registry
│   │       ├── configmap.yaml         # Configurações não sensíveis do Mlflow
│   │       ├── secret.yaml            # Credenciais e dados sensíveis do Mlflow
│   │       ├── kustomization.yaml     # Agrega e indexa todos os recursos do Mlflow para o Kustomize
│   │       ├── service.yaml           # Service interno para expor o Mlflow dentro do cluster
│   │       └── deployment.yaml        # Deployment do Mlflow (container com credenciais montadas via Secret)
│   │
│   ├── overlays/
│   │   └── minikube/                                     # Overlay para desenvolvimento local
│   │       ├── kustomization.yaml                        # Aplica patches e customizações específicas do ambiente Minikube
│   │       ├── namespace-patch.yaml                      # Patch que sobrescreve/ajusta o namespace para uso no Minikube
│   │       ├── postgresql-mlflow-statetulset-patch.yaml  # Patch que sobrescreve configurações statefulset do Postgres para uso no Minikube
│   │       ├── postgresql-mlflow-pvc-patch.yaml          # Patch que sobrescreve configurações do pvc do Postgres para uso no Minikube
│   │       ├── minio-mlflow-deployment.yaml              # Patch que sobrescreve configurações deployment do MinIO para uso no Minikube
│   │       └── minio-mlflow-pvc-patch.yaml               # Patch que sobrescreve configurações do pvc MinIO para uso no Minikube
│   │
│   └── argocd/                        # Configurações do ArgoCD
│       ├── kustomization.yaml         # Agrega e organiza os manifestos de ArgoCD
│       ├── project.yaml               # ArgoCD Project que define escopo e permissões dos apps
│       ├── app-minikube.yaml          # Aplicação ArgoCD apontando para o overlay de Minikube
│       └── app-aws.yaml               # Aplicação ArgoCD apontando para o overlay de produção na AWS
```

## Fazer um fork/clone desse respositório

```
git clone https://github.com/<YOUR_USERNAME>/<YOUR_REPO>.git
cd <YOUR_REPO>
```

## Atualizar os arquivos de configuração

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

## Gerar chave

```bash
# Gere um par de chaves
ssh-keygen -t ed25519 -C "argocd@minikube" -f ~/.ssh/argocd_rsa -N ""
# Visualize a chave pública gerada
cat ~/.ssh/argocd_rsa.pub
```


Em: https://github.com/<YOUR_USERNAME>/anomaly-detection-system/settings/keys

Click em Add deploy key (https://github.com/<YOUR_USERNAME>/anomaly-detection-system/settings/keys/new) 

```
Title: <Escolha um nome>
Key: <Cole a chave retornada no comando 'cat' anteriomente>
```

Agora podemos registrar a chave ssh como uma secret

```
# kubectl delete secret repo-anomaly-detection-system-ssh -n argocd  # caso precise

kubectl create secret generic repo-anomaly-detection-system-ssh \
  -n argocd \
  --from-literal=type=git \
  --from-literal=url=git@github.com:<YOUR_USERNAME>/anomaly-detection-system.git \
  --from-file=sshPrivateKey=$HOME/.ssh/argocd_rsa

kubectl label secret repo-anomaly-detection-system-ssh \
  -n argocd argocd.argoproj.io/secret-type=repository
```

## Documentação

0. [Contexto](docs/00-domain-context.md) - Contexto de domínio
1. [Requisitos](docs/01-requirements.md) - Requisitos funcionais e não-funcionais
2. [Estimativa de Capacidade](docs/02-capacity-estimation.md) - Cálculo de escala
3. [Desenho da API](docs/03-api-design.md) - Contratos de API
4. [Desenho de alto nível](docs/04-high-level-design.md) - Desenho de alto nível
