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
```

## Documentação

0. [Contexto](docs/00-domain-context.md) - Contexto de domínio
1. [Requisitos](docs/01-requirements.md) - Requisitos funcionais e não-funcionais
2. [Estimativa de Capacidade](docs/02-capacity-estimation.md) - Cálculo de escala
3. [Desenho da API](docs/03-api-design.md) - Contratos de API
4. [Desenho de alto nível](docs/04-high-level-design.md) - Desenho de alto nível
