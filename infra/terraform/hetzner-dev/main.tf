terraform {
  required_version = ">= 1.5"
  required_providers {
    hcloud = {
      source  = "hetznercloud/hcloud"
      version = "~> 1.45"
    }
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

provider "hcloud" {
  token = var.hcloud_token
}

provider "aws" {
  profile = var.aws_profile
  region  = "us-east-1" # Route 53 is global; region is only for the API endpoint
}

# ---------- variables ----------

variable "hcloud_token" {
  type        = string
  sensitive   = true
  description = "Hetzner Cloud API token. Export TF_VAR_hcloud_token from op://Private/hetzner_podcasts_token/token — never write it to a file."
}

variable "ssh_public_key" {
  type        = string
  sensitive   = true
  description = "Public key for the admin user."
}

variable "route53_zone_id" {
  type        = string
  description = "Hosted zone id for the root domain (mcgiv.dev = Z0115995336TMVXI5W90N)."
}

variable "root_domain" {
  type    = string
  default = "mcgiv.dev"
}

variable "dev_subdomain" {
  type    = string
  default = "pods"
}

variable "dev_hostname" {
  type        = string
  default     = ""
  description = "Optional full hostname override; defaults to <dev_subdomain>.<root_domain>."
}

variable "server_type" {
  type    = string
  default = "cpx11" # cheapest US-region type; 2 GB RAM — cloud-init adds 2G swap for builds
}

variable "location" {
  type    = string
  default = "ash"
}

variable "admin_username" {
  type    = string
  default = "matt"
}

variable "route53_ttl" {
  type    = number
  default = 60
}

variable "route53_allow_overwrite" {
  type    = bool
  default = true
}

variable "aws_profile" {
  type        = string
  default     = "bosque-chat-admin"
  description = "AWS profile owning the Route 53 zone. mcgiv.dev always uses bosque-chat-admin."
}

locals {
  hostname = var.dev_hostname != "" ? var.dev_hostname : "${var.dev_subdomain}.${var.root_domain}"
}

# ---------- hetzner ----------

resource "hcloud_ssh_key" "admin" {
  name       = "pods-dev-admin"
  public_key = var.ssh_public_key
}

resource "hcloud_firewall" "pods_dev" {
  name = "pods-dev"

  dynamic "rule" {
    for_each = [22, 80, 443]
    content {
      direction  = "in"
      protocol   = "tcp"
      port       = tostring(rule.value)
      source_ips = ["0.0.0.0/0", "::/0"]
    }
  }
}

resource "hcloud_server" "pods_dev" {
  name         = "pods-dev"
  image        = "ubuntu-24.04"
  server_type  = var.server_type
  location     = var.location
  ssh_keys     = [hcloud_ssh_key.admin.id]
  firewall_ids = [hcloud_firewall.pods_dev.id]

  user_data = <<-CLOUDINIT
    #cloud-config
    ssh_pwauth: false
    users:
      - name: ${var.admin_username}
        shell: /bin/bash
        sudo: "ALL=(ALL) NOPASSWD:ALL"
        ssh_authorized_keys:
          - ${var.ssh_public_key}
    package_update: true
    package_upgrade: true
    packages:
      - git
      - curl
      - ca-certificates
      - fail2ban
      - unattended-upgrades
      - ufw
      - tmux
    swap:
      filename: /swapfile
      size: 2G
    write_files:
      - path: /etc/ssh/sshd_config.d/99-hardening.conf
        content: |
          PermitRootLogin no
          PasswordAuthentication no
          KbdInteractiveAuthentication no
      - path: /usr/local/bin/pods-dev-up
        permissions: "0755"
        content: |
          #!/bin/sh
          set -eu
          APP=/opt/pods/app
          [ -d "$APP/.git" ] || { echo "missing checkout at $APP — clone the repo first (see infra/terraform/hetzner-dev/README.md)" >&2; exit 1; }
          [ -f "$APP/.env" ] || { echo "missing $APP/.env — populate secrets first (see infra/terraform/hetzner-dev/README.md)" >&2; exit 1; }
          cd "$APP"
          exec docker compose up --build -d
    runcmd:
      - install -m 0755 -d /etc/apt/keyrings
      - curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
      - echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu noble stable" > /etc/apt/sources.list.d/docker.list
      - apt-get update
      - apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
      - usermod -aG docker ${var.admin_username}
      - ufw allow OpenSSH
      - ufw allow 80/tcp
      - ufw allow 443/tcp
      - ufw --force enable
      - mkdir -p /opt/pods/app
      - chown -R ${var.admin_username}:${var.admin_username} /opt/pods
      - systemctl restart ssh
      - touch /var/lib/cloud/instance/pods-cloud-init-done
  CLOUDINIT
}

# ---------- dns ----------

resource "aws_route53_record" "pods_dev" {
  zone_id         = var.route53_zone_id
  name            = local.hostname
  type            = "A"
  ttl             = var.route53_ttl
  allow_overwrite = var.route53_allow_overwrite
  records         = [hcloud_server.pods_dev.ipv4_address]
}

# ---------- outputs ----------

output "ipv4" {
  value = hcloud_server.pods_dev.ipv4_address
}

output "hostname" {
  value = local.hostname
}

output "app_url" {
  value = "https://${local.hostname}"
}

output "ssh_command" {
  value = "ssh ${var.admin_username}@${local.hostname}"
}

output "app_start_command" {
  value = "ssh ${var.admin_username}@${local.hostname} pods-dev-up"
}
