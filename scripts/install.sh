#!/usr/bin/env bash

#==============================================================================
# Anomaly Detection System - Dependency Installation Script
#==============================================================================
# Description: Automated installation of required dependencies for local
#              Kubernetes development environment
# Author: Maike
# Version: 1.0.0
#==============================================================================

set -euo pipefail

#------------------------------------------------------------------------------
# Configuration
#------------------------------------------------------------------------------
readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly LOG_FILE="${SCRIPT_DIR}/install-$(date +%Y%m%d_%H%M%S).log"
readonly MIN_DOCKER_VERSION="20.10.0"
readonly MIN_KUBECTL_VERSION="1.27.0"

# Required versions
readonly MINIKUBE_VERSION="v1.37.0"
readonly KUBECTL_VERSION="v1.34.2"
readonly HELM_VERSION="v3.19.2"
readonly KUSTOMIZE_VERSION="v5.7.1"

# Colors for output
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly BLUE='\033[0;34m'
readonly NC='\033[0m' # No Color

#------------------------------------------------------------------------------
# Logging Functions
#------------------------------------------------------------------------------
log() {
    echo -e "${BLUE}[$(date +'%Y-%m-%d %H:%M:%S')]${NC} $*" | tee -a "$LOG_FILE"
}

log_success() {
    echo -e "${GREEN}[✓]${NC} $*" | tee -a "$LOG_FILE"
}

log_error() {
    echo -e "${RED}[✗]${NC} $*" | tee -a "$LOG_FILE" >&2
}

log_warning() {
    echo -e "${YELLOW}[!]${NC} $*" | tee -a "$LOG_FILE"
}

log_section() {
    echo -e "\n${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}" | tee -a "$LOG_FILE"
    echo -e "${BLUE}$*${NC}" | tee -a "$LOG_FILE"
    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}" | tee -a "$LOG_FILE"
}

#------------------------------------------------------------------------------
# Utility Functions
#------------------------------------------------------------------------------
command_exists() {
    command -v "$1" >/dev/null 2>&1
}

version_gt() {
    test "$(printf '%s\n' "$@" | sort -V | head -n 1)" != "$1"
}

get_os() {
    if [[ "$OSTYPE" == "linux-gnu"* ]]; then
        echo "linux"
    elif [[ "$OSTYPE" == "darwin"* ]]; then
        echo "darwin"
    else
        log_error "Unsupported operating system: $OSTYPE"
        exit 1
    fi
}

get_arch() {
    local arch
    arch="$(uname -m)"
    case "$arch" in
        x86_64)
            echo "amd64"
            ;;
        aarch64|arm64)
            echo "arm64"
            ;;
        *)
            log_error "Unsupported architecture: $arch"
            exit 1
            ;;
    esac
}

#------------------------------------------------------------------------------
# Pre-flight Checks
#------------------------------------------------------------------------------
check_prerequisites() {
    log_section "Pre-flight Checks"
    
    # Check if running as root
    if [[ $EUID -eq 0 ]]; then
        log_error "This script should not be run as root"
        exit 1
    fi
    
    # Check for sudo access
    if ! sudo -n true 2>/dev/null; then
        log "This script requires sudo privileges for some operations"
        sudo -v || {
            log_error "Failed to obtain sudo privileges"
            exit 1
        }
    fi
    
    # Check internet connectivity
    if ! ping -c 1 google.com >/dev/null 2>&1; then
        log_error "No internet connection detected"
        exit 1
    fi
    
    log_success "Pre-flight checks passed"
}

