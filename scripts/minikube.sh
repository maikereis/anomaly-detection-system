#!/usr/bin/env bash

#==============================================================================
# Anomaly Detection System - Complete Setup Script
#==============================================================================
# Description: Automated setup of entire Kubernetes infrastructure
# Author: Maike
# Version: 1.0.0
#==============================================================================

set -euo pipefail

#------------------------------------------------------------------------------
# Configuration
#------------------------------------------------------------------------------
readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
readonly LOG_FILE="${SCRIPT_DIR}/setup-$(date +%Y%m%d_%H%M%S).log"

# Minikube configuration
readonly MINIKUBE_CPUS=6
readonly MINIKUBE_MEMORY=12288
readonly MINIKUBE_DRIVER=docker

# Kubernetes
readonly KUBERNETES_VERSION="v1.34.0"

# Component versions
readonly ISTIO_VERSION="1.24.0"
readonly CERT_MANAGER_VERSION="v1.16.2"
readonly KSERVE_VERSION="v0.16.0"
readonly KNATIVE_VERSION="v1.20.0"

# Colors
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly BLUE='\033[0;34m'
readonly CYAN='\033[0;36m'
readonly NC='\033[0m'

#------------------------------------------------------------------------------
# Logging Functions
#------------------------------------------------------------------------------
log() {
    echo -e "${BLUE}[$(date +'%H:%M:%S')]${NC} $*" | tee -a "$LOG_FILE"
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
    echo -e "\n${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}" | tee -a "$LOG_FILE"
    echo -e "${CYAN}$*${NC}" | tee -a "$LOG_FILE"
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}" | tee -a "$LOG_FILE"
}

