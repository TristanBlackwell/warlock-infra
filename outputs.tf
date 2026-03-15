output "vpc_id" {
  description = "ID of the VPC"
  value       = digitalocean_vpc.main.id
}

output "vpc_cidr" {
  description = "CIDR block of the VPC"
  value       = digitalocean_vpc.main.ip_range
}

output "bastion_public_ip" {
  description = "Public floating IP of the bastion host"
  value       = digitalocean_floating_ip.bastion.ip_address
}

output "bastion_private_ip" {
  description = "Private IP of the bastion host"
  value       = digitalocean_droplet.bastion.ipv4_address_private
}

output "bastion_ssh_command" {
  description = "SSH command to connect to bastion"
  value       = "ssh bastionuser@${digitalocean_floating_ip.bastion.ip_address}"
}

output "load_balancer_ip" {
  description = "Public IP address of the load balancer"
  value       = digitalocean_loadbalancer.gateway_lb.ip
}

output "gateway_url" {
  description = "Gateway URL"
  value       = var.cert_id != "" && var.domain != "" ? "https://${var.domain}" : "http://${digitalocean_loadbalancer.gateway_lb.ip}"
}

output "gateway_private_ip" {
  description = "Private IP of the gateway droplet"
  value       = digitalocean_droplet.gateway.ipv4_address_private
}

output "worker_private_ips" {
  description = "Private IPs of all worker (control plane) droplets"
  value       = digitalocean_droplet.worker[*].ipv4_address_private
}

output "worker_names" {
  description = "Names of all worker droplets"
  value       = digitalocean_droplet.worker[*].name
}

output "worker_endpoints" {
  description = "Warlock HTTP API endpoints for all workers"
  value = [
    for ip in digitalocean_droplet.worker[*].ipv4_address_private :
    "http://${ip}:3000"
  ]
}

output "worker_ssh_console_endpoints" {
  description = "Warlock SSH console endpoints for all workers (via bastion with agent forwarding)"
  value = [
    for ip in digitalocean_droplet.worker[*].ipv4_address_private :
    "ssh -A vm-<uuid>@${ip} -p 2222 -o ProxyJump=bastionuser@${digitalocean_floating_ip.bastion.ip_address}"
  ]
}

output "connection_instructions" {
  description = "Quick reference for connecting to infrastructure"
  value       = <<-EOT
    === Warlock Infrastructure - Connection Guide ===
    
    📖 Full Documentation:
      - Quick Start:  See QUICKSTART.md
      - SSH Access:   See VM-SSH-ACCESS.md
      - Architecture: See README.md
    
    🔑 IMPORTANT: Before SSH access, load your key:
      ssh-add ~/.ssh/your_private_key
    
    === API Access (via Load Balancer) ===
    
    Gateway API URL:
      ${var.cert_id != "" && var.domain != "" ? "https://${var.domain}" : "http://${digitalocean_loadbalancer.gateway_lb.ip}"}
    
    Create VM:
      curl -X POST ${var.cert_id != "" && var.domain != "" ? "https://${var.domain}" : "http://${digitalocean_loadbalancer.gateway_lb.ip}"}/vm \
        -H "Content-Type: application/json" \
        -d '{"vcpus":1,"memory_mb":256,"ssh_keys":["<your-public-key>"]}'
    
    Health Check:
      curl ${var.cert_id != "" && var.domain != "" ? "https://${var.domain}" : "http://${digitalocean_loadbalancer.gateway_lb.ip}"}/internal/health
    
    === SSH Access (via Bastion) ===
    
    Bastion IP:
      ${digitalocean_floating_ip.bastion.ip_address}
    
    Connect to VM (auto-login as root):
      ssh vm-<vm-id>@${digitalocean_floating_ip.bastion.ip_address}
    
    === Network Topology ===
    
    Bastion IP:        ${digitalocean_floating_ip.bastion.ip_address}  (for SSH)
    Load Balancer IP:  ${digitalocean_loadbalancer.gateway_lb.ip}      (for API)
    Gateway (private): ${digitalocean_droplet.gateway.ipv4_address_private}
    Workers (private): ${join(", ", digitalocean_droplet.worker[*].ipv4_address_private)}
  EOT
}
