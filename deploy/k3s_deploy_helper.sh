#!/bin/bash

# K3s Cloud-Init Deployment Helper Script (Fixed Version)
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
print_header "K3s Cloud-Init Configuration Generator"

echo "This script will help you generate cloud-init files for your k3s cluster."
echo "You'll need to provide some basic information about your setup."
echo ""

# Collect configuration information
MASTER_IP=$(prompt_with_default "Enter the master node IP address" "10.77.0.200")
while ! validate_ip "$MASTER_IP"; do
    print_error "Invalid IP address format"
    MASTER_IP=$(prompt_with_default "Enter the master node IP address" "10.77.0.200")
done

MASTER_HOSTNAME=$(prompt_with_default "Enter the master node hostname" "k3s-master")

SSH_KEY_PATH=$(prompt_with_default "Path to your SSH public key" "$HOME/.ssh/id_rsa.pub")
if [[ -f "$SSH_KEY_PATH" ]]; then
    SSH_KEY=$(cat "$SSH_KEY_PATH")
    print_success "SSH key loaded from $SSH_KEY_PATH"
else
    print_warning "SSH key file not found. Using placeholder."
    SSH_KEY="ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABAQC... # Replace with your SSH public key"
fi

NODE_TOKEN=$(prompt_with_default "K3s node token (leave empty to generate random)" "")
if [[ -z "$NODE_TOKEN" ]]; then
    NODE_TOKEN=$(openssl rand -hex 32)
    print_success "Generated random node token"
fi

WORKER_COUNT=$(prompt_with_default "Number of worker nodes to configure" "1")

# Create output directory
OUTPUT_DIR="k3s-cloud-init-$(date +%Y%m%d_%H%M%S)"
mkdir -p "$OUTPUT_DIR"

print_header "Generating Configuration Files"

# Generate master node configuration
print_success "Generating master node configuration..."

cat > "$OUTPUT_DIR/master-cloud-init.yaml" << EOF
#cloud-config
# K3s Master Node Bootstrap Script
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
  - ufw

users:
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
      kubelet-arg:
        - "max-pods=250"
        - "node-labels=node-role=master"
      write-kubeconfig-mode: "0644"
      tls-san:
        - "localhost"
        - "127.0.0.1"
        - "$MASTER_HOSTNAME"
        - "$MASTER_IP"
    permissions: '0600'
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
      echo "Firewall configured successfully"
    permissions: '0755'
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
  - mkdir -p /etc/rancher/k3s
  - /usr/local/bin/setup-firewall.sh
  - curl -sfL https://get.k3s.io | INSTALL_K3S_EXEC="--config /etc/rancher/k3s/config.yaml" sh -
  - sleep 30
  - until kubectl --kubeconfig=/etc/rancher/k3s/k3s.yaml get nodes | grep -q "Ready"; do sleep 10; done
  - echo "K3s master installation completed!"
  - kubectl --kubeconfig=/etc/rancher/k3s/k3s.yaml get nodes

final_message: |
  K3s Master Node Ready!
  
  Master IP: $MASTER_IP
  Master Hostname: $MASTER_HOSTNAME
  Node Token: $NODE_TOKEN
  
  SSH to master: ssh k3sadmin@$MASTER_IP
  Get nodes: kubectl get nodes
  
  Workers can join with:
  curl -sfL https://get.k3s.io | K3S_URL=https://$MASTER_IP:6443 K3S_TOKEN=$NODE_TOKEN sh -

power_state:
  mode: reboot
  delay: "+1"
  message: "Rebooting after k3s master installation"
EOF

# Generate worker node configurations
for i in $(seq 1 $WORKER_COUNT); do
    print_success "Generating worker node $i configuration..."
    
    WORKER_IP=$(prompt_with_default "Enter IP for worker node $i" "10.77.0.$((200 + i))")
    while ! validate_ip "$WORKER_IP"; do
        print_error "Invalid IP address format"
        WORKER_IP=$(prompt_with_default "Enter IP for worker node $i" "10.77.0.$((200 + i))")
    done
    
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

users:
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
        - "node-labels=worker-id=$i"
      node-ip: $WORKER_IP
    permissions: '0600'
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
  - mkdir -p /etc/rancher/k3s
  - echo "Waiting for master node connectivity..."
  - until ping -c1 $MASTER_IP >/dev/null 2>&1; do echo "Waiting for master..."; sleep 10; done
  - echo "Master reachable, installing k3s agent..."
  - curl -sfL https://get.k3s.io | INSTALL_K3S_EXEC="agent --config /etc/rancher/k3s/config.yaml" sh -
  - echo "K3s worker node $i installation completed!"

final_message: |
  K3s Worker Node $i Ready!
  
  Worker IP: $WORKER_IP
  Worker Role: $WORKER_ROLE
  Master: $MASTER_IP:6443
  
  SSH to worker: ssh k3sadmin@$WORKER_IP

power_state:
  mode: reboot
  delay: "+1"
  message: "Rebooting after k3s worker installation"
EOF
done

# Generate quick deployment script
cat > "$OUTPUT_DIR/deploy.sh" << EOF
#!/bin/bash

echo "K3s Cluster Deployment Guide"
echo "============================="
echo ""

echo "1. Deploy Master Node:"
echo "   sudo cloud-init --file master-cloud-init.yaml"
echo "   # Wait 3-5 minutes for completion"
echo ""

echo "2. Check Master Status:"
echo "   ssh k3sadmin@$MASTER_IP 'kubectl get nodes'"
echo ""

echo "3. Deploy Worker Nodes:"
for i in \$(seq 1 $WORKER_COUNT); do
    echo "   sudo cloud-init --file worker-\$i-cloud-init.yaml"
done
echo ""

echo "4. Verify Cluster:"
echo "   ssh k3sadmin@$MASTER_IP 'kubectl get nodes -o wide'"
echo ""

echo "Master IP: $MASTER_IP"
echo "Token: $NODE_TOKEN"
echo ""
echo "Manual worker join command:"
echo "curl -sfL https://get.k3s.io | K3S_URL=https://$MASTER_IP:6443 K3S_TOKEN=$NODE_TOKEN sh -"
EOF

chmod +x "$OUTPUT_DIR/deploy.sh"

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
echo "  └── 🚀 deploy.sh"
echo ""

print_success "Cluster Summary:"
echo "  🖥️  Master: $MASTER_IP ($MASTER_HOSTNAME)"
echo "  👥 Workers: $WORKER_COUNT nodes"
echo "  🔑 Token: ${NODE_TOKEN:0:16}..."
echo ""

print_warning "Next Steps:"
echo "1. Review the generated configurations"
echo "2. Deploy master node first: sudo cloud-init --file $OUTPUT_DIR/master-cloud-init.yaml"
echo "3. Wait for master to be ready (3-5 minutes)"
echo "4. Deploy worker nodes using their respective configurations"
echo "5. Verify cluster: ssh k3sadmin@$MASTER_IP 'kubectl get nodes'"
echo ""

echo "🚀 See $OUTPUT_DIR/deploy.sh for deployment commands"

print_success "Happy clustering! 🎉"
