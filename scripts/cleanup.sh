#!/usr/bin/env bash

#==============================================================================
# Anomaly Detection System - Cleanup Script
#==============================================================================
# Description: Remove all components and reset environment
# Author: Maike
# Version: 1.0.0
#==============================================================================

set -euo pipefail

#------------------------------------------------------------------------------
# Configuration
#------------------------------------------------------------------------------
readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
readonly LOG_FILE="${SCRIPT_DIR}/cleanup-$(date +%Y%m%d_%H%M%S).log"

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

#------------------------------------------------------------------------------
# Confirmation
#------------------------------------------------------------------------------
confirm_cleanup() {
    clear
    echo -e "${RED}"
    cat << "EOF"
    ╔═══════════════════════════════════════════════════════════════╗
    ║                                                               ║
    ║                  ⚠️  CLEANUP WARNING  ⚠️                      ║
    ║                                                               ║
    ╚═══════════════════════════════════════════════════════════════╝
EOF
    echo -e "${NC}"
    
    echo -e "${YELLOW}This script will:${NC}"
    echo "  • Delete the entire Minikube cluster"
    echo "  • Remove all deployed applications"
    echo "  • Clean up Docker resources"
    echo "  • Delete persistent volumes and data"
    echo ""
    echo -e "${RED}⚠️  ALL DATA WILL BE LOST${NC}"
    echo ""
    
    read -p "Are you sure you want to continue? (yes/NO): " -r
    if [[ ! $REPLY =~ ^[Yy][Ee][Ss]$ ]]; then
        log "Cleanup cancelled by user"
        exit 0
    fi
    
    echo ""
    read -p "Type 'DELETE' to confirm: " -r
    if [[ $REPLY != "DELETE" ]]; then
        log "Cleanup cancelled - confirmation failed"
        exit 0
    fi
}

#------------------------------------------------------------------------------
# Cleanup Functions
#------------------------------------------------------------------------------
stop_port_forwards() {
    log_section "Stopping Port Forwards"
    
    local pf_pids
    pf_pids=$(pgrep -f "kubectl port-forward" || true)
    
    if [[ -n "$pf_pids" ]]; then
        log "Killing port-forward processes..."
        echo "$pf_pids" | xargs -r kill -9 2>/dev/null || true
        log_success "Port forwards stopped"
    else
        log "No active port forwards found"
    fi
}

cleanup_argocd_apps() {
    log_section "Cleaning ArgoCD Applications"
    
    if ! kubectl get namespace argocd >/dev/null 2>&1; then
        log "ArgoCD not installed, skipping..."
        return 0
    fi
    
    local apps
    apps=$(kubectl get applications -n argocd -o name 2>/dev/null || echo "")
    
    if [[ -n "$apps" ]]; then
        log "Deleting ArgoCD applications..."
        echo "$apps" | xargs -r kubectl delete -n argocd --cascade=foreground --timeout=60s || true
        log_success "ArgoCD applications deleted"
    else
        log "No ArgoCD applications found"
    fi
}

cleanup_namespaces() {
    log_section "Cleaning Namespaces"
    
    local namespaces=("ml-dev" "monitoring" "argocd" "istio-system" "kserve" "knative-serving" "cert-manager")
    
    for ns in "${namespaces[@]}"; do
        if kubectl get namespace "$ns" >/dev/null 2>&1; then
            log "Deleting namespace: $ns"
            kubectl delete namespace "$ns" --timeout=60s || {
                log_warning "Force deleting namespace: $ns"
                kubectl delete namespace "$ns" --grace-period=0 --force || true
            }
            log_success "Namespace $ns deleted"
        else
            log "Namespace $ns not found"
        fi
    done
}

cleanup_helm_releases() {
    log_section "Cleaning Helm Releases"
    
    local releases
    releases=$(helm list --all-namespaces -q 2>/dev/null || echo "")
    
    if [[ -n "$releases" ]]; then
        log "Found Helm releases:"
        echo "$releases"
        
        while IFS= read -r release; do
            local namespace
            namespace=$(helm list --all-namespaces | grep "$release" | awk '{print $2}')
            log "Uninstalling $release from $namespace..."
            helm uninstall "$release" -n "$namespace" --wait --timeout 60s || true
        done <<< "$releases"
        
        log_success "Helm releases cleaned"
    else
        log "No Helm releases found"
    fi
}

cleanup_crds() {
    log_section "Cleaning Custom Resource Definitions"
    
    local crd_patterns=("kserve.io" "knative.dev" "istio.io" "cert-manager.io" "monitoring.coreos.com")
    
    for pattern in "${crd_patterns[@]}"; do
        local crds
        crds=$(kubectl get crd -o name 2>/dev/null | grep "$pattern" || echo "")
        
        if [[ -n "$crds" ]]; then
            log "Deleting CRDs matching: $pattern"
            echo "$crds" | xargs -r kubectl delete --timeout=30s || true
        fi
    done
    
    log_success "CRDs cleaned"
}

