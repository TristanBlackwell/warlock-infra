resource "digitalocean_firewall" "bastion" {
  name = "bastion-firewall"

  droplet_ids = [digitalocean_droplet.bastion.id]

  # Open SSH
  inbound_rule {
    protocol         = "tcp"
    port_range       = "22"
    source_addresses = ["0.0.0.0/0", "::/0"]
  }

  # All outbound allowed
  outbound_rule {
    protocol              = "tcp"
    port_range            = "1-65535"
    destination_addresses = ["0.0.0.0/0", "::/0"]
  }

  outbound_rule {
    protocol              = "udp"
    port_range            = "1-65535"
    destination_addresses = ["0.0.0.0/0", "::/0"]
  }

  outbound_rule {
    protocol              = "icmp"
    destination_addresses = ["0.0.0.0/0", "::/0"]
  }
}

resource "digitalocean_firewall" "gateway" {
  name = "gateway-firewall"

  droplet_ids = [digitalocean_droplet.gateway.id]

  # API access from load balancer
  inbound_rule {
    protocol                  = "tcp"
    port_range                = "8080"
    source_load_balancer_uids = [digitalocean_loadbalancer.gateway_lb.id]
  }

  # API access from workers (registration / heartbeat)
  inbound_rule {
    protocol         = "tcp"
    port_range       = "8080"
    source_addresses = digitalocean_droplet.worker[*].ipv4_address_private
  }

  # API access from bastion
  inbound_rule {
    protocol         = "tcp"
    port_range       = "8080"
    source_addresses = ["${digitalocean_droplet.bastion.ipv4_address_private}/32"]
  }

  # Allow SSH from bastion only
  inbound_rule {
    protocol         = "tcp"
    port_range       = "22"
    source_addresses = ["${digitalocean_droplet.bastion.ipv4_address_private}/32"]
  }

  outbound_rule {
    protocol              = "tcp"
    port_range            = "1-65535"
    destination_addresses = ["0.0.0.0/0", "::/0"]
  }

  outbound_rule {
    protocol              = "udp"
    port_range            = "1-65535"
    destination_addresses = ["0.0.0.0/0", "::/0"]
  }

  outbound_rule {
    protocol              = "icmp"
    destination_addresses = ["0.0.0.0/0", "::/0"]
  }
}

resource "digitalocean_firewall" "worker" {
  name = "worker-firewall"

  droplet_ids = digitalocean_droplet.worker[*].id

  # Allow Warlock HTTP API (port 3000) from gateway droplet
  inbound_rule {
    protocol         = "tcp"
    port_range       = "3000"
    source_addresses = ["${digitalocean_droplet.gateway.ipv4_address_private}/32"]
  }

  # Allow Warlock SSH console (port 2222) from bastion
  inbound_rule {
    protocol         = "tcp"
    port_range       = "2222"
    source_addresses = ["${digitalocean_droplet.bastion.ipv4_address_private}/32"]
  }

  # Allow SSH from bastion only
  inbound_rule {
    protocol         = "tcp"
    port_range       = "22"
    source_addresses = ["${digitalocean_droplet.bastion.ipv4_address_private}/32"]
  }

  # Allow all outbound (workers need internet for Firecracker guest VMs to access external services)
  outbound_rule {
    protocol              = "tcp"
    port_range            = "1-65535"
    destination_addresses = ["0.0.0.0/0", "::/0"]
  }

  outbound_rule {
    protocol              = "udp"
    port_range            = "1-65535"
    destination_addresses = ["0.0.0.0/0", "::/0"]
  }

  outbound_rule {
    protocol              = "icmp"
    destination_addresses = ["0.0.0.0/0", "::/0"]
  }
}
