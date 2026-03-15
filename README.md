# Warlock Infrastructure

This repository holds the Terraform configuration for deploying [Warlock](https://github.com/TristanBlackwell/warlock/tree/master) within a DigitalOcean VPC.

## Architecture

### Network Topology

```
┌─────────────────────────────────────────────────┐
│              Public Internet                     │
└────────────┬──────────────────┬─────────────────┘
             │                  │
    ┌────────▼────────┐  ┌──────▼──────────────┐
    │  Bastion        │  │  Load Balancer      │
    │  Floating IP    │  │  Public IP          │
    │  <bastion-ip>   │  │  <lb-ip>            │
    │                 │  │                     │
    │  SSH Port 22    │  │  HTTP 80 → 8080     │
    └────────┬────────┘  └──────┬──────────────┘
             │                  │
    ┌────────▼──────────────────▼─────────────┐
    │       Private VPC (10.10.0.0/16)        │
    │                                          │
    │  ┌──────────┐  ┌─────────┐             │
    │  │ Gateway  │  │ Worker  │             │
    │  │10.10.0.2 │  │10.10.0.3│   [VMs]     │
    │  │ Port 8080│  │ Port 2222│  [vsock]    │
    │  └──────────┘  └─────────┘             │
    └──────────────────────────────────────────┘
```

### IP Usage

| Purpose | IP to Use | Example |
|---------|-----------|---------|
| Create/Delete VMs | Load Balancer IP | `curl http://<lb-ip>/vm` |
| SSH to VMs | Bastion IP | `ssh vm-<uuid>@<bastion-ip>` |

**Different IPs?**
- **Bastion IP** (Floating IP) - Stable, dedicated SSH gateway
- **Load Balancer IP** - Can have SSL certificate and domain name, scales gateway instances

### Components

- **VPC (10.10.0.0/16)**: Private network for all infrastructure
- **Bastion**: SSH gateway with public floating IP for VM access
- **Gateway**: VM registry and orchestration API (smart worker selection, capacity tracking)
- **Worker(s)**: Warlock Firecracker control plane instances
- **Load Balancer**: Public HTTP/HTTPS endpoint for gateway API
- **Firewalls**: Strict security rules for each component

### Gateway API

The Gateway API exposes a _proxy_ over a single or multiple instances of Warlock acting as a registry, indirection
for scaling, and although not currently implemented, authentication.

- **Worker selection** - Best-fit scheduling based on capacity
- **Capacity tracking** - Resource availability across workers
- **VM location registry** - Routes SSH connections to correct worker
- **Automatic failover** - Marks unhealthy workers and reroutes

See [QUICKSTART.md](QUICKSTART.md) for usage examples.

## Prerequisites

1. **DigitalOcean Account** with API access
2. **Terraform** v1.4+ ([Installation](https://developer.hashicorp.com/terraform/downloads))
3. **doctl** CLI ([Installation](https://docs.digitalocean.com/reference/doctl/how-to/install/))
4. **SSH Key** registered with DigitalOcean

## Quick Start

### 1. Configure Variables

```bash
# Copy the example variables file
cp terraform.tfvars.example terraform.tfvars

vim terraform.tfvars
```

Required variables:
- `do_token`: DigitalOcean API token
- `region`: Deployment region (e.g., `lon1`)
- `ssh_key_id`: SSH key ID from `doctl compute ssh-key list`
- `admin_ssh_key`: Your public SSH key content

### 2. Initialize Terraform

```bash
terraform init
```

### 3. Review Plan

```bash
terraform plan
```

### 4. Deploy Infrastructure

```bash
terraform apply
```

## Configuration

### Variables

| Variable        | Description                | Default | Required |
| --------------- | -------------------------- | ------- | -------- |
| `do_token`      | DigitalOcean API token     | -       | Yes      |
| `region`        | Deployment region          | `nyc3`  | No       |
| `ssh_key_id`    | SSH key ID                 | -       | Yes      |
| `admin_ssh_key` | Public SSH key content     | -       | Yes      |
| `worker_count`  | Number of worker instances | `1`     | No       |
| `domain`        | Domain for SSL             | `""`    | No       |
| `cert_id`       | Certificate ID for HTTPS   | `""`    | No       |

### Adding HTTPS

1. **Create or upload SSL certificate:**
   ```bash
   doctl compute certificate create --name warlock-cert \
     --leaf-certificate-path cert.pem \
     --private-key-path key.pem
   ```

2. **Get certificate ID:**
   ```bash
   doctl compute certificate list
   ```

3. **Update terraform.tfvars:**
   ```hcl
   domain  = "api.example.com"
   cert_id = "abc123-def456-ghi789"
   ```

4. **Apply changes:**
   ```bash
   terraform apply
   ```

### Scaling Workers

To add more Warlock control plane instances:

```hcl
# terraform.tfvars
worker_count = 3
```

Then apply:
```bash
terraform apply
```

The API droplet will receive updated worker configuration.

## VM Management

### Creating VMs via Gateway

VMs are created through the gateway's orchestration API. The gateway automatically selects the best worker based on available capacity.

**Get your infrastructure IPs:**
```bash
# Bastion IP (for SSH)
BASTION_IP=$(terraform output -raw bastion_public_ip)

# Load Balancer IP (for API)
LB_IP=$(terraform output -raw load_balancer_ip)
```

**Create a VM:**
```bash
curl -X POST http://$LB_IP/vm \
  -H "Content-Type: application/json" \
  -d '{
    "vcpus": 1,
    "memory_mb": 256,
    "ssh_keys": ["ssh-ed25519 AAAA... your-key"]
  }'
```

**Response:**
```json
{
  "id": "550e8400-e29b-41d4-a716-446655440000",
  "vcpus": 1,
  "memory_mb": 256,
  "state": "Running",
  "vmm_version": "1.15.0",
  "guest_ip": "172.16.0.2"
}
```

### SSH Access to VMs

> [!IMPORTANT]
> Add your SSH key to the agent first!

```bash
# REQUIRED: Load SSH key into agent
ssh-add ~/.ssh/your_private_key

# Verify it's loaded
ssh-add -l

# Connect to VM (auto-login as root)
ssh vm-<vm-id>@$BASTION_IP
```

You will be **automatically logged in as root** - no password prompt.

**Why ssh-add is required:** Agent forwarding allows your key to authenticate through the bastion → worker chain without storing keys on intermediate servers.

**See [VM-SSH-ACCESS.md](VM-SSH-ACCESS.md) for detailed SSH documentation and troubleshooting.**

### Deleting VMs

```bash
# Delete via gateway API
curl -X DELETE http://$LB_IP/vm/<vm-id>
```

### Check Infrastructure Health

```bash
# Gateway health (shows workers and VMs)
curl http://$LB_IP/internal/health
```

## Troubleshooting

### VM SSH Access Issues

**Problem: "Permission denied (publickey)"**
- Ensure key is loaded in SSH agent: `ssh-add -l`
- Verify VM was created with your public key
- Check you're using the private key (without `.pub`)

**Problem: "Connection timeout"**
- Check you're using **bastion IP** for SSH (not load balancer)
- Verify bastion is running: `terraform output bastion_public_ip`
- Cloud-init may still be running (wait 60-90s after deployment)

**Problem: "No workers available with sufficient capacity"**
- Workers are at capacity
- Check usage: `curl http://$LB_IP/internal/health`
- Delete unused VMs to free resources
- Workers report capacity every 30s (wait for heartbeat)

**Problem: Terraform output shows wrong IP**
- State is stale: `terraform refresh`
- Or check actual: `doctl compute droplet list`

**For complete troubleshooting, see [VM-SSH-ACCESS.md](VM-SSH-ACCESS.md).**

### Deployment Issues

**Problem: Terraform fails with "droplet not found"**
- Clean state: `terraform destroy` then `terraform apply`
- Check API token has correct permissions

**Problem: Gateway shows 0 workers**
- Wait 30s for worker heartbeat
- Check worker logs: `ssh -J bastionuser@$BASTION_IP workeruser@<worker-ip> journalctl -u warlock -f`
- Verify `GATEWAY_URL` is correct in worker cloud-init

## Related

- **[SSH Access Guide](VM-SSH-ACCESS.md)** - Detailed SSH documentation
- [Warlock](https://github.com/TristanBlackwell/warlock) - Firecracker management API
- [Warlock Gateway](https://github.com/TristanBlackwell/warlock-gateway) - VM orchestration API
- [Firecracker](https://firecracker-microvm.github.io/) - Lightweight virtualization
