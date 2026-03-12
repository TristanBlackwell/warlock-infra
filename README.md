# Warlock Infrastructure

Terraform configuration for deploying the [Warlock](https://github.com/TristanBlackwell/warlock) Firecracker control plane within a DigitalOcean VPC.

## Architecture

```
                    Internet
                       │
                       │
              ┌────────▼────────┐
              │  Load Balancer  │
              │   HTTP(S)       │
              └────────┬────────┘
                       │
        ┌──────────────┼──────────────┐
        │              │              │
        │      ┌───────▼────────┐     │
        │      │    Gateway     │     │  VPC: 10.10.0.0/16
        │      │   (Port 8080)  │     │
        │      │  VM Registry   │     │
        │      └───────┬────────┘     │
        │              │              │
        │      ┌───────▼────────┐     │
        │      │  Worker(s)     │     │
        │      │  (Warlock)     │     │
        │      │ :3000 / :2222  │     │
        │      └────────────────┘     │
        │                             │
   ┌────▼─────┐              ┌───────▼────────┐
   │ Bastion  │──────SSH─────▶  All Droplets  │
   │ (Floating│              │   Port 22      │
   │    IP)   │  VM Proxy    │                │
   └──────────┘              └────────────────┘
        ▲
        │ ssh vm-<uuid>@bastion
        │
    Your Machine
```

### Components

- **VPC (10.10.0.0/16)**: Private network for all infrastructure
- **Bastion**: SSH gateway with public floating IP for secure access
- **Gateway Droplet**: `warlock-gateway`
- **Worker Droplets**: `warlock`
- **Load Balancer**: Public-facing HTTPS endpoint for the Gateway API
- **Firewalls**: Strict security rules for each component

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

## Related

- [Warlock Control Plane](../warlock) - Firecracker management API
- [Firecracker](https://firecracker-microvm.github.io/) - Lightweight virtualization
