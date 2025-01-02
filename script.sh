#!/bin/bash

# Exit immediately if a command exits with a non-zero status. By enabling set -e, you ensure that if any command in the script fails, the entire script stops running, preventing further commands from executing in potentially faulty or inconsistent states. This is helpful for debugging or ensuring that failures are caught early in automation tasks
set -e 

# Define directories
TERRAFORM="terraform"
ANSIBLE="ansible"

# Update and install prerequisites
sudo apt update && sudo apt install -y \
    software-properties-common \
    curl \
    unzip \
    sshpass

# Install Ansible
sudo apt-add-repository --yes --update ppa:ansible/ansible
sudo apt update
sudo apt install -y ansible


# Install Terraform
TERRAFORM_VERSION="1.6.0"  #version (it can be adjusted)

# Check if Terraform is already installed and up-to-date
if command -v terraform &> /dev/null && [ "$(terraform version | head -n 1 | awk '{print $2}')" == "v${TERRAFORM_VERSION}" ]; then
  echo "Terraform ${TERRAFORM_VERSION} is already installed."
else
  echo "Installing Terraform ${TERRAFORM_VERSION}..."
  curl -fsSL -o terraform.zip "https://releases.hashicorp.com/terraform/${TERRAFORM_VERSION}/terraform_${TERRAFORM_VERSION}_linux_amd64.zip"
  unzip terraform.zip
  sudo rm -rf /usr/local/bin/terraform  # Remove existing binary or directory
  sudo mv terraform /usr/local/bin/
  rm terraform.zip
fi


# Prepare Terraform configuration directory
mkdir -p "$TERRAFORM"
cat > "$TERRAFORM/main.tf" <<EOF
provider "aws" {
  region = "us-east-2"
}
resource "aws_key_pair" "example" {
  key_name   = "example-key"
  public_key = file("~/.ssh/id_rsa.pub")
}