#------------------------------------------------------------------------------
# Docker Installation
#------------------------------------------------------------------------------
install_docker() {
    log_section "Docker Installation"
    
    if command_exists docker; then
        local docker_version
        docker_version=$(docker --version | grep -oP '\d+\.\d+\.\d+' | head -1)
        log "Docker already installed: $docker_version"
        
        if version_gt "$docker_version" "$MIN_DOCKER_VERSION"; then
            log_success "Docker version is sufficient"
            return 0
        else
            log_warning "Docker version $docker_version is below minimum $MIN_DOCKER_VERSION"
        fi
    fi
    
    local os
    os=$(get_os)
    
    if [[ "$os" == "linux" ]]; then
        log "Installing Docker on Linux..."
        
        # Remove old versions
        sudo apt-get remove -y docker docker-engine docker.io containerd runc 2>/dev/null || true
        
        # Install dependencies
        sudo apt-get update
        sudo apt-get install -y \
            ca-certificates \
            curl \
            gnupg \
            lsb-release
        
        # Add Docker's official GPG key
        sudo install -m 0755 -d /etc/apt/keyrings
        curl -fsSL https://download.docker.com/linux/ubuntu/gpg | \
            sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg
        sudo chmod a+r /etc/apt/keyrings/docker.gpg
        
        # Set up repository
        echo \
          "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu \
          $(lsb_release -cs) stable" | \
          sudo tee /etc/apt/sources.list.d/docker.list > /dev/null
        
        # Install Docker Engine
        sudo apt-get update
        sudo apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
        
        # Add user to docker group
        sudo usermod -aG docker "$USER"
        
        log_success "Docker installed successfully"
        log_warning "You may need to log out and back in for group changes to take effect"
    else
        log_error "Please install Docker Desktop manually from https://www.docker.com/products/docker-desktop"
        exit 1
    fi
}

#------------------------------------------------------------------------------
# kubectl Installation
#------------------------------------------------------------------------------
install_kubectl() {
    log_section "kubectl Installation"
    
    if command_exists kubectl; then
        local current_version
        current_version=$(kubectl version --client -o json | grep -oP '"gitVersion": "\K[^"]+' | head -1)
        log "kubectl already installed: $current_version"
        
        if [[ "$current_version" == "$KUBECTL_VERSION" ]]; then
            log_success "kubectl version matches requirement"
            return 0
        fi
    fi
    
    log "Installing kubectl $KUBECTL_VERSION..."
    
    local os arch
    os=$(get_os)
    arch=$(get_arch)
    
    curl -LO "https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/${os}/${arch}/kubectl"
    curl -LO "https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/${os}/${arch}/kubectl.sha256"
    
    # Verify checksum
    if ! echo "$(cat kubectl.sha256)  kubectl" | sha256sum --check --status; then
        log_error "kubectl checksum verification failed"
        rm -f kubectl kubectl.sha256
        exit 1
    fi
    
    chmod +x kubectl
    sudo mv kubectl /usr/local/bin/
    rm kubectl.sha256
    
    log_success "kubectl ${KUBECTL_VERSION} installed successfully"
}

#------------------------------------------------------------------------------
# Minikube Installation
#------------------------------------------------------------------------------
install_minikube() {
    log_section "Minikube Installation"
    
    if command_exists minikube; then
        local current_version
        current_version=$(minikube version --short)
        log "Minikube already installed: $current_version"
        
        if [[ "$current_version" == "$MINIKUBE_VERSION" ]]; then
            log_success "Minikube version matches requirement"
            return 0
        fi
    fi
    
    log "Installing Minikube $MINIKUBE_VERSION..."
    
    local os arch
    os=$(get_os)
    arch=$(get_arch)
    
    curl -LO "https://storage.googleapis.com/minikube/releases/${MINIKUBE_VERSION}/minikube-${os}-${arch}"
    sudo install "minikube-${os}-${arch}" /usr/local/bin/minikube
    rm "minikube-${os}-${arch}"
    
    log_success "Minikube ${MINIKUBE_VERSION} installed successfully"
}

#------------------------------------------------------------------------------
# Helm Installation
#------------------------------------------------------------------------------
install_helm() {
    log_section "Helm Installation"
    
    if command_exists helm; then
        local current_version
        current_version=$(helm version --short | grep -oP 'v\d+\.\d+\.\d+')
        log "Helm already installed: $current_version"
        
        if [[ "$current_version" == "$HELM_VERSION" ]]; then
            log_success "Helm version matches requirement"
            return 0
        fi
    fi
    
    log "Installing Helm $HELM_VERSION..."
    
    curl -fsSL https://get.helm.sh/helm-${HELM_VERSION}-$(get_os)-$(get_arch).tar.gz -o helm.tar.gz
    tar -zxvf helm.tar.gz
    sudo mv $(get_os)-$(get_arch)/helm /usr/local/bin/helm
    rm -rf helm.tar.gz $(get_os)-$(get_arch)
    
    log_success "Helm ${HELM_VERSION} installed successfully"
}

