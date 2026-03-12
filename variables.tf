variable "do_token" {
  description = "DigitalOcean API token"
  type        = string
  sensitive   = true
}

variable "region" {
  description = "DigitalOcean region for deployment"
  type        = string
  default     = "lon1"
}

variable "ssh_key_id" {
  description = "DigitalOcean SSH key ID"
  type        = string
}

variable "admin_ssh_key" {
  description = "Public SSH key content for admin access"
  type        = string
}

variable "worker_count" {
  description = "Number of worker (control plane) instances"
  type        = number
  default     = 1
}

variable "domain" {
  description = "Domain name for SSL certificate (optional)"
  type        = string
  default     = ""
}

variable "cert_id" {
  description = "DigitalOcean certificate ID for load balancer HTTPS (optional)"
  type        = string
  default     = ""
}