delete_minikube_cluster() {
    log_section "Deleting Minikube Cluster"
    
    if minikube status >/dev/null 2>&1; then
        log "Stopping and deleting Minikube cluster..."
        minikube delete --purge
        log_success "Minikube cluster deleted"
    else
        log "Minikube cluster not running"
    fi
}

cleanup_docker() {
    log_section "Cleaning Docker Resources"
    
    log "Pruning Docker volumes..."
    docker volume prune -f || true
    
    log "Pruning Docker networks..."
    docker network prune -f || true
    
    log "Removing unused images..."
    docker image prune -a -f || true
    
    log_success "Docker resources cleaned"
}

cleanup_ssh_keys() {
    log_section "SSH Keys"
    
    if [[ -f "$HOME/.ssh/argocd_rsa" ]]; then
        read -p "Delete SSH keys (~/.ssh/argocd_rsa*)? (y/N): " -n 1 -r
        echo
        if [[ $REPLY =~ ^[Yy]$ ]]; then
            rm -f "$HOME/.ssh/argocd_rsa" "$HOME/.ssh/argocd_rsa.pub"
            log_success "SSH keys deleted"
        else
            log "SSH keys preserved"
        fi
    else
        log "No SSH keys found"
    fi
}

cleanup_manifest_backups() {
    log_section "Cleaning Manifest Backups"
    
    local backups
    backups=$(find "$PROJECT_ROOT/manifests" -name "*.bak" 2>/dev/null || echo "")
    
    if [[ -n "$backups" ]]; then
        log "Found backup files:"
        echo "$backups"
        
        read -p "Delete manifest backups? (y/N): " -n 1 -r
        echo
        if [[ $REPLY =~ ^[Yy]$ ]]; then
            echo "$backups" | xargs -r rm -f
            log_success "Backup files deleted"
        else
            log "Backup files preserved"
        fi
    else
        log "No backup files found"
    fi
}

reset_manifests() {
    log_section "Resetting Manifests"
    
    local app_manifest="$PROJECT_ROOT/manifests/argocd/app-minikube.yaml"
    
    if [[ -f "${app_manifest}.bak" ]]; then
        read -p "Restore original manifests from backup? (y/N): " -n 1 -r
        echo
        if [[ $REPLY =~ ^[Yy]$ ]]; then
            mv "${app_manifest}.bak" "$app_manifest"
            log_success "Manifests restored from backup"
        fi
    fi
}

cleanup_logs() {
    log_section "Cleaning Log Files"
    
    local log_files
    log_files=$(find "$SCRIPT_DIR" -name "*.log" -type f 2>/dev/null | grep -v "$(basename "$LOG_FILE")" || echo "")
    
    if [[ -n "$log_files" ]]; then
        local count
        count=$(echo "$log_files" | wc -l)
        log "Found $count old log files"
        
        read -p "Delete old log files? (y/N): " -n 1 -r
        echo
        if [[ $REPLY =~ ^[Yy]$ ]]; then
            echo "$log_files" | xargs -r rm -f
            log_success "Log files deleted"
        else
            log "Log files preserved"
        fi
    else
        log "No old log files found"
    fi
}

#------------------------------------------------------------------------------
# Verification
#------------------------------------------------------------------------------
verify_cleanup() {
    log_section "Verifying Cleanup"
    
    local issues=()
    
    if minikube status >/dev/null 2>&1; then
        issues+=("Minikube cluster still running")
    fi
    
    if docker ps --filter "name=minikube" --format "{{.Names}}" 2>/dev/null | grep -q minikube; then
        issues+=("Minikube Docker containers found")
    fi
    
    if helm list --all-namespaces -q 2>/dev/null | grep -q .; then
        issues+=("Helm releases still present")
    fi
    
    if [[ ${#issues[@]} -gt 0 ]]; then
        log_warning "Cleanup verification found issues:"
        for issue in "${issues[@]}"; do
            echo "  • $issue"
        done
        return 1
    else
        log_success "Cleanup verified - environment clean"
        return 0
    fi
}

#------------------------------------------------------------------------------
# Main Execution
#------------------------------------------------------------------------------
main() {
    log "Cleanup started at $(date)"
    log "Log file: $LOG_FILE"
    
    confirm_cleanup
    
    stop_port_forwards
    cleanup_argocd_apps
    cleanup_helm_releases
    cleanup_namespaces
    cleanup_crds
    delete_minikube_cluster
    cleanup_docker
    cleanup_ssh_keys
    cleanup_manifest_backups
    reset_manifests
    cleanup_logs
    
    echo ""
    verify_cleanup || true
    
    log_section "Cleanup Complete"
    log_success "Environment has been reset"
    
    echo -e "\n${GREEN}To reinstall:${NC}"
    echo "  ./scripts/0-install-dependencies.sh  # If needed"
    echo "  ./scripts/setup-system.sh"
    
    echo -e "\n${BLUE}Log file: ${LOG_FILE}${NC}\n"
}

trap 'log_error "Cleanup failed at line $LINENO"; exit 1' ERR

main "$@"