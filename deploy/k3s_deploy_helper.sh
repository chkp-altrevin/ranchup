#!/bin/bash

# K3s Cloud-Init Deployment Helper Script
# This script helps you customize and generate the cloud-init files for your k3s cluster

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Function to print colored output
print_header() {
    echo -e "${BLUE}================================================${NC}"
    echo -e "${BLUE} $1${NC}"
    echo -e "${BLUE}================================================${NC}"
}

print_success() {
    echo -e "${GREEN}✓ $1${NC}"
}

print_warning() {
    echo -e "${YELLOW}⚠ $1${NC}"
}

print_error() {
    echo -e "${RED}✗ $1${NC}"
}

# Function to prompt for input with default value
prompt_with_default() {
    local prompt="$1"
    local default="$2"
    local result
    
    read -p "$prompt [$default]: " result
    echo "${result:-$default}"
}

# Function to validate IP address
validate_ip() {
    local ip=$1
    if [[ $ip =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
        return 0
    else
        return 1
    fi
}

# Main script
print_header "Generating Configuration Files"

# Generate master node configuration
print_success "Generating master node configuration..."

cat > "$OUTPUT_DIR/master-cloud-init.yaml" << EOF
#cloud-config
# Enhanced K3s Master Node Bootstrap Script
# Generated on $(date)

package_update: true
package_upgrade: true

packages:
  - curl
  - wget
  - git
  - htop
  - net-tools
  - unzip
  - jq
  - iotop
  - nethogs
  - fail2ban
  - ufw
  - rsync
  - cron
  - logrotate

users:
  - name: k3s
    system: true
    shell: /bin/false
    home: /var/lib/k3s
    create_home: true
  - name: k3sadmin
    gecos: "K3s Administrator"
    sudo: ALL=(ALL) NOPASSWD:ALL
    shell: /bin/bash
    groups: users,admin
    ssh_authorized_keys:
      - $SSH_KEY

write_files:
  - path: /etc/rancher/k3s/config.yaml
    content: |
      cluster-init: true
      disable:
        - traefik
      datastore-endpoint: "etcd"
      kubelet-arg:
        - "max-pods=250"
        - "node-labels=node-role=master"
        - "node-labels=node-type=control-plane"
      kube-apiserver-arg:
        - "default-not-ready-toleration-seconds=30"
        - "default-unreachable-toleration-seconds=30"
        - "audit-log-path=/var/log/k3s-audit.log"
        - "audit-log-maxage=30"
        - "audit-log-maxbackup=3"
        - "audit-log-maxsize=100"
      kube-controller-manager-arg:
        - "node-monitor-period=5s"
        - "node-monitor-grace-period=20s"
        - "pod-eviction-timeout=30s"
      write-kubeconfig-mode: "0644"
      tls-san:
        - "localhost"
        - "127.0.0.1"
        - "$MASTER_HOSTNAME"
        - "$MASTER_IP"
    permissions: '0600'
    owner: root:root

  - path: /usr/local/bin/k3s-backup.sh
    content: |
      #!/bin/bash
      BACKUP_DIR="/var/backups/k3s"
      DATE=\$(date +%Y%m%d_%H%M%S)
      
      mkdir -p \$BACKUP_DIR
      echo "Starting k3s backup at \$(date)"
      
      k3s etcd-snapshot save --etcd-snapshot-dir \$BACKUP_DIR k3s-snapshot-\$DATE
      tar -czf \$BACKUP_DIR/k3s-config-\$DATE.tar.gz /etc/rancher/k3s/ /var/lib/rancher/k3s/server/manifests/ 2>/dev/null
      find \$BACKUP_DIR -name "k3s-*" -mtime +7 -delete
      
      echo "Backup completed at \$(date)"
      ls -la \$BACKUP_DIR/
    permissions: '0755'
    owner: root:root

  - path: /usr/local/bin/k3s-health-check.sh
    content: |
      #!/bin/bash
      LOGFILE="/var/log/k3s-health.log"
      
      log() {
        echo "\$(date '+%Y-%m-%d %H:%M:%S') - \$1" | tee -a \$LOGFILE
      }
      
      log "Starting health check"
      
      if ! systemctl is-active --quiet k3s; then
        log "ERROR: k3s service is not running"
        systemctl restart k3s
        exit 1
      fi
      
      if ! kubectl --kubeconfig=/etc/rancher/k3s/k3s.yaml get nodes >/dev/null 2>&1; then
        log "ERROR: Cannot connect to k3s API server"
        exit 1
      fi
      
      NOT_READY=\$(kubectl --kubeconfig=/etc/rancher/k3s/k3s.yaml get nodes | grep -c "NotReady" || true)
      if [ "\$NOT_READY" -gt 0 ]; then
        log "WARNING: \$NOT_READY nodes are NotReady"
      fi
      
      MEMORY_USAGE=\$(free | grep Mem | awk '{printf "%.0f", \$3/\$2 * 100.0}')
      DISK_USAGE=\$(df /var/lib/rancher | tail -1 | awk '{print \$5}' | sed 's/%//')
      
      if [ "\$MEMORY_USAGE" -gt 90 ]; then
        log "WARNING: High memory usage: \${MEMORY_USAGE}%"
      fi
      
      if [ "\$DISK_USAGE" -gt 85 ]; then
        log "WARNING: High disk usage: \${DISK_USAGE}%"
      fi
      
      log "Health check completed - Memory: \${MEMORY_USAGE}%, Disk: \${DISK_USAGE}%"
    permissions: '0755'
    owner: root:root

  - path: /usr/local/bin/setup-firewall.sh
    content: |
      #!/bin/bash
      ufw --force reset
      ufw default deny incoming
      ufw default allow outgoing
      ufw allow 22/tcp
      ufw allow 6443/tcp
      ufw allow 10250/tcp
      ufw allow 8472/udp
      ufw allow from 10.42.0.0/16
      ufw allow from 10.43.0.0/16
      ufw allow 30000:32767/tcp
      ufw --force enable
    permissions: '0755'
    owner: root:root

  - path: /etc/cron.d/k3s-maintenance
    content: |
      */5 * * * * root /usr/local/bin/k3s-health-check.sh
      0 2 * * * root /usr/local/bin/k3s-backup.sh
      0 3 * * 0 root k3s crictl rmi --prune
    permissions: '0644'
    owner: root:root

bootcmd:
  - modprobe br_netfilter
  - modprobe overlay

runcmd:
  - echo 'net.bridge.bridge-nf-call-iptables = 1' >> /etc/sysctl.conf
  - echo 'net.bridge.bridge-nf-call-ip6tables = 1' >> /etc/sysctl.conf
  - echo 'net.ipv4.ip_forward = 1' >> /etc/sysctl.conf
  - sysctl -p
  - echo 'br_netfilter' >> /etc/modules-load.d/k3s.conf
  - echo 'overlay' >> /etc/modules-load.d/k3s.conf
  - mkdir -p /etc/rancher/k3s /var/lib/rancher/k3s /var/backups/k3s
  - /usr/local/bin/setup-firewall.sh
  - curl -sfL https://get.k3s.io | INSTALL_K3S_EXEC="--config /etc/rancher/k3s/config.yaml" sh -
  - sleep 30
  - until kubectl --kubeconfig=/etc/rancher/k3s/k3s.yaml get nodes | grep -q "Ready"; do sleep 10; done
  - curl https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
  - kubectl --kubeconfig=/etc/rancher/k3s/k3s.yaml apply -f https://github.com/kubernetes-sigs/metrics-server/releases/latest/download/components.yaml
  - /usr/local/bin/k3s-backup.sh

final_message: |
  K3s Master Node Ready!
  
  Master IP: $MASTER_IP
  Node Token: $NODE_TOKEN
  
  Worker nodes can join with:
  curl -sfL https://get.k3s.io | K3S_URL=https://$MASTER_IP:6443 K3S_TOKEN=$NODE_TOKEN sh -

power_state:
  mode: reboot
  delay: "+1"
EOF

# Generate worker node configurations
for i in $(seq 1 $WORKER_COUNT); do
    print_success "Generating worker node $i configuration..."
    
    WORKER_IP=$(prompt_with_default "Enter IP for worker node $i" "192.168.1.$((100 + i))")
    WORKER_ROLE=$(prompt_with_default "Enter role label for worker $i" "worker")
    
    cat > "$OUTPUT_DIR/worker-$i-cloud-init.yaml" << EOF
#cloud-config
# K3s Worker Node $i Bootstrap Script
# Generated on $(date)

package_update: true
package_upgrade: true

packages:
  - curl
  - wget
  - git
  - htop
  - net-tools
  - unzip
  - jq

users:
  - name: k3s
    system: true
    shell: /bin/false
    home: /var/lib/k3s
    create_home: true
  - name: k3sadmin
    gecos: "K3s Administrator"
    sudo: ALL=(ALL) NOPASSWD:ALL
    shell: /bin/bash
    groups: users,admin
    ssh_authorized_keys:
      - $SSH_KEY

write_files:
  - path: /etc/rancher/k3s/config.yaml
    content: |
      server: https://$MASTER_IP:6443
      token: $NODE_TOKEN
      kubelet-arg:
        - "max-pods=250"
        - "node-labels=node-role=$WORKER_ROLE"
        - "node-labels=node-type=worker"
      node-ip: $WORKER_IP
    permissions: '0600'
    owner: root:root

  - path: /etc/systemd/system/k3s-agent.service.d/override.conf
    content: |
      [Service]
      ExecStartPre=/bin/sh -c 'until ping -c1 $MASTER_IP >/dev/null 2>&1; do sleep 5; done'
      ExecStartPre=/bin/sh -c 'until nc -z $MASTER_IP 6443; do echo "Waiting for master..."; sleep 5; done'
      Restart=always
      RestartSec=10s
    permissions: '0644'
    owner: root:root

bootcmd:
  - modprobe br_netfilter
  - modprobe overlay

runcmd:
  - echo 'net.bridge.bridge-nf-call-iptables = 1' >> /etc/sysctl.conf
  - echo 'net.bridge.bridge-nf-call-ip6tables = 1' >> /etc/sysctl.conf
  - echo 'net.ipv4.ip_forward = 1' >> /etc/sysctl.conf
  - sysctl -p
  - echo 'br_netfilter' >> /etc/modules-load.d/k3s.conf
  - echo 'overlay' >> /etc/modules-load.d/k3s.conf
  - mkdir -p /etc/rancher/k3s /etc/systemd/system/k3s-agent.service.d
  - until ping -c1 $MASTER_IP >/dev/null 2>&1; do sleep 10; done
  - curl -sfL https://get.k3s.io | INSTALL_K3S_EXEC="agent --config /etc/rancher/k3s/config.yaml" sh -
  - sleep 30

final_message: |
  K3s Worker Node $i configured!
  
  Node IP: $WORKER_IP
  Role: $WORKER_ROLE
  Master: $MASTER_IP:6443

power_state:
  mode: reboot
  delay: "+1"
EOF
done

# Generate deployment README
cat > "$OUTPUT_DIR/README.md" << EOF
# K3s Cloud-Init Configuration

Generated on $(date) for cluster: $MASTER_HOSTNAME

## Cluster Configuration

- **Master Node**: $MASTER_IP ($MASTER_HOSTNAME)
- **Worker Nodes**: $WORKER_COUNT nodes
- **Node Token**: $NODE_TOKEN

## Files Generated

- \`master-cloud-init.yaml\` - Master node configuration
- \`worker-N-cloud-init.yaml\` - Worker node configurations
- \`deploy-cluster.sh\` - Deployment helper script

## Quick Deployment

1. **Deploy Master Node:**
   \`\`\`bash
   # Copy master-cloud-init.yaml to your cloud provider
   # Or use with cloud-init directly:
   cloud-init --file master-cloud-init.yaml
   \`\`\`

2. **Deploy Worker Nodes:**
   \`\`\`bash
   # Deploy each worker configuration to respective nodes
   cloud-init --file worker-1-cloud-init.yaml
   cloud-init --file worker-2-cloud-init.yaml
   \`\`\`

3. **Verify Cluster:**
   \`\`\`bash
   # On master node:
   kubectl get nodes
   kubectl get pods -A
   \`\`\`

## Useful Commands

### On Master Node:
- \`kubectl get nodes\` - View cluster nodes
- \`/usr/local/bin/k3s-backup.sh\` - Create backup
- \`/usr/local/bin/k3s-health-check.sh\` - Check cluster health
- \`cat /var/lib/rancher/k3s/server/node-token\` - Get join token

### Adding More Workers:
\`\`\`bash
curl -sfL https://get.k3s.io | K3S_URL=https://$MASTER_IP:6443 K3S_TOKEN=$NODE_TOKEN sh -
\`\`\`

## Security Notes

- SSH key authentication is configured
- UFW firewall is enabled on master
- Only required k3s ports are open
- Regular health checks and backups are scheduled

## Troubleshooting

1. **Node won't join:**
   - Check network connectivity to master
   - Verify token is correct
   - Check firewall rules

2. **Pods not starting:**
   - Check node resources: \`kubectl top nodes\`
   - View events: \`kubectl get events\`
   - Check logs: \`journalctl -u k3s -f\`

3. **Health check failures:**
   - View logs: \`/var/log/k3s-health.log\`
   - Manual check: \`/usr/local/bin/k3s-health-check.sh\`

## Customization

To modify the configuration:
1. Edit the YAML files as needed
2. Update network ranges in firewall rules if using custom pod/service CIDRs
3. Adjust resource limits in kubelet-args
4. Add additional TLS SANs if needed

Happy clustering! 🚀
EOF

# Generate deployment script
cat > "$OUTPUT_DIR/deploy-cluster.sh" << 'EOF'
#!/bin/bash

# K3s Cluster Deployment Script
# This script helps deploy the generated cloud-init configurations

set -e

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

echo -e "${GREEN}K3s Cluster Deployment Helper${NC}"
echo "This script provides commands to deploy your k3s cluster"
echo ""

echo -e "${YELLOW}Step 1: Deploy Master Node${NC}"
echo "Copy master-cloud-init.yaml to your master node and run:"
echo "  sudo cloud-init --file master-cloud-init.yaml"
echo "  # Or use with your cloud provider's user-data"
echo ""

echo -e "${YELLOW}Step 2: Wait for Master${NC}"
echo "Wait for master node to be ready (usually 3-5 minutes)"
echo "Check with: ssh k3sadmin@MASTER_IP 'kubectl get nodes'"
echo ""

echo -e "${YELLOW}Step 3: Deploy Workers${NC}"
echo "Deploy each worker node configuration:"
for config in worker-*-cloud-init.yaml; do
    if [[ -f "$config" ]]; then
        echo "  sudo cloud-init --file $config"
    fi
done
echo ""

echo -e "${YELLOW}Step 4: Verify Cluster${NC}"
echo "On the master node, run:"
echo "  kubectl get nodes"
echo "  kubectl get pods -A"
echo ""

echo -e "${GREEN}All configuration files are ready for deployment!${NC}"
EOF

chmod +x "$OUTPUT_DIR/deploy-cluster.sh"

# Summary
print_header "Configuration Complete!"

echo -e "${GREEN}✓ Generated cluster configuration in: $OUTPUT_DIR${NC}"
echo ""
echo "Files created:"
echo "  📁 $OUTPUT_DIR/"
echo "  ├── 📄 master-cloud-init.yaml"
for i in $(seq 1 $WORKER_COUNT); do
    echo "  ├── 📄 worker-$i-cloud-init.yaml"
done
echo "  ├── 📄 README.md"
echo "  └── 🚀 deploy-cluster.sh"
echo ""

print_success "Cluster Summary:"
echo "  🖥️  Master: $MASTER_IP ($MASTER_HOSTNAME)"
echo "  👥 Workers: $WORKER_COUNT nodes"
echo "  🔑 Token: ${NODE_TOKEN:0:16}..."
echo ""

print_warning "Next Steps:"
echo "1. Review the generated configurations"
echo "2. Deploy master node first using master-cloud-init.yaml"
echo "3. Wait for master to be ready (3-5 minutes)"
echo "4. Deploy worker nodes using their respective configurations"
echo "5. Verify cluster with: kubectl get nodes"
echo ""

echo "📖 See $OUTPUT_DIR/README.md for detailed instructions"
echo "🚀 Run $OUTPUT_DIR/deploy-cluster.sh for deployment commands"

print_success "Happy clustering! 🎉"K3s Cloud-Init Configuration Generator"

echo "This script will help you generate cloud-init files for your k3s cluster."
echo "You'll need to provide some basic information about your setup."
echo ""

# Collect configuration information
MASTER_IP=$(prompt_with_default "Enter the master node IP address" "192.168.1.100")
while ! validate_ip "$MASTER_IP"; do
    print_error "Invalid IP address format"
    MASTER_IP=$(prompt_with_default "Enter the master node IP address" "192.168.1.100")
done

MASTER_HOSTNAME=$(prompt_with_default "Enter the master node hostname" "k3s-master")

SSH_KEY_PATH=$(prompt_with_default "Path to your SSH public key" "$HOME/.ssh/id_rsa.pub")
if [[ -f "$SSH_KEY_PATH" ]]; then
    SSH_KEY=$(cat "$SSH_KEY_PATH")
    print_success "SSH key loaded from $SSH_KEY_PATH"
else
    print_warning "SSH key file not found. You'll need to add it manually."
    SSH_KEY="ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABAQC... # Replace with your SSH public key"
fi

NODE_TOKEN=$(prompt_with_default "K3s node token (leave empty to generate random)" "")
if [[ -z "$NODE_TOKEN" ]]; then
    NODE_TOKEN=$(openssl rand -hex 32)
    print_success "Generated random node token"
fi

WORKER_COUNT=$(prompt_with_default "Number of worker nodes to configure" "2")

# Create output directory
OUTPUT_DIR="k3s-cloud-init-$(date +%Y%m%d_%H%M%S)"
mkdir -p "$OUTPUT_DIR"

print_header "
