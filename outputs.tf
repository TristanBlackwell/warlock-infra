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
  description = "Warlock SSH console endpoints for all workers (via bastion)"
  value = [
    for ip in digitalocean_droplet.worker[*].ipv4_address_private :
    "ssh vm-<uuid>@${ip} -p 2222 -o ProxyJump=bastionuser@${digitalocean_floating_ip.bastion.ip_address}"
  ]
}

output "connection_instructions" {
  description = "Quick reference for connecting to infrastructure"
  value       = <<-EOT
    === Warlock Infrastructure Connection Guide ===
    
    Bastion SSH:
      ssh bastionuser@${digitalocean_floating_ip.bastion.ip_address}
    
    Gateway API:
      ${var.cert_id != "" && var.domain != "" ? "https://${var.domain}" : "http://${digitalocean_loadbalancer.gateway_lb.ip}"}
    
    Worker SSH (via bastion):
      ssh -J bastionuser@${digitalocean_floating_ip.bastion.ip_address} workeruser@<worker-private-ip>
    
    Warlock API (direct from API host):
      curl http://<worker-private-ip>:3000/internal/health
    
    === Connect to Guest VMs ===
    
    Direct VM Access:
      ssh vm-<uuid>@${digitalocean_floating_ip.bastion.ip_address}
    
    Example:
      # Get VM ID from creating a VM
      VM_ID=$(curl -X POST http://<gateway>/vm -d '{"vcpus":1,"mem_size_mib":128}' | jq -r '.id')
      
      # Connect to VM console
      ssh vm-$VM_ID@${digitalocean_floating_ip.bastion.ip_address}
  EOT
}
