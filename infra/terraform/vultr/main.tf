data "vultr_os" "debian" {
  filter {
    name   = "name"
    values = ["Debian 12 x64 (bookworm)"]
  }
}

resource "vultr_ssh_key" "matt" {
  name    = "pods-matt"
  ssh_key = var.ssh_public_key
}

resource "vultr_firewall_group" "pods" {
  description = "pods.mcgiv.dev public web"
}

resource "vultr_firewall_rule" "http" {
  firewall_group_id = vultr_firewall_group.pods.id
  protocol          = "tcp"
  ip_type           = "v4"
  subnet            = "0.0.0.0"
  subnet_size       = 0
  port              = "80"
}

resource "vultr_firewall_rule" "https" {
  firewall_group_id = vultr_firewall_group.pods.id
  protocol          = "tcp"
  ip_type           = "v4"
  subnet            = "0.0.0.0"
  subnet_size       = 0
  port              = "443"
}

resource "vultr_firewall_rule" "http6" {
  firewall_group_id = vultr_firewall_group.pods.id
  protocol          = "tcp"
  ip_type           = "v6"
  subnet            = "::"
  subnet_size       = 0
  port              = "80"
}

resource "vultr_firewall_rule" "https6" {
  firewall_group_id = vultr_firewall_group.pods.id
  protocol          = "tcp"
  ip_type           = "v6"
  subnet            = "::"
  subnet_size       = 0
  port              = "443"
}

resource "vultr_firewall_rule" "ssh" {
  firewall_group_id = vultr_firewall_group.pods.id
  protocol          = "tcp"
  ip_type           = "v4"
  subnet            = "0.0.0.0"
  subnet_size       = 0
  port              = "22"
}

resource "vultr_instance" "pods" {
  plan              = var.plan
  region            = var.region
  os_id             = data.vultr_os.debian.id
  label             = "pods"
  hostname          = "pods"
  enable_ipv6       = true
  ssh_key_ids       = [vultr_ssh_key.matt.id]
  firewall_group_id = vultr_firewall_group.pods.id
  user_data = templatefile("${path.module}/cloud-init.yaml.tftpl", {
    tailscale_auth_key = var.tailscale_auth_key
  })
}

resource "aws_route53_record" "pods_a" {
  zone_id = var.route53_zone_id
  name    = var.hostname
  type    = "A"
  ttl     = 60
  records = [vultr_instance.pods.main_ip]
}

resource "aws_route53_record" "pods_aaaa" {
  zone_id = var.route53_zone_id
  name    = var.hostname
  type    = "AAAA"
  ttl     = 60
  records = [vultr_instance.pods.v6_main_ip]
}

output "ipv4" {
  value = vultr_instance.pods.main_ip
}

output "ipv6" {
  value = vultr_instance.pods.v6_main_ip
}