spinner() {
    local pid=$1
    local delay=0.1
    local spinstr='⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏'
    while ps -p "$pid" > /dev/null 2>&1; do
        local temp=${spinstr#?}
        printf " [%c]  " "$spinstr"
        local spinstr=$temp${spinstr%"$temp"}
        sleep $delay
        printf "\b\b\b\b\b\b"
    done
    printf "    \b\b\b\b"
}

wait_for_pods() {
    local namespace=$1
    local timeout=${2:-300}
    
    log "Waiting for pods in namespace '$namespace' to be ready..."
    if kubectl wait --for=condition=ready pod --all -n "$namespace" --timeout="${timeout}s" >/dev/null 2>&1; then
        log_success "All pods ready in namespace '$namespace'"
        return 0
    else
        log_warning "Some pods may not be ready in '$namespace'"
        kubectl get pods -n "$namespace"
        return 1
    fi
}

#------------------------------------------------------------------------------
# Pre-flight Checks
#------------------------------------------------------------------------------
check_dependencies() {
    log_section "Checking Dependencies"
    
    local missing_deps=()
    
    for cmd in docker kubectl minikube helm kustomize git; do
        if ! command -v "$cmd" >/dev/null 2>&1; then
            missing_deps+=("$cmd")
        else
            log_success "$cmd: $(command -v $cmd)"
        fi
    done
    
    if [[ ${#missing_deps[@]} -gt 0 ]]; then
        log_error "Missing dependencies: ${missing_deps[*]}"
        log "Run: ./scripts/0-install-dependencies.sh"
        exit 1
    fi
    
    log_success "All dependencies available"
}

check_github_credentials() {
    log_section "Checking GitHub Configuration"
    
    # Check/create SSH key
    if [[ -f "$HOME/.ssh/argocd_rsa" ]]; then
        log_success "SSH key already exists at ~/.ssh/argocd_rsa"
    else
        log "Generating SSH key..."
        ssh-keygen -t ed25519 -C "argocd@minikube" -f "$HOME/.ssh/argocd_rsa" -N ""
        log_success "SSH key created at ~/.ssh/argocd_rsa"
        echo -e "\n${YELLOW}Public key (add to GitHub Deploy Keys):${NC}"
        cat "$HOME/.ssh/argocd_rsa.pub"
        echo ""
    fi
    
    # Get GitHub username
    if [[ -z "${GITHUB_USERNAME:-}" ]]; then
        read -p "Enter your GitHub username: " GITHUB_USERNAME
        if [[ -z "$GITHUB_USERNAME" ]]; then
            log_error "GitHub username is required"
            exit 1
        fi
    fi
    
    export GITHUB_USERNAME
    log_success "GitHub username: $GITHUB_USERNAME"
    
    # Update manifests with username
    local app_manifest="$PROJECT_ROOT/manifests/argocd/app-minikube.yaml"
    if [[ -f "$app_manifest" ]]; then
        log "Updating repository URL in manifests..."
        sed -i.bak "s|git@github.com:[^/]*/|git@github.com:${GITHUB_USERNAME}/|g" "$app_manifest"
        log_success "Manifests updated with GitHub username"
    fi
}

#------------------------------------------------------------------------------
# Minikube Setup
#------------------------------------------------------------------------------
start_minikube() {
    log_section "Starting Minikube Cluster"
    
    if minikube status >/dev/null 2>&1; then
        log_warning "Minikube is already running"
        read -p "Do you want to delete and recreate the cluster? (y/N): " -n 1 -r
        echo
        if [[ $REPLY =~ ^[Yy]$ ]]; then
            log "Deleting existing cluster..."
            minikube delete
        else
            log "Using existing cluster"
            return 0
        fi
    fi
    
    log "Starting Minikube (CPUs: $MINIKUBE_CPUS, Memory: ${MINIKUBE_MEMORY}MB)..."
    minikube start \
        --cpus="$MINIKUBE_CPUS" \
        --memory="$MINIKUBE_MEMORY" \
        --driver="$MINIKUBE_DRIVER" \
        --kubernetes-version="$KUBERNETES_VERSION"
    
    log_success "Minikube started"
    
    log "Enabling addons..."
    minikube addons enable ingress
    minikube addons enable metrics-server
    minikube addons enable dashboard
    
    log_success "Addons enabled"
}

#------------------------------------------------------------------------------
# Istio Installation
#------------------------------------------------------------------------------
install_istio() {
    log_section "Installing Istio Service Mesh"
    
    if helm list -n istio-system | grep -q istio-base; then
        log_warning "Istio already installed, skipping..."
        return 0
    fi
    
    log "Adding Istio Helm repository..."
    helm repo add istio https://istio-release.storage.googleapis.com/charts >/dev/null 2>&1 || true
    helm repo update >/dev/null 2>&1
    
    log "Installing Istio base..."
    helm install istio-base istio/base \
        -n istio-system \
        --create-namespace \
        --version "$ISTIO_VERSION" \
        --wait
    
    log "Installing istiod..."
    helm install istiod istio/istiod \
        -n istio-system \
        --version "$ISTIO_VERSION" \
        --wait
    
    log "Installing Istio ingress gateway..."
    helm install istio-ingress istio/gateway \
        -n istio-system \
        --skip-crds --disable-openapi-validation \
        --version "$ISTIO_VERSION" \
        --wait
    
    wait_for_pods istio-system
    log_success "Istio installed successfully"
}

#------------------------------------------------------------------------------
# Cert-Manager Installation
#------------------------------------------------------------------------------
install_cert_manager() {
    log_section "Installing Cert-Manager"
    
    if kubectl get namespace cert-manager >/dev/null 2>&1; then
        log_warning "Cert-manager already installed, skipping..."
        return 0
    fi
    
    log "Applying cert-manager manifests..."
    kubectl apply -f "https://github.com/cert-manager/cert-manager/releases/download/${CERT_MANAGER_VERSION}/cert-manager.yaml"
    
    wait_for_pods cert-manager
    log_success "Cert-manager installed successfully"
}

#------------------------------------------------------------------------------
# Knative Installation
#------------------------------------------------------------------------------
install_knative() {
    log_section "Installing Knative Serving"
    
    if kubectl get namespace knative-serving >/dev/null 2>&1; then
        log_warning "Knative already installed, skipping..."
        return 0
    fi
    
    log "Installing Knative CRDs..."
    kubectl apply -f "https://github.com/knative/serving/releases/download/knative-${KNATIVE_VERSION}/serving-crds.yaml"
    
    log "Installing Knative core..."
    kubectl apply -f "https://github.com/knative/serving/releases/download/knative-${KNATIVE_VERSION}/serving-core.yaml"
    
    wait_for_pods knative-serving
    log_success "Knative installed successfully"
}

#------------------------------------------------------------------------------
# KServe Installation
#------------------------------------------------------------------------------
install_kserve() {
    log_section "Installing KServe"
    
    if kubectl get namespace kserve >/dev/null 2>&1; then
        log_warning "KServe already installed, skipping..."
        return 0
    fi
    
    log "Installing KServe..."
    kubectl apply --server-side --force-conflicts -f "https://github.com/kserve/kserve/releases/download/${KSERVE_VERSION}/kserve.yaml"
    
    wait_for_pods kserve
    
    log "Verifying KServe CRDs..."
    kubectl get crd | grep kserve.io | wc -l | xargs -I {} log_success "{} KServe CRDs installed"
}

#------------------------------------------------------------------------------
# Prometheus Operator Installation
#------------------------------------------------------------------------------
install_prometheus() {
    log_section "Installing Prometheus Stack"
    
    if helm list -n monitoring | grep -q prometheus-operator; then
        log_warning "Prometheus already installed, skipping..."
        return 0
    fi
    
    log "Adding Prometheus Helm repository..."
    helm repo add prometheus-community https://prometheus-community.github.io/helm-charts >/dev/null 2>&1 || true
    helm repo update >/dev/null 2>&1
    
    log "Installing kube-prometheus-stack..."
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
    
    wait_for_pods monitoring
    
    log "Retrieving Grafana password..."
    local grafana_password
    grafana_password=$(kubectl get secret prometheus-operator-grafana -n monitoring -o jsonpath="{.data.admin-password}" | base64 -d)
    
    log_success "Prometheus installed successfully"
    echo -e "${GREEN}Grafana credentials:${NC}"
    echo -e "  User: ${YELLOW}admin${NC}"
    echo -e "  Pass: ${YELLOW}$grafana_password${NC}"
}

#------------------------------------------------------------------------------
# ArgoCD Installation
#------------------------------------------------------------------------------
install_argocd() {
    log_section "Installing ArgoCD"
    
    if kubectl get namespace argocd >/dev/null 2>&1; then
        log_warning "ArgoCD already installed, skipping..."
        return 0
    fi
    
    log "Creating ArgoCD namespace..."
    kubectl create namespace argocd
    
    log "Installing ArgoCD..."
    kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml
    
    wait_for_pods argocd
    
    log "Retrieving ArgoCD password..."
    local argocd_password
    argocd_password=$(kubectl get secret argocd-initial-admin-secret -n argocd -o jsonpath="{.data.password}" | base64 -d)
    
    log_success "ArgoCD installed successfully"
    echo -e "${GREEN}ArgoCD credentials:${NC}"
    echo -e "  User: ${YELLOW}admin${NC}"
    echo -e "  Pass: ${YELLOW}$argocd_password${NC}"
}

#------------------------------------------------------------------------------
# GitHub SSH Secret Configuration
#------------------------------------------------------------------------------
configure_github_secret() {
    log_section "Configuring GitHub SSH Secret"
    
    if kubectl get secret repo-anomaly-detection-system-ssh -n argocd >/dev/null 2>&1; then
        log_warning "Secret already exists"
        read -p "Recreate secret? (y/N): " -n 1 -r
        echo
        if [[ $REPLY =~ ^[Yy]$ ]]; then
            kubectl delete secret repo-anomaly-detection-system-ssh -n argocd
        else
            return 0
        fi
    fi
    
    # Extract repo URL from manifest
    local repo_url
    repo_url=$(grep -Po 'repoURL:\s*\K[^\s]+' "$PROJECT_ROOT/manifests/argocd/app-minikube.yaml" | head -1)
    
    log "Creating SSH secret for repository: $repo_url"
    kubectl create secret generic repo-anomaly-detection-system-ssh \
        -n argocd \
        --from-literal=type=git \
        --from-literal=url="$repo_url" \
        --from-file=sshPrivateKey="$HOME/.ssh/argocd_rsa"
    
    kubectl label secret repo-anomaly-detection-system-ssh \
        -n argocd argocd.argoproj.io/secret-type=repository
    
    log_success "GitHub SSH secret configured"
}

#------------------------------------------------------------------------------
# ArgoCD Application Deployment
#------------------------------------------------------------------------------
deploy_argocd_app() {
    log_section "Deploying ArgoCD Application"
    
    log "Applying ArgoCD manifests..."
    kubectl apply -k "$PROJECT_ROOT/manifests/argocd/"
    
    log "Waiting for application to be created..."
    sleep 5
    
    if kubectl get application ml-system-minikube -n argocd >/dev/null 2>&1; then
        log_success "Application 'ml-system-minikube' created"
        
        log "Syncing application..."
        kubectl patch application ml-system-minikube -n argocd \
            --type merge \
            -p '{"operation": {"sync": {"prune": false}}}'
        
        log "Waiting for sync to complete (this may take a few minutes)..."
        sleep 10
        
        kubectl get application ml-system-minikube -n argocd -o yaml | grep -A 5 status: || true
    else
        log_error "Failed to create ArgoCD application"
        return 1
    fi
}

#------------------------------------------------------------------------------
# Verify Deployment
#------------------------------------------------------------------------------
verify_deployment() {
    log_section "Verifying Deployment"
    
    log "Checking namespace ml-dev..."
    if kubectl get namespace ml-dev >/dev/null 2>&1; then
        log_success "Namespace ml-dev exists"
    else
        log_error "Namespace ml-dev not found"
        return 1
    fi
    
    log "Checking resources in ml-dev..."
    kubectl get all -n ml-dev
    
    echo -e "\n${CYAN}Deployment Summary:${NC}"
    echo "  • Pods:         $(kubectl get pods -n ml-dev --no-headers 2>/dev/null | wc -l)"
    echo "  • Services:     $(kubectl get svc -n ml-dev --no-headers 2>/dev/null | wc -l)"
    echo "  • Deployments:  $(kubectl get deployments -n ml-dev --no-headers 2>/dev/null | wc -l)"
    echo "  • StatefulSets: $(kubectl get statefulsets -n ml-dev --no-headers 2>/dev/null | wc -l)"
    echo "  • PVCs:         $(kubectl get pvc -n ml-dev --no-headers 2>/dev/null | wc -l)"
}

#------------------------------------------------------------------------------
# Setup Port Forwards
#------------------------------------------------------------------------------
setup_port_forwards() {
    log_section "Setting Up Port Forwards"
    
    log_warning "Run these commands in separate terminals to access services:"
    echo ""
    echo -e "${YELLOW}# ArgoCD UI${NC}"
    echo "kubectl port-forward svc/argocd-server -n argocd 8080:443"
    echo ""
    echo -e "${YELLOW}# MLflow UI${NC}"
    echo "kubectl port-forward -n ml-dev svc/mlflow 5000:5000"
    echo ""
    echo -e "${YELLOW}# MinIO Console${NC}"
    echo "kubectl port-forward -n ml-dev svc/minio-mlflow 9001:9001"
    echo ""
    echo -e "${YELLOW}# Grafana${NC}"
    echo 'kubectl port-forward -n monitoring $(kubectl get pod -n monitoring -l "app.kubernetes.io/name=grafana" -o name) 3000'
    echo ""
    echo -e "${YELLOW}# Prometheus${NC}"
    echo "kubectl port-forward -n monitoring svc/prometheus-operator-kube-prom-prometheus 9090:9090"
    echo ""
}

#------------------------------------------------------------------------------
# Main Execution
#------------------------------------------------------------------------------
main() {
    clear
    echo -e "${CYAN}"
    cat << "EOF"
    ╔═══════════════════════════════════════════════════════════════╗
    ║                                                               ║
    ║       Anomaly Detection System - Complete Setup              ║
    ║                                                               ║
    ╚═══════════════════════════════════════════════════════════════╝
EOF
    echo -e "${NC}"
    
    log "Setup started at $(date)"
    log "Log file: $LOG_FILE"
    
    check_dependencies
    check_github_credentials
    start_minikube
    install_istio
    install_cert_manager
    install_knative
    install_kserve
    install_prometheus
    install_argocd
    configure_github_secret
    deploy_argocd_app
    
    sleep 15  # Give time for initial sync
    verify_deployment
    setup_port_forwards
    
    log_section "Setup Complete!"
    log_success "All components installed successfully"
    echo -e "\n${GREEN}Access URLs:${NC}"
    echo "  • ArgoCD:    https://localhost:8080"
    echo "  • MLflow:    http://localhost:5000"
    echo "  • MinIO:     http://localhost:9001"
    echo "  • Grafana:   http://localhost:3000"
    echo "  • Prometheus: http://localhost:9090"
    
    echo -e "\n${YELLOW}Next steps:${NC}"
    echo "  1. Set up port forwards (see commands above)"
    echo "  2. Access ArgoCD UI and sync the application if needed"
    echo "  3. Check application status: kubectl get all -n ml-dev"
    echo "  4. View logs: kubectl logs -n ml-dev -l app=mlflow"
    
    echo -e "\n${BLUE}Log file: ${LOG_FILE}${NC}\n"
}

trap 'log_error "Setup failed at line $LINENO. Check $LOG_FILE"; exit 1' ERR

main "$@"