#------------------------------------------------------------------------------
# Kustomize Installation
#------------------------------------------------------------------------------
install_kustomize() {
    log_section "Kustomize Installation"
    
    if command_exists kustomize; then
        local current_version
        current_version=$(kustomize version --short | grep -oP 'v\d+\.\d+\.\d+')
        log "Kustomize already installed: $current_version"
        
        if [[ "$current_version" == "$KUSTOMIZE_VERSION" ]]; then
            log_success "Kustomize version matches requirement"
            return 0
        fi
    fi
    
    log "Installing Kustomize $KUSTOMIZE_VERSION..."
    
    curl -s "https://raw.githubusercontent.com/kubernetes-sigs/kustomize/master/hack/install_kustomize.sh" | bash -s -- "${KUSTOMIZE_VERSION#v}"
    sudo mv kustomize /usr/local/bin/
    
    log_success "Kustomize ${KUSTOMIZE_VERSION} installed successfully"
}

#------------------------------------------------------------------------------
# Git Configuration Check
#------------------------------------------------------------------------------
check_git() {
    log_section "Git Configuration"
    
    if ! command_exists git; then
        log "Installing Git..."
        sudo apt-get update
        sudo apt-get install -y git
    fi
    
    local git_version
    git_version=$(git --version | grep -oP '\d+\.\d+\.\d+')
    log_success "Git $git_version is available"
    
    # Check Git configuration
    if ! git config user.name >/dev/null 2>&1; then
        log_warning "Git user.name not configured"
        log "Run: git config --global user.name 'Your Name'"
    fi
    
    if ! git config user.email >/dev/null 2>&1; then
        log_warning "Git user.email not configured"
        log "Run: git config --global user.email 'your.email@example.com'"
    fi
}

#------------------------------------------------------------------------------
# Installation Summary
#------------------------------------------------------------------------------
print_summary() {
    log_section "Installation Summary"
    
    echo -e "\n${GREEN}All dependencies installed successfully!${NC}\n"
    
    echo "Installed versions:"
    echo "  • Docker:     $(docker --version | grep -oP '\d+\.\d+\.\d+' | head -1)"
    echo "  • kubectl:    $(kubectl version --client -o json | grep -oP '"gitVersion": "\K[^"]+' | head -1)"
    echo "  • Minikube:   $(minikube version --short)"
    echo "  • Helm:       $(helm version --short | grep -oP 'v\d+\.\d+\.\d+')"
    echo "  • Kustomize:  $(kustomize version --short | grep -oP 'v\d+\.\d+\.\d+')"
    echo "  • Git:        $(git --version | grep -oP '\d+\.\d+\.\d+')"
    
    echo -e "\n${YELLOW}Next steps:${NC}"
    echo "  1. If Docker was just installed, log out and back in for group changes"
    echo "  2. Start Minikube: minikube start --cpus=4 --memory=8192 --driver=docker"
    echo "  3. Follow the README.md for ArgoCD setup"
    
    echo -e "\n${BLUE}Log file saved to: ${LOG_FILE}${NC}\n"
}

#------------------------------------------------------------------------------
# Main Execution
#------------------------------------------------------------------------------
main() {
    clear
    echo -e "${BLUE}"
    cat << "EOF"
    ╔═══════════════════════════════════════════════════════════════╗
    ║                                                               ║
    ║       Anomaly Detection System - Dependency Installer        ║
    ║                                                               ║
    ╚═══════════════════════════════════════════════════════════════╝
EOF
    echo -e "${NC}"
    
    log "Installation started at $(date)"
    log "Log file: $LOG_FILE"
    
    check_prerequisites
    install_docker
    install_kubectl
    install_minikube
    install_helm
    install_kustomize
    check_git
    print_summary
    
    log "Installation completed successfully at $(date)"
}

# Trap errors
trap 'log_error "Installation failed at line $LINENO. Check $LOG_FILE for details."; exit 1' ERR

# Run main function
main "$@"