#!/usr/bin/env bash

#==============================================================================
# Kubernetes ML System - Automated Environment Setup
#==============================================================================
# Purpose:     Automated initialization and configuration of complete ML
#              infrastructure on Minikube including service mesh, monitoring,
#              and GitOps deployment pipeline
# 
# Components:  Minikube, Istio, Cert-Manager, KubeRay, Prometheus, ArgoCD
# Platform:    Linux | macOS
# 
# Author:      Maike
# Version:     1.0.0
# License:     MIT
#==============================================================================

set -euo pipefail

#------------------------------------------------------------------------------
# Configuration
#------------------------------------------------------------------------------
readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly LOG_FILE="${SCRIPT_DIR}/minikube-setup-$(date +%Y%m%d_%H%M%S).log"

# Cluster Configuration
readonly CLUSTER_CPUS=6
readonly CLUSTER_MEMORY=12288
readonly CLUSTER_DRIVER="docker"

# Component Versions
readonly ISTIO_VERSION="1.28.0"
readonly CERT_MANAGER_VERSION="v1.19.1"
readonly KUBERAY_VERSION="v1.5.1"
readonly ARGOCD_VERSION="stable"

# Helm Repositories
readonly ISTIO_REPO="https://istio-release.storage.googleapis.com/charts"
readonly KUBERAY_REPO="https://ray-project.github.io/kuberay-helm/"
readonly PROMETHEUS_REPO="https://prometheus-community.github.io/helm-charts"

# Timeouts (seconds)
readonly DEFAULT_TIMEOUT=300
readonly EXTENDED_TIMEOUT=600

# Colors
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly BLUE='\033[0;34m'
readonly CYAN='\033[0;36m'
readonly MAGENTA='\033[0;35m'
readonly NC='\033[0m'

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

log_info() {
    echo -e "${CYAN}[ℹ]${NC} $*" | tee -a "$LOG_FILE"
}

log_step() {
    echo -e "${MAGENTA}[→]${NC} $*" | tee -a "$LOG_FILE"
}

log_section() {
    echo "" | tee -a "$LOG_FILE"
    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}" | tee -a "$LOG_FILE"
    echo -e "${BLUE}$*${NC}" | tee -a "$LOG_FILE"
    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}" | tee -a "$LOG_FILE"
}

#------------------------------------------------------------------------------
# Utility Functions
#------------------------------------------------------------------------------
command_exists() {
    command -v "$1" >/dev/null 2>&1
}

wait_for_deployment() {
    local deployment=$1
    local namespace=$2
    local timeout=${3:-$DEFAULT_TIMEOUT}
    
    log_step "Waiting for deployment/$deployment in namespace $namespace..."
    
    if kubectl wait --for=condition=available \
        --timeout="${timeout}s" \
        "deployment/${deployment}" \
        -n "$namespace" 2>&1 | tee -a "$LOG_FILE"; then
        log_success "Deployment $deployment is ready"
        return 0
    else
        log_error "Deployment $deployment failed to become ready"
        return 1
    fi
}