resource "aws_security_group" "allow_ssh_http" {
  name_prefix = "allow_ssh_http"

  ingress {
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    from_port   = 3000
    to_port     = 3000
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    from_port   = 9090
    to_port     = 9090
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}
resource "aws_instance" "example" {
  ami           = "ami-00eb69d236edcfaf8"  # AMI
  instance_type = "t2.micro"
  key_name      = aws_key_pair.example.key_name
  security_groups = [aws_security_group.allow_ssh_http.name]

  tags = {
    Name = "Prometheus-Server"
  }
}

output "instance_ip" {
  value = aws_instance.example.public_ip
}
EOF

# Initialize and apply Terraform configuration
cd "$TERRAFORM"
terraform init
terraform apply -auto-approve

# Get the instance IP
INSTANCE_IP=$(terraform output -raw instance_ip)

cd ..
# Wait for the instance to initialize
echo "Waiting for the EC2 instance to initialize..."
sleep 60


# Prepare Ansible configuration
mkdir -p "$ANSIBLE/roles/prometheus/tasks"
mkdir -p "$ANSIBLE/roles/node_exporter/tasks"
mkdir -p "$ANSIBLE/roles/grafana/tasks"

# Prometheus role
cat > "$ANSIBLE/roles/prometheus/tasks/main.yml" <<EOF
---
- name: Download Prometheus binary
  get_url:
    url: "https://github.com/prometheus/prometheus/releases/download/v2.47.0/prometheus-2.47.0.linux-amd64.tar.gz"
    dest: /tmp/prometheus.tar.gz

- name: Extract Prometheus binary
  become: true
  ansible.builtin.unarchive:
    src: /tmp/prometheus.tar.gz
    dest: /usr/local/bin/
    remote_src: yes

- name: Create Prometheus configuration directory
  become: true
  file:
    path: /etc/prometheus
    state: directory
    mode: '0755'

- name: Move Prometheus binaries to appropriate directories
  become: true
  shell: |
    mv /usr/local/bin/prometheus-2.47.0.linux-amd64/prometheus /usr/local/bin/
    mv /usr/local/bin/prometheus-2.47.0.linux-amd64/promtool /usr/local/bin/
    mv /usr/local/bin/prometheus-2.47.0.linux-amd64/*.yml /etc/prometheus/
    mv /usr/local/bin/prometheus-2.47.0.linux-amd64/console_libraries /etc/prometheus/
    mv /usr/local/bin/prometheus-2.47.0.linux-amd64/consoles /etc/prometheus/
  args:
    creates: /usr/local/bin/prometheus

- name: Create Prometheus systemd service
  become: true
  copy:
    dest: /etc/systemd/system/prometheus.service
    content: |
      [Unit]
      Description=Prometheus Monitoring
      After=network.target

      [Service]
      User=prometheus
      ExecStart=/usr/local/bin/prometheus --config.file=/etc/prometheus/prometheus.yml --storage.tsdb.path=/var/lib/prometheus --web.console.templates=/etc/prometheus/consoles --web.console.libraries=/etc/prometheus/console_libraries

      [Install]
      WantedBy=multi-user.target

- name: Reload systemd and start Prometheus
  become: true
  systemd:
    daemon_reload: yes
    name: prometheus
    enabled: yes
    state: started

EOF


# Node Exporter role
cat > "$ANSIBLE/roles/node_exporter/tasks/main.yml" <<EOF
---
- name: Download Node Exporter
  become: true
  get_url:
    url: "https://github.com/prometheus/node_exporter/releases/download/v1.6.0/node_exporter-1.6.0.linux-amd64.tar.gz"
    dest: /tmp/node_exporter.tar.gz

- name: Extract Node Exporter
  become: true
  ansible.builtin.unarchive:
    src: /tmp/node_exporter.tar.gz
    dest: /usr/local/bin/
    remote_src: yes

- name: Move Node Exporter binary
  become: true
  shell: |
    mv /usr/local/bin/node_exporter-1.6.0.linux-amd64/node_exporter /usr/local/bin/
  args:
    creates: /usr/local/bin/node_exporter

- name: Create Node Exporter systemd service
  become: true
  copy:
    dest: /etc/systemd/system/node_exporter.service
    content: |
      [Unit]
      Description=Prometheus Node Exporter
      After=network.target

      [Service]
      User=nobody
      ExecStart=/usr/local/bin/node_exporter

      [Install]
      WantedBy=multi-user.target

- name: Reload systemd and start Node Exporter
  become: true
  systemd:
    daemon_reload: yes
    name: node_exporter
    enabled: yes
    state: started
EOF


# Grafana role

cat > "$ANSIBLE/roles/grafana/tasks/main.yml" <<EOF
---
- name: Add Grafana APT repository
  become: true
  apt_key:
    url: https://packages.grafana.com/gpg.key
    state: present

- name: Add Grafana repository
  become: true
  apt_repository:
    repo: "deb https://packages.grafana.com/oss/deb stable main"
    state: present

- name: Update APT cache
  become: true
  apt:
    update_cache: yes

- name: Install Grafana
  become: true
  apt:
    name: grafana
    state: present

- name: Enable and start Grafana service
  become: true
  systemd:
    name: grafana-server
    enabled: yes
    state: started
EOF

# Generate Ansible inventory
cat > "$ANSIBLE/inventory" <<EOF
[ec2_instance]
$INSTANCE_IP ansible_user=ubuntu ansible_ssh_private_key_file=~/.ssh/id_rsa ansible_ssh_common_args='-o StrictHostKeyChecking=no'
EOF

# Generate Ansible playbook
cat > "$ANSIBLE/playbook.yml" <<EOF
---
- hosts: ec2_instance
  roles:
    - prometheus
    - node_exporter
    - grafana
EOF

# Run Ansible playbook
cd "$ANSIBLE"
ansible-playbook -i inventory playbook.yml

# Success message
echo "Setup complete. Prometheus, Node Exporter, and Grafana have been deployed to $INSTANCE_IP."

