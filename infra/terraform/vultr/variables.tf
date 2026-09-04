variable "region" {
  type        = string
  default     = "ewr"
  description = "Vultr region id"
}

variable "plan" {
  type        = string
  default     = "vc2-1c-2gb"
  description = "Vultr Cloud Compute plan id"
}

variable "ssh_public_key" {
  type = string
}

variable "route53_zone_id" {
  type = string
}

variable "hostname" {
  type    = string
  default = "pods.mcgiv.dev"
}

variable "tailscale_auth_key" {
  type      = string
  sensitive = true
  default   = ""
}