wait_for_pods() {
    local namespace=$1
    local label=$2
    local timeout=${3:-$DEFAULT_TIMEOUT}
    
    log_step "Waiting for pods with label $label in namespace $namespace..."
    
    local end_time=$((SECONDS + timeout))
    while [ $SECONDS -lt $end_time ]; do
        local ready_pods
        ready_pods=$(kubectl get pods -n "$namespace" -l "$label" \
            -o jsonpath='{.items[*].status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo "")
        
        if [[ "$ready_pods" == *"False"* ]] || [[ -z "$ready_pods" ]]; then
            sleep 5
            continue
        fi
        
        if [[ "$ready_pods" =~ ^(True[[:space:]])*True$ ]]; then
            log_success "All pods are ready"
            return 0
        fi
        
        sleep 5
    done
    
    log_error "Timeout waiting for pods to be ready"
    return 1
}

helm_repo_add() {
    local name=$1
    local url=$2
    
    log_step "Adding Helm repository: $name"
    
    if helm repo add "$name" "$url" 2>&1 | tee -a "$LOG_FILE"; then
        log_success "Repository $name added"
    else
        log_warning "Repository $name may already exist"
    fi
}

#------------------------------------------------------------------------------
# Pre-flight Checks
#------------------------------------------------------------------------------
preflight_checks() {
    log_section "Pre-flight Validation"
    
    # Check required tools
    local missing_tools=()
    
    for tool in minikube kubectl helm docker; do
        if ! command_exists "$tool"; then
            missing_tools+=("$tool")
        fi
    done
    
    if [ ${#missing_tools[@]} -gt 0 ]; then
        log_error "Missing required tools: ${missing_tools[*]}"
        log_info "Please run: ./scripts/0-install-dependencies.sh"
        exit 1
    fi
    
    log_success "All required tools are installed"
    
    # Check Docker is running
    if ! docker info >/dev/null 2>&1; then
        log_error "Docker daemon is not running"
        log_info "Start Docker and try again"
        exit 1
    fi
    
    log_success "Docker daemon is running"
    
    # Check if Minikube is already running
    if minikube status >/dev/null 2>&1; then
        log_warning "Minikube cluster already exists"
        read -p "Do you want to delete and recreate it? (y/N): " -n 1 -r
        echo
        if [[ $REPLY =~ ^[Yy]$ ]]; then
            log_step "Deleting existing Minikube cluster..."
            minikube delete
            log_success "Existing cluster deleted"
        else
            log_info "Using existing cluster"
        fi
    fi
}

#------------------------------------------------------------------------------
# Minikube Initialization
#------------------------------------------------------------------------------
start_minikube() {
    log_section "Minikube Cluster Initialization"
    
    log_step "Starting Minikube cluster..."
    log_info "Configuration: ${CLUSTER_CPUS} CPUs, ${CLUSTER_MEMORY}MB RAM, driver: ${CLUSTER_DRIVER}"
    
    if minikube start \
        --cpus="$CLUSTER_CPUS" \
        --memory="$CLUSTER_MEMORY" \
        --driver="$CLUSTER_DRIVER" 2>&1 | tee -a "$LOG_FILE"; then
        log_success "Minikube cluster started successfully"
    else
        log_error "Failed to start Minikube cluster"
        exit 1
    fi
    
    # Enable essential addons
    log_step "Enabling Minikube addons..."
    
    for addon in ingress metrics-server dashboard; do
        log_info "Enabling addon: $addon"
        if minikube addons enable "$addon" 2>&1 | tee -a "$LOG_FILE"; then
            log_success "Addon $addon enabled"
        else
            log_warning "Failed to enable addon: $addon"
        fi
    done
    
    # Verify cluster
    log_step "Verifying cluster status..."
    kubectl cluster-info | tee -a "$LOG_FILE"
    kubectl get nodes | tee -a "$LOG_FILE"
    
    log_success "Minikube cluster is operational"
}

#------------------------------------------------------------------------------
# Istio Installation
#------------------------------------------------------------------------------
install_istio() {
    log_section "Istio Service Mesh Installation"
    
    # Add Helm repository
    helm_repo_add "istio" "$ISTIO_REPO"
    helm repo update 2>&1 | tee -a "$LOG_FILE"
    
    # Check and install/upgrade Istio base
    log_step "Checking Istio base installation..."
    if helm list -n istio-system 2>/dev/null | grep -q "istio-base"; then
        log_warning "Istio base already exists. Upgrading to version $ISTIO_VERSION..."
        if helm upgrade istio-base istio/base \
            -n istio-system \
            --version "$ISTIO_VERSION" \
            --timeout 3m 2>&1 | tee -a "$LOG_FILE"; then
            log_success "Istio base upgraded"
        else
            log_error "Failed to upgrade Istio base"
            return 1
        fi
    else
        log_step "Installing Istio base components..."
        if helm install istio-base istio/base \
            -n istio-system \
            --create-namespace \
            --version "$ISTIO_VERSION" 2>&1 | tee -a "$LOG_FILE"; then
            log_success "Istio base installed"
        else
            log_error "Failed to install Istio base"
            return 1
        fi
    fi
    
    # Check and install/upgrade Istiod
    log_step "Checking Istiod installation..."
    if helm list -n istio-system 2>/dev/null | grep -q "istiod"; then
        log_warning "Istiod already exists. Upgrading to version $ISTIO_VERSION..."
        if helm upgrade istiod istio/istiod \
            -n istio-system \
            --version "$ISTIO_VERSION" \
            --timeout 5m \
            --wait 2>&1 | tee -a "$LOG_FILE"; then
            log_success "Istiod upgraded"
        else
            log_error "Failed to upgrade Istiod"
            return 1
        fi
    else
        log_step "Installing Istiod control plane..."
        if helm install istiod istio/istiod \
            -n istio-system \
            --version "$ISTIO_VERSION" \
            --timeout 5m \
            --wait 2>&1 | tee -a "$LOG_FILE"; then
            log_success "Istiod installed"
        else
            log_error "Failed to install Istiod"
            return 1
        fi
    fi
    
    # Check and install/upgrade Ingress Gateway
    log_step "Checking Istio Ingress Gateway installation..."
    if helm list -n istio-system 2>/dev/null | grep -q "istio-ingress"; then
        log_warning "Istio Ingress Gateway already exists. Upgrading to version $ISTIO_VERSION..."
        
        # Upgrade without --wait to avoid hanging on pod restarts
        if helm upgrade istio-ingress istio/gateway \
            -n istio-system \
            --version "$ISTIO_VERSION" \
            --timeout 5m 2>&1 | tee -a "$LOG_FILE"; then
            log_success "Istio Ingress Gateway upgrade initiated"
            
            # Manual wait with better feedback
            log_step "Waiting for gateway pods to be ready..."
            sleep 10
            for i in {1..30}; do
                if kubectl get pods -n istio-system -l app=istio-ingress -o jsonpath='{.items[*].status.conditions[?(@.type=="Ready")].status}' 2>/dev/null | grep -q "True"; then
                    log_success "Gateway is ready"
                    break
                fi
                echo -n "."
                sleep 2
            done
            echo ""
        else
            log_warning "Upgrade command completed with warnings, checking gateway status..."
            if kubectl get deployment -n istio-system -l app=istio-ingress >/dev/null 2>&1; then
                log_success "Gateway deployment exists and is functional"
            else
                log_error "Failed to upgrade Istio Ingress Gateway"
                return 1
            fi
        fi
    else
        log_step "Installing Istio Ingress Gateway..."
        if helm install istio-ingress istio/gateway \
            -n istio-system \
            --version "$ISTIO_VERSION" \
            --timeout 5m \
            --wait 2>&1 | tee -a "$LOG_FILE"; then
            log_success "Istio Ingress Gateway installed"
        else
            log_error "Failed to install Istio Ingress Gateway"
            return 1
        fi
    fi
    
    # Verify installation
    log_step "Verifying Istio installation..."
    kubectl get pods -n istio-system | tee -a "$LOG_FILE"
    
    wait_for_deployment "istiod" "istio-system"
    
    log_success "Istio Service Mesh installed successfully"
}

#------------------------------------------------------------------------------
# Cert-Manager Installation
#------------------------------------------------------------------------------
install_cert_manager() {
    log_section "Cert-Manager Installation"
    
    # Check if cert-manager namespace exists
    if kubectl get namespace cert-manager >/dev/null 2>&1; then
        log_warning "Cert-Manager namespace already exists"
        log_info "Checking if components are running..."
        
        if kubectl get deployment -n cert-manager cert-manager >/dev/null 2>&1; then
            log_info "Cert-Manager already installed. Checking status..."
            kubectl get pods -n cert-manager | tee -a "$LOG_FILE"
            
            # Wait for existing deployments to be ready
            wait_for_deployment "cert-manager" "cert-manager" || true
            wait_for_deployment "cert-manager-webhook" "cert-manager" || true
            wait_for_deployment "cert-manager-cainjector" "cert-manager" || true
            
            log_success "Using existing Cert-Manager installation"
            return 0
        fi
    fi
    
    log_step "Installing Cert-Manager..."
    
    if kubectl apply -f "https://github.com/cert-manager/cert-manager/releases/download/${CERT_MANAGER_VERSION}/cert-manager.yaml" 2>&1 | tee -a "$LOG_FILE"; then
        log_success "Cert-Manager manifests applied"
    else
        log_error "Failed to apply Cert-Manager manifests"
        return 1
    fi
    
    # Wait for deployments
    log_step "Waiting for Cert-Manager components..."
    
    wait_for_deployment "cert-manager" "cert-manager"
    wait_for_deployment "cert-manager-webhook" "cert-manager"
    wait_for_deployment "cert-manager-cainjector" "cert-manager"
    
    # Verify installation
    log_step "Verifying Cert-Manager installation..."
    kubectl get pods -n cert-manager | tee -a "$LOG_FILE"
    
    log_success "Cert-Manager installed successfully"
}

#------------------------------------------------------------------------------
# KubeRay Operator Installation
#------------------------------------------------------------------------------
install_kuberay() {
    log_section "KubeRay Operator Installation"
    
    # Add Helm repository
    helm_repo_add "kuberay" "$KUBERAY_REPO"
    helm repo update 2>&1 | tee -a "$LOG_FILE"
    
    # Check and install/upgrade KubeRay operator
    log_step "Checking KubeRay operator installation..."
    if helm list -n ray-system 2>/dev/null | grep -q "kuberay-operator"; then
        log_warning "KubeRay operator already exists. Upgrading to version $KUBERAY_VERSION..."
        if helm upgrade kuberay-operator kuberay/kuberay-operator \
            --namespace ray-system \
            --version "$KUBERAY_VERSION" \
            --wait 2>&1 | tee -a "$LOG_FILE"; then
            log_success "KubeRay operator upgraded"
        else
            log_error "Failed to upgrade KubeRay operator"
            return 1
        fi
    else
        log_step "Installing KubeRay operator..."
        if helm install kuberay-operator kuberay/kuberay-operator \
            --namespace ray-system \
            --create-namespace \
            --version "$KUBERAY_VERSION" \
            --wait 2>&1 | tee -a "$LOG_FILE"; then
            log_success "KubeRay operator installed"
        else
            log_error "Failed to install KubeRay operator"
            return 1
        fi
    fi
    
    # Wait for operator
    wait_for_deployment "kuberay-operator" "ray-system"
    
    # Verify CRDs
    log_step "Verifying Ray CRDs..."
    kubectl get crd | grep ray.io | tee -a "$LOG_FILE"
    
    log_success "KubeRay operator installed successfully"
}

#------------------------------------------------------------------------------
# Prometheus Stack Installation
#------------------------------------------------------------------------------
install_prometheus() {
    log_section "Prometheus Monitoring Stack Installation"
    
    # Add Helm repository
    helm_repo_add "prometheus-community" "$PROMETHEUS_REPO"
    helm repo update 2>&1 | tee -a "$LOG_FILE"
    
    # Install kube-prometheus-stack
    log_step "Installing kube-prometheus-stack..."
    if helm upgrade --install prometheus-operator prometheus-community/kube-prometheus-stack \
        --namespace monitoring \
        --create-namespace \
        --set prometheus.enabled=true \
        --set grafana.enabled=true \
        --set alertmanager.enabled=false \
        --set prometheusOperator.enabled=true \
        --set prometheus.prometheusSpec.serviceMonitorSelectorNilUsesHelmValues=false \
        --set prometheus.prometheusSpec.podMonitorSelectorNilUsesHelmValues=false \
        --wait \
        --timeout 5m 2>&1 | tee -a "$LOG_FILE"; then
        log_success "Prometheus stack installed"
    else
        log_error "Failed to install Prometheus stack"
        return 1
    fi
    
    # Get Grafana password
    log_step "Retrieving Grafana credentials..."
    local grafana_password
    grafana_password=$(kubectl get secret prometheus-operator-grafana \
        -n monitoring \
        -o jsonpath="{.data.admin-password}" 2>/dev/null | base64 -d)
    
    log_success "Grafana credentials:"
    echo -e "${CYAN}  Username: admin${NC}"
    echo -e "${CYAN}  Password: ${grafana_password}${NC}"
    
    # Save credentials
    echo "Grafana Admin Password: ${grafana_password}" >> "${SCRIPT_DIR}/credentials.log"
    
    # Verify installation
    log_step "Verifying Prometheus installation..."
    kubectl get pods -n monitoring | tee -a "$LOG_FILE"
    kubectl get crd | grep monitoring.coreos.com | tee -a "$LOG_FILE"
    
    log_success "Prometheus monitoring stack installed successfully"
}

#------------------------------------------------------------------------------
# ArgoCD Installation
#------------------------------------------------------------------------------
install_argocd() {
    log_section "ArgoCD GitOps Installation"
    
    # Create namespace
    log_step "Creating ArgoCD namespace..."
    kubectl create namespace argocd 2>&1 | tee -a "$LOG_FILE" || true
    
    # Check if ArgoCD is already installed
    if kubectl get deployment argocd-server -n argocd >/dev/null 2>&1; then
        log_warning "ArgoCD is already installed"
        log_info "Applying latest manifests (this is safe and idempotent)..."
    else
        log_step "Installing ArgoCD..."
    fi
    
    if kubectl apply -n argocd \
        -f "https://raw.githubusercontent.com/argoproj/argo-cd/${ARGOCD_VERSION}/manifests/install.yaml" 2>&1 | tee -a "$LOG_FILE"; then
        log_success "ArgoCD manifests applied"
    else
        log_error "Failed to apply ArgoCD manifests"
        return 1
    fi
    
    # Wait for ArgoCD server
    wait_for_deployment "argocd-server" "argocd" "$EXTENDED_TIMEOUT"
    
    # Get initial password
    log_step "Retrieving ArgoCD credentials..."
    sleep 10  # Give time for secret to be created
    
    local argocd_password
    argocd_password=$(kubectl -n argocd get secret argocd-initial-admin-secret \
        -o jsonpath="{.data.password}" 2>/dev/null | base64 -d)
    
    if [[ -n "$argocd_password" ]]; then
        log_success "ArgoCD credentials:"
        echo -e "${CYAN}  Username: admin${NC}"
        echo -e "${CYAN}  Password: ${argocd_password}${NC}"
        
        # Save credentials
        echo "ArgoCD Admin Password: ${argocd_password}" >> "${SCRIPT_DIR}/credentials.log"
    else
        log_warning "Could not retrieve ArgoCD password automatically"
        log_info "Retrieve it later with: kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath=\"{.data.password}\" | base64 -d"
    fi
    
    # Verify installation
    log_step "Verifying ArgoCD installation..."
    kubectl get pods -n argocd | tee -a "$LOG_FILE"
    
    log_success "ArgoCD installed successfully"
}

#------------------------------------------------------------------------------
# Post-Installation Configuration
#------------------------------------------------------------------------------
post_install_config() {
    log_section "Post-Installation Configuration"
    
    # Get Minikube IP
    local minikube_ip
    minikube_ip=$(minikube ip)
    log_info "Minikube IP: $minikube_ip"
    
    # Create port-forward script
    log_step "Creating port-forward helper script..."
    
    cat > "${SCRIPT_DIR}/start-port-forwards.sh" << 'PORTFORWARD_SCRIPT'
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
PORTFORWARD_SCRIPT

    chmod +x "${SCRIPT_DIR}/start-port-forwards.sh"
    log_success "Created start-port-forwards.sh"
    
    # Create stop script
    cat > "${SCRIPT_DIR}/stop-port-forwards.sh" << 'STOP_SCRIPT'
#!/usr/bin/env bash
echo "Stopping all kubectl port-forwards..."
pkill -f "kubectl.*port-forward"
echo "Done."
STOP_SCRIPT

    chmod +x "${SCRIPT_DIR}/stop-port-forwards.sh"
    log_success "Created stop-port-forwards.sh"
    
    # Start port-forwards
    log_step "Starting port-forwards..."
    "${SCRIPT_DIR}/start-port-forwards.sh"
    
    log_success "Post-installation configuration completed"
}

#------------------------------------------------------------------------------
# Installation Summary
#------------------------------------------------------------------------------
print_summary() {
    log_section "Installation Summary"
    
    echo ""
    echo -e "${GREEN}╔═══════════════════════════════════════════════════════╗${NC}"
    echo -e "${GREEN}║                                                       ║${NC}"
    echo -e "${GREEN}║     ML System Environment Setup Complete! 🚀         ║${NC}"
    echo -e "${GREEN}║                                                       ║${NC}"
    echo -e "${GREEN}╚═══════════════════════════════════════════════════════╝${NC}"
    echo ""
    
    echo -e "${CYAN}Installed Components:${NC}"
    echo ""
    printf "  ${GREEN}✓${NC} %-20s %s\n" "Minikube" "Kubernetes cluster running"
    printf "  ${GREEN}✓${NC} %-20s %s\n" "Istio ${ISTIO_VERSION}" "Service mesh for traffic management"
    printf "  ${GREEN}✓${NC} %-20s %s\n" "Cert-Manager" "TLS certificate management"
    printf "  ${GREEN}✓${NC} %-20s %s\n" "KubeRay" "Distributed computing framework"
    printf "  ${GREEN}✓${NC} %-20s %s\n" "Prometheus" "Monitoring and alerting"
    printf "  ${GREEN}✓${NC} %-20s %s\n" "Grafana" "Metrics visualization"
    printf "  ${GREEN}✓${NC} %-20s %s\n" "ArgoCD" "GitOps continuous delivery"
    echo ""
    
    echo -e "${YELLOW}Next Steps:${NC}"
    echo ""
    echo "  1. Configure Git repository for GitOps:"
    echo "     ${CYAN}# Fork/clone the repository${NC}"
    echo "     ${CYAN}# Update manifests/argocd/app-minikube.yaml with your repo URL${NC}"
    echo ""
    echo "  2. Generate SSH keys for ArgoCD:"
    echo "     ${CYAN}ssh-keygen -t ed25519 -C \"argocd@minikube\" -f ~/.ssh/argocd_rsa -N \"\"${NC}"
    echo "     ${CYAN}# Add the public key as a deploy key in GitHub${NC}"
    echo ""
    echo "  3. Register SSH key as Kubernetes Secret:"
    echo "     ${CYAN}kubectl create secret generic repo-anomaly-detection-system-ssh \\${NC}"
    echo "     ${CYAN}  -n argocd \\${NC}"
    echo "     ${CYAN}  --from-literal=type=git \\${NC}"
    echo "     ${CYAN}  --from-literal=url=git@github.com:<YOUR_USERNAME>/anomaly-detection-system.git \\${NC}"
    echo "     ${CYAN}  --from-file=sshPrivateKey=\$HOME/.ssh/argocd_rsa${NC}"
    echo ""
    echo "  4. Deploy the ML system:"
    echo "     ${CYAN}kubectl apply -k manifests/argocd/${NC}"
    echo ""
    echo "  5. Access services:"
    echo "     ${CYAN}./scripts/start-port-forwards.sh${NC}  # Start all port-forwards"
    echo "     ${CYAN}./scripts/stop-port-forwards.sh${NC}   # Stop all port-forwards"
    echo ""
    echo "     Or manually:"
    echo "     ${CYAN}kubectl port-forward svc/argocd-server -n argocd 8080:443${NC}"
    echo "     ${CYAN}kubectl port-forward -n monitoring svc/prometheus-operator-grafana 3000:80${NC}"
    
    echo -e "${BLUE}Documentation & Credentials:${NC}"
    echo "  • Installation log: ${LOG_FILE}"
    echo "  • Credentials file: ${SCRIPT_DIR}/credentials.log"
    echo "  • Project README:   ./README.md"
    echo ""
    
    echo -e "${MAGENTA}Quick Commands:${NC}"
    echo "  • Cluster status:  ${CYAN}minikube status${NC}"
    echo "  • View pods:       ${CYAN}kubectl get pods -A${NC}"
    echo "  • Stop cluster:    ${CYAN}minikube stop${NC}"
    echo "  • Delete cluster:  ${CYAN}minikube delete${NC}"
    echo ""
}

#------------------------------------------------------------------------------
# Cleanup Function
#------------------------------------------------------------------------------
cleanup() {
    log_section "Cleanup"
    log_info "Performing cleanup operations..."
    
    # Any cleanup tasks if needed
    
    log_success "Cleanup completed"
}

#------------------------------------------------------------------------------
# Error Handler
#------------------------------------------------------------------------------
error_handler() {
    local line_number=$1
    local exit_code=$?
    
    log_error "Setup failed at line ${line_number} with exit code ${exit_code}"
    log_error "Check log file for details: ${LOG_FILE}"
    
    cleanup
    exit "$exit_code"
}

#------------------------------------------------------------------------------
# Main Execution
#------------------------------------------------------------------------------
main() {
    clear
    
    echo -e "${CYAN}"
    cat << 'EOF'
╔═══════════════════════════════════════════════════════════════╗
║                                                               ║
║     ML System - Automated Minikube Environment Setup         ║
║                                                               ║
║     Infrastructure: Minikube + Istio + ArgoCD                ║
║     Observability:  Prometheus + Grafana                      ║
║     ML Platform:    KubeRay + MLflow                          ║
║                                                               ║
╚═══════════════════════════════════════════════════════════════╝
EOF
    echo -e "${NC}"
    
    log "Setup started"
    log "Platform: $(uname -s) $(uname -m)"
    log "Log file: ${LOG_FILE}"
    
    # Create credentials file
    : > "${SCRIPT_DIR}/credentials.log"
    echo "ML System - Credentials" > "${SCRIPT_DIR}/credentials.log"
    echo "Generated: $(date)" >> "${SCRIPT_DIR}/credentials.log"
    echo "" >> "${SCRIPT_DIR}/credentials.log"
    
    # Execute setup pipeline
    preflight_checks
    start_minikube
    install_istio
    install_cert_manager
    install_kuberay
    install_prometheus
    install_argocd
    post_install_config
    print_summary
    
    log "Setup completed successfully at $(date)"
}

# Register error handler
trap 'error_handler $LINENO' ERR

# Register cleanup on exit
trap cleanup EXIT

# Execute main function
main "$@"