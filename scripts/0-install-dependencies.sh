#!/bin/bash

set -e

echo "========================================="
echo "Instalando Dependências Kubernetes"
echo "========================================="

# Cores para output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Função para verificar se o comando foi executado com sucesso
check_success() {
    if [ $? -eq 0 ]; then
        echo -e "${GREEN}✓ $1 instalado com sucesso${NC}"
    else
        echo -e "${RED}✗ Erro ao instalar $1${NC}"
        exit 1
    fi
}

# Detectar sistema operacional
OS=$(uname -s | tr '[:upper:]' '[:lower:]')
ARCH=$(uname -m)

case $ARCH in
    x86_64)
        ARCH="amd64"
        ;;
    aarch64)
        ARCH="arm64"
        ;;
esac

echo -e "${YELLOW}Sistema detectado: $OS/$ARCH${NC}"
echo ""

# Instalar Git 2.43.0
echo "Instalando Git 2.43.0..."
if command -v apt-get &> /dev/null; then
    sudo apt-get update
    sudo apt-get install -y git
elif command -v yum &> /dev/null; then
    sudo yum install -y git
elif command -v brew &> /dev/null; then
    brew install git
fi
check_success "Git"

# Instalar Docker 29.1.1
echo ""
echo "Instalando Docker 29.1.1..."
if [ "$OS" = "linux" ]; then
    # Remover instalações antigas e conflitantes
    echo "Removendo pacotes Docker conflitantes..."
    CONFLICTING_PKGS=$(dpkg --get-selections | grep -E 'docker|containerd|runc|podman' | cut -f1)
    if [ ! -z "$CONFLICTING_PKGS" ]; then
        sudo apt-get remove -y $CONFLICTING_PKGS 2>/dev/null || true
    fi
    
    # Limpar pacotes órfãos
    sudo apt-get autoremove -y
    
    # Remover configurações conflitantes
    sudo rm -f /etc/apt/sources.list.d/docker.list
    sudo rm -f /etc/apt/sources.list.d/docker.sources
    sudo rm -f /etc/apt/keyrings/docker.gpg
    sudo rm -f /etc/apt/keyrings/docker.asc
    
    # Instalar dependências
    sudo apt-get update
    sudo apt-get install -y ca-certificates curl
    sudo install -m 0755 -d /etc/apt/keyrings
    
    # Adicionar chave GPG oficial do Docker
    sudo curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
    sudo chmod a+r /etc/apt/keyrings/docker.asc
    
    # Adicionar repositório às fontes do APT
    echo \
      "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu \
      $(. /etc/os-release && echo "$VERSION_CODENAME") stable" | \
      sudo tee /etc/apt/sources.list.d/docker.list > /dev/null
    
    sudo apt-get update
    
    # Instalar Docker Engine
    sudo apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
    
    # Adicionar usuário ao grupo docker
    sudo usermod -aG docker $USER
    
elif [ "$OS" = "darwin" ]; then
    echo -e "${YELLOW}Para macOS, instale Docker Desktop manualmente de https://www.docker.com/products/docker-desktop${NC}"
fi
check_success "Docker"

# Instalar kubectl v1.34.2
echo ""
echo "Instalando kubectl v1.34.2..."
curl -LO "https://dl.k8s.io/release/v1.34.2/bin/$OS/$ARCH/kubectl"
chmod +x kubectl
sudo mv kubectl /usr/local/bin/
check_success "kubectl"

# Instalar Kustomize v5.7.1
echo ""
echo "Instalando Kustomize v5.7.1..."
curl -LO "https://github.com/kubernetes-sigs/kustomize/releases/download/kustomize%2Fv5.7.1/kustomize_v5.7.1_${OS}_${ARCH}.tar.gz"
tar -xzf kustomize_v5.7.1_${OS}_${ARCH}.tar.gz
chmod +x kustomize
sudo mv kustomize /usr/local/bin/
rm kustomize_v5.7.1_${OS}_${ARCH}.tar.gz
check_success "Kustomize"

# Instalar Minikube v1.37.0
echo ""
echo "Instalando Minikube v1.37.0..."
curl -LO "https://storage.googleapis.com/minikube/releases/v1.37.0/minikube-$OS-$ARCH"
chmod +x minikube-$OS-$ARCH
sudo mv minikube-$OS-$ARCH /usr/local/bin/minikube
check_success "Minikube"

# Instalar Helm v3.19.2
echo ""
echo "Instalando Helm v3.19.2..."
curl -LO "https://get.helm.sh/helm-v3.19.2-$OS-$ARCH.tar.gz"
tar -xzf helm-v3.19.2-$OS-$ARCH.tar.gz
sudo mv $OS-$ARCH/helm /usr/local/bin/
rm -rf $OS-$ARCH helm-v3.19.2-$OS-$ARCH.tar.gz
check_success "Helm"

echo ""
echo "========================================="
echo -e "${GREEN}Todas as dependências foram instaladas!${NC}"
echo "========================================="
echo ""
echo "Versões instaladas:"
echo "-------------------"

# Git
GIT_VERSION=$(git --version | awk '{print $3}')
echo "- **Git**: $GIT_VERSION"

# Docker
DOCKER_VERSION=$(docker --version | awk '{print $3}' | tr -d ',')
DOCKER_BUILD=$(docker version --format '{{.Server.GitCommit}}' 2>/dev/null | cut -c1-7)
echo "- **Docker**: $DOCKER_VERSION, build: $DOCKER_BUILD"

# kubectl
KUBECTL_VERSION=$(kubectl version --client --short 2>/dev/null | awk '{print $3}' || kubectl version --client -o json 2>/dev/null | grep -o '"gitVersion":"[^"]*"' | cut -d'"' -f4)
echo "- **kubectl**: $KUBECTL_VERSION"

# Kustomize
KUSTOMIZE_VERSION=$(kustomize version --short 2>/dev/null | awk '{print $1}' || kustomize version 2>/dev/null | grep -o 'v[0-9.]*')
echo "- **Kustomize**: $KUSTOMIZE_VERSION"

# Minikube
MINIKUBE_VERSION=$(minikube version --short 2>/dev/null | awk '{print $1}' || minikube version | grep 'minikube version:' | awk '{print $3}')
MINIKUBE_COMMIT=$(minikube version | grep 'commit:' | awk '{print $2}' | cut -c1-7)
echo "- **Minikube**: $MINIKUBE_VERSION, commit: $MINIKUBE_COMMIT"

# Helm
HELM_VERSION=$(helm version --short 2>/dev/null | awk '{print $1}' | tr -d 'v' || helm version --template='{{.Version}}' | tr -d 'v')
HELM_COMMIT=$(helm version --template='{{.GitCommit}}' 2>/dev/null | cut -c1-7)
echo "- **Helm**: v$HELM_VERSION, commit: $HELM_COMMIT"

echo ""
echo -e "${YELLOW}NOTA: Se você instalou o Docker, pode ser necessário fazer logout e login novamente para aplicar as permissões de grupo.${NC}"
echo -e "${YELLOW}Ou execute: newgrp docker${NC}"