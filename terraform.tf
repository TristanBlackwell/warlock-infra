terraform {
  required_providers {
    digitalocean = { source = "digitalocean/digitalocean" }
  }
}

provider "digitalocean" {
  token = var.do_token
}

resource "digitalocean_vpc" "main" {
  name     = "warlock-private-vpc"
  region   = var.region
  ip_range = "10.10.0.0/16"
}

resource "digitalocean_droplet" "bastion" {
  name     = "bastion"
  region   = var.region
  size     = "s-1vcpu-512mb-10gb"
  image    = "ubuntu-24-04-x64"
  vpc_uuid = digitalocean_vpc.main.id
  ssh_keys = [var.ssh_key_id]

  user_data = templatefile("${path.module}/cloudinit/bastion-cloudinit.yaml", {
    ssh_key         = var.admin_ssh_key
    gateway_api_url = "http://${digitalocean_droplet.gateway.ipv4_address_private}:8080"
  })
  tags = ["bastion"]
}

resource "digitalocean_floating_ip" "bastion" {
  region = var.region
}

resource "digitalocean_floating_ip_assignment" "bastion" {
  ip_address = digitalocean_floating_ip.bastion.ip_address
  droplet_id = digitalocean_droplet.bastion.id
}

resource "digitalocean_droplet" "gateway" {
  name     = "gateway"
  region   = var.region
  size     = "s-1vcpu-1gb"
  image    = "ubuntu-24-04-x64"
  vpc_uuid = digitalocean_vpc.main.id
  ssh_keys = [var.ssh_key_id]
  tags     = ["gateway"]
  user_data = templatefile("${path.module}/cloudinit/gateway-cloudinit.yaml", {
    ssh_key = var.admin_ssh_key
  })
}

resource "digitalocean_loadbalancer" "gateway_lb" {
  name     = "gateway-lb"
  region   = var.region
  vpc_uuid = digitalocean_vpc.main.id

  # HTTP forwarding rule
  forwarding_rule {
    entry_protocol  = "http"
    entry_port      = 80
    target_protocol = "http"
    target_port     = 8080
  }

  # HTTPS forwarding rule
  dynamic "forwarding_rule" {
    for_each = var.cert_id != "" ? [1] : []
    content {
      entry_protocol  = "https"
      entry_port      = 443
      target_protocol = "http"
      target_port     = 8080
      certificate_id  = var.cert_id
    }
  }

  redirect_http_to_https = var.cert_id != "" ? true : false

  healthcheck {
    protocol = "http"
    port     = 8080
    path     = "/internal/health"
  }

  droplet_tag = "gateway"
}

resource "digitalocean_droplet" "worker" {
  count    = var.worker_count
  name     = "worker-${count.index}"
  region   = var.region
  size     = "s-1vcpu-512mb-10gb"
  image    = "ubuntu-24-04-x64"
  vpc_uuid = digitalocean_vpc.main.id
  ssh_keys = [var.ssh_key_id]
  tags     = ["worker"]
  user_data = templatefile("${path.module}/cloudinit/worker-cloudinit.yaml", {
    ssh_key    = var.admin_ssh_key
    gateway_ip = digitalocean_droplet.gateway.ipv4_address_private
    hostname   = "worker-${count.index}"
  })
}