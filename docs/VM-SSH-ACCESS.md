# VM SSH Access Guide

Comprehensive guide to SSH access for Warlock VMs, including architecture, troubleshooting, and advanced topics.

## Table of Contents

- [Architecture Overview](#architecture-overview)
- [How SSH Access Works](#how-ssh-access-works)
- [Prerequisites](#prerequisites)
- [Step-by-Step Access](#step-by-step-access)
- [Troubleshooting](#troubleshooting)
- [Advanced Topics](#advanced-topics)
- [FAQ](#faq)

## Architecture Overview

### Network Topology

```
┌─────────────────────────────────────────────────┐
│              Public Internet                     │
└────────────┬──────────────────┬─────────────────┘
             │                  │
    ┌────────▼────────┐  ┌──────▼──────────────┐
    │  Bastion        │  │  Load Balancer      │
    │  Floating IP    │  │  Public IP          │
    │  (Stable)       │  │  (Can have domain)  │
    │                 │  │                     │
    │  Port 22        │  │  Port 80/443        │
    │  SSH Access     │  │  HTTP(S) API        │
    └────────┬────────┘  └──────┬──────────────┘
             │                  │
    ┌────────▼──────────────────▼─────────────┐
    │       Private VPC (10.10.0.0/16)        │
    │                                          │
    │  ┌──────────────┐  ┌─────────────────┐ │
    │  │   Gateway    │  │  Worker Node    │ │
    │  │  10.10.0.2   │  │   10.10.0.3     │ │
    │  │              │  │                 │ │
    │  │  Port 8080   │  │  Port 3000 API  │ │
    │  │  VM Registry │  │  Port 2222 SSH  │ │
    │  │              │  │                 │ │
    │  └──────────────┘  └────────┬────────┘ │
    │                              │          │
    │                     ┌────────▼───────┐ │
    │                     │  Firecracker   │ │
    │                     │  VMs (vsock)   │ │
    │                     └────────────────┘ │
    └──────────────────────────────────────────┘
```

### IP Usage Patterns

| Purpose | IP to Use | Example |
|---------|-----------|---------|
| Create VM | Load Balancer IP | `curl http://<lb-ip>/vm` |
| Delete VM | Load Balancer IP | `curl -X DELETE http://<lb-ip>/vm/{id}` |
| Health Check | Load Balancer IP | `curl http://<lb-ip>/internal/health` |
| SSH to VM | Bastion IP | `ssh vm-<uuid>@<bastion-ip>` |
| SSH to Bastion | Bastion IP | `ssh bastionuser@<bastion-ip>` |

**Why different IPs?**
- **Bastion (Floating IP):** Stable IP for SSH, doesn't change, dedicated security gateway
- **Load Balancer:** Can have SSL certificate, domain name, scales gateway instances

## How SSH Access Works

### The SSH Authentication Chain

When you connect to a VM, your SSH session goes through multiple authentication points:

```
┌──────────┐  1. SSH with      ┌──────────┐
│          │     agent fwd     │          │
│   User   ├──────────────────►│ Bastion  │
│          │  ssh vm-X@bastion │          │
└──────────┘                    └────┬─────┘
                                     │
                                     │ 2. Query gateway
                                     │    GET /vm/X/location
                                     ▼
                              ┌──────────┐
                              │ Gateway  │
                              │10.10.0.2 │
                              └────┬─────┘
                                   │
                                   │ 3. Returns:
                                   │    worker_ip=10.10.0.3
                                   │    port=2222
                                   │
                              ┌────▼─────┐
                              │ Bastion  │
                              │ Proxy    │
                              └────┬─────┘
                                   │
                                   │ 4. SSH to worker
                                   │    ssh -A vm-X@10.10.0.3:2222
                                   │    (forwards agent)
                                   ▼
                              ┌──────────┐
                              │ Warlock  │
                              │ SSH Srvr │  5. Validates key
                              │ Port 2222│     against VM's
                              └────┬─────┘     authorized_keys
                                   │
                                   │ 6. Opens vsock
                                   │    connection
                                   ▼
                              ┌──────────┐
                              │    VM    │
                              │  Guest   │  7. Auto-login
                              │          │     /bin/bash -l
                              └──────────┘     as root
```

### Components Involved

**Security Note:** Gateway and worker droplets have firewall rules that **block direct SSH from the internet**. SSH access is **only allowed from the bastion's private IP**. This reduces the attack surface to a single hardened endpoint.

#### 1. NSS Module (Name Service Switch)
- **Location:** `/lib/x86_64-linux-gnu/libnss_warlock.so.2` on bastion
- **Purpose:** Dynamically resolves `vm-<uuid>` usernames to UIDs
- **How:** Parses VM UUID from username, returns synthetic UID
- **Why:** Allows SSH to accept VM usernames without creating actual user accounts

#### 2. VM SSH Proxy Script
- **Location:** `/usr/local/bin/vm-ssh-proxy` on bastion
- **Purpose:** Routes SSH connections to the correct worker
- **How:** 
  1. Extracts VM ID from `$USER` environment variable
  2. Queries gateway API for VM location
  3. Establishes SSH connection to worker with agent forwarding
- **Config:** Executed via `ForceCommand` in `/etc/ssh/sshd_config.d/00-vm-proxy.conf`

#### 3. Warlock SSH Server
- **Location:** Worker node, port 2222
- **Purpose:** Authenticates SSH keys and proxies to VM console
- **How:**
  1. Validates incoming SSH key against VM's `authorized_keys` list
  2. Opens vsock connection to VM's console (vsock port 1024)
  3. Pipes SSH session data to/from vsock
- **Implementation:** Custom Rust SSH server using `russh` library

#### 4. VM Guest Console
- **Location:** Inside Firecracker VM
- **Purpose:** Provides root shell access
- **How:**
  1. `systemd` service runs `socat VSOCK-LISTEN:1024`
  2. Listens for connections from host via vsock
  3. Executes `/bin/bash -l` (login shell as root)
- **Config:** Root password cleared, no authentication required inside VM

### Authentication Flow Detail

**Step 1: User → Bastion**
```bash
ssh vm-29db6982-33b3-4829-a046-7d774c4933eb@<bastion-ip>
```
- SSH agent on user's machine provides key
- Bastion's NSS module resolves `vm-29db6982...` to UID 49235 (synthetic)
- PAM allows VM users via `pam_succeed_if.so user =~ vm-*`
- Bastion authenticates against `/etc/ssh/vm-authorized-keys`

**Step 2: Proxy Queries Gateway**
```bash
# Inside vm-ssh-proxy script
LOCATION=$(curl -sf http://10.10.0.2:8080/vm/29db6982.../location)
WORKER_IP=$(echo "$LOCATION" | jq -r '.worker_ip')
# Returns: 10.10.0.3
```

**Step 3: Proxy → Worker Warlock SSH**
```bash
# Proxy executes
exec ssh -A vm-29db6982...@10.10.0.3 -p 2222
```
- `-A` flag forwards SSH agent from user's machine
- Agent provides user's SSH key to worker connection
- Warlock SSH server validates key against VM's stored `authorized_keys`

**Step 4: Warlock → VM Console**
- Warlock opens vsock connection to VM (CID from VM metadata)
- Connects to vsock port 1024 inside guest
- `socat` inside VM receives connection
- Executes `/bin/bash -l` as root
- User's terminal is now connected to VM's bash shell

## Prerequisites

### 1. SSH Agent Setup

**Why Required:**  
Agent forwarding allows your SSH key to authenticate at multiple points (bastion → worker) without storing keys on intermediate servers.

**Setup:**
```bash
# Start SSH agent (usually already running on macOS/Linux)
eval "$(ssh-agent -s)"

# Add your private key
ssh-add ~/.ssh/your_private_key

# Verify it's loaded
ssh-add -l
# Expected output: 256 SHA256:... /path/to/key (ED25519)
```

**Persistence:**  
On macOS, add to `~/.ssh/config`:
```
Host *
  AddKeysToAgent yes
  UseKeychain yes
```

On Linux, add to `~/.bashrc` or `~/.zshrc`:
```bash
# Auto-start SSH agent and add key
if [ -z "$SSH_AUTH_SOCK" ]; then
  eval "$(ssh-agent -s)"
  ssh-add ~/.ssh/your_private_key 2>/dev/null
fi
```

### 2. SSH Key in VM

When creating VMs, you **must** provide your public key:

```bash
curl -X POST http://<lb-ip>/vm \
  -H "Content-Type: application/json" \
  -d "{
    \"ssh_keys\": [\"$(cat ~/.ssh/your_key.pub)\"]
  }"
```

The Warlock SSH server validates against this exact key.

### 3. Network Access

- Bastion must be reachable on port 22
- Load balancer must be reachable on port 80 (or 443 for HTTPS)
- VPC routing must allow bastion → gateway → worker communication

## Step-by-Step Access

### Creating a VM with SSH Keys

**Via Gateway API:**
```bash
# Get load balancer IP
LB_IP=$(terraform output -raw load_balancer_ip)

# Create VM with your public key
VM_JSON=$(curl -s -X POST http://$LB_IP/vm \
  -H "Content-Type: application/json" \
  -d "{
    \"vcpus\": 1,
    \"memory_mb\": 256,
    \"ssh_keys\": [
      \"$(cat ~/.ssh/id_ed25519.pub)\",
      \"$(cat ~/.ssh/id_rsa.pub)\"
    ]
  }")

# Extract VM ID
VM_ID=$(echo "$VM_JSON" | jq -r '.id')
echo "VM ID: $VM_ID"
```

**Response:**
```json
{
  "id": "29db6982-33b3-4829-a046-7d774c4933eb",
  "vcpus": 1,
  "memory_mb": 256,
  "state": "Running",
  "vmm_version": "1.15.0",
  "guest_ip": "172.16.0.2"
}
```

### Connecting to a VM

**Basic Connection:**
```bash
# Get bastion IP
BASTION_IP=$(terraform output -raw bastion_public_ip)

# Connect (agent forwarding is automatic)
ssh vm-29db6982-33b3-4829-a046-7d774c4933eb@$BASTION_IP
```

**With Verbose Output (for debugging):**
```bash
ssh -v vm-29db6982-33b3-4829-a046-7d774c4933eb@$BASTION_IP
```

**Expected Output:**
```
Could not chdir to home directory /nonexistent: No such file or directory
root@ubuntu-fc-uvm:/#
```

The "chdir" warning is **normal** - NSS module creates synthetic users without home directories.

### What Happens Behind the Scenes

1. **SSH connects to bastion**
   ```
   debug1: Connecting to <bastion-ip> [<bastion-ip>] port 22
   debug1: Connection established
   ```

2. **NSS resolves username**
   ```
   # Bastion runs:
   getpwnam("vm-29db6982-33b3-4829-a046-7d774c4933eb")
   # Returns: UID 49235, shell /usr/local/bin/vm-ssh-proxy
   ```

3. **ForceCommand executes proxy**
   ```
   # /usr/local/bin/vm-ssh-proxy executes
   VM_ID=29db6982-33b3-4829-a046-7d774c4933eb
   ```

4. **Proxy queries gateway**
   ```
   curl http://10.10.0.2:8080/vm/29db6982.../location
   # Returns: {"worker_ip": "10.10.0.3", "port": 2222}
   ```

5. **Proxy SSHs to worker**
   ```
   exec ssh -A vm-29db6982...@10.10.0.3 -p 2222
   # Agent forwards your key
   ```

6. **Warlock validates key**
   ```rust
   // In Warlock SSH server
   is_key_authorized(&incoming_key, &vm.resources.ssh_keys)
   // Returns: true (key matches)
   ```

7. **Warlock opens vsock**
   ```
   # Connects to VM's vsock CID, port 1024
   ```

8. **VM console executes bash**
   ```
   # socat receives connection
   # Executes: /bin/bash -l
   # You're now root in the VM
   ```

## Troubleshooting

### "Permission denied (publickey)"

**Symptom:**
```
vm-29db6982...@10.10.0.3: Permission denied (publickey,hostbased,keyboard-interactive).
Connection to <bastion-ip> closed.
```

**Causes & Solutions:**

#### 1. SSH Key Not Loaded in Agent
**Check:**
```bash
ssh-add -l
# If returns: "The agent has no identities."
```

**Fix:**
```bash
ssh-add ~/.ssh/your_private_key
ssh-add -l  # Verify it's loaded
```

#### 2. Wrong Key Used for VM Creation
**Check:**
```bash
# Compare fingerprints
ssh-keygen -lf ~/.ssh/your_key.pub
ssh-add -l
# Fingerprints should match
```

**Fix:**  
Recreate VM with the correct public key.

#### 3. Using Public Key Instead of Private
**Check:**
```bash
ssh -i ~/.ssh/your_key.pub vm-X@<bastion-ip>
# Error: bad permissions (0644 for .pub file)
```

**Fix:**
```bash
# Use private key (no .pub extension)
ssh-add ~/.ssh/your_key
```

#### 4. Agent Forwarding Disabled
**Check:**
```bash
ssh -v vm-X@<bastion-ip> 2>&1 | grep -i "agent"
# Should see: debug1: Setting up agent forwarding.
```

**Fix:**  
Agent forwarding should be automatic. If not, add to `~/.ssh/config`:
```
Host <bastion-ip>
  ForwardAgent yes
```

### "Connection refused" or "Connection timeout"

**Symptom:**
```
ssh: connect to host <ip> port 22: Connection refused
# or
ssh: connect to host <ip> port 22: Operation timed out
```

**Causes & Solutions:**

#### 1. Wrong IP Used
**Check:**
```bash
# Verify you're using bastion IP, not load balancer
terraform output bastion_public_ip
terraform output load_balancer_ip
# Use bastion IP for SSH
```

#### 2. Bastion Not Running
**Check:**
```bash
doctl compute droplet list | grep bastion
# Should show: bastion ... active
```

**Fix:**  
If not active, redeploy:
```bash
terraform apply
```

#### 3. Firewall Blocking
**Check:**
```bash
doctl compute firewall list
# Should show SSH allowed from all IPs
```

**Fix:**  
Review firewall rules in `firewall.tf`.

#### 4. Cloud-Init Still Running
**Symptom:** Connection works from DigitalOcean console but not SSH.

**Fix:**  
Wait 60-90 seconds after deployment for cloud-init to complete.

### "Could not chdir to home directory /nonexistent"

**Symptom:**
```
Could not chdir to home directory /nonexistent: No such file or directory
root@ubuntu-fc-uvm:/#
```

**Status:** ✅ **This is normal!**

**Explanation:**  
- NSS module creates synthetic users without home directories
- SSH attempts to `chdir` to home, fails gracefully
- Authentication continues normally
- You're successfully logged in as root

**Action Required:** None - this is expected behavior.

### "Password prompt appears"

**Symptom:**
```
vm-29db6982...@10.10.0.3's password:
```

**Causes & Solutions:**

#### 1. Agent Forwarding Failed
**Check:**
```bash
ssh-add -l
# Verify key is loaded
```

**Fix:**
```bash
ssh-add ~/.ssh/your_key
```

#### 2. Wrong VM ID
**Check:**
```bash
# Verify VM exists
curl http://<lb-ip>/vm/$VM_ID/location
# Should return: {"vm_id": "...", "worker_ip": "..."}
```

#### 3. Warlock SSH Server Not Running
**Check worker:**
```bash
# SSH to worker (via bastion)
ssh -J bastionuser@<bastion-ip> workeruser@10.10.0.3

# Check Warlock is running
curl localhost:3000/internal/ready
```

### "VM not found or unavailable"

**Symptom:**
```
Error: VM '29db6982...' not found or unavailable
Please check that the VM exists and is running.
Connection to <bastion-ip> closed.
```

**Causes & Solutions:**

#### 1. VM Doesn't Exist
**Check:**
```bash
curl http://<lb-ip>/vm/$VM_ID/location
# Should return: 404 if VM doesn't exist
```

**Fix:**  
Create the VM first:
```bash
curl -X POST http://<lb-ip>/vm ...
```

#### 2. Worker Unhealthy
**Check:**
```bash
curl http://<lb-ip>/internal/health
# Check: "healthy_workers" count
```

**Fix:**  
Workers heartbeat every 30s. Wait or check worker logs.

#### 3. Gateway Unreachable from Bastion
**Check from bastion:**
```bash
ssh bastionuser@<bastion-ip>
curl http://10.10.0.2:8080/internal/health
```

**Fix:**  
Verify VPC routing and gateway is running.

### Terraform Output Shows Wrong IP

**Symptom:**  
`terraform output bastion_public_ip` shows different IP than actual droplet.

**Cause:**  
Terraform state is stale (bastion was recreated).

**Fix:**
```bash
# Refresh terraform state
terraform refresh

# Or check actual IPs
doctl compute droplet list --format Name,PublicIPv4
```

## Advanced Topics

### Network Topology Details

#### VPC (10.10.0.0/16)
- **Subnet:** All droplets use same /16 subnet
- **Routing:** Internal routing via DigitalOcean VPC
- **DNS:** Private DNS for droplet names (not used currently)

#### Bastion Floating IP
- **Type:** DigitalOcean Floating IP (reserved, stable)
- **Assignment:** Attached to bastion droplet
- **Failover:** Can be reassigned to different droplet if needed
- **DNS:** Can point domain A record to floating IP

#### Load Balancer
- **Type:** DigitalOcean managed load balancer
- **Backend:** Routes to gateway droplet(s) tagged `gateway`
- **Health Check:** HTTP GET `/internal/health` on port 8080
- **SSL:** Optional, configured via `cert_id` variable
- **Scaling:** Automatically distributes to multiple gateway instances

### Security Model

#### Firewall Protection

**Network Security:**
- **Bastion:** SSH (port 22) open to internet - single hardened entry point
- **Gateway:** SSH (port 22) **blocked from internet** - only accepts connections from bastion private IP
- **Workers:** SSH (port 22) **blocked from internet** - only accepts connections from bastion private IP
- **VMs:** Not directly accessible - vsock console only, no network exposure

This firewall configuration ensures that internal infrastructure components cannot be directly accessed from the internet, reducing the attack surface to a single hardened SSH gateway (bastion).

#### Authentication Layers

**Layer 1: Bastion SSH**
- User's SSH key against `/etc/ssh/vm-authorized-keys`
- All VM users share same authorized_keys file
- NSS module validates username format (must be `vm-<uuid>`)

**Layer 2: Warlock SSH Server**
- User's SSH key (forwarded via agent) against VM's stored keys
- Each VM has its own `authorized_keys` list
- Keys stored in worker's memory (AppState)

**Layer 3: VM Guest**
- No authentication - auto-login as root
- Security enforced at Warlock layer
- vsock is private to host (not network accessible)

#### Trust Boundaries

```
┌─────────────────────────────────────────┐
│  User's Machine                         │
│  - Private key (never leaves)           │
│  - SSH agent (holds key in memory)      │
└──────────────┬──────────────────────────┘
               │ SSH with agent forwarding
               │ (encrypted)
┌──────────────▼──────────────────────────┐
│  Bastion (Public)                       │
│  - No user data stored                  │
│  - Proxies connections only             │
│  - Agent forwarding (transient)         │
└──────────────┬──────────────────────────┘
               │ Private VPC
               │ (encrypted)
┌──────────────▼──────────────────────────┐
│  Worker (Private)                       │
│  - VM metadata (authorized_keys)        │
│  - Validates user's key                 │
│  - No key storage needed                │
└──────────────┬──────────────────────────┘
               │ vsock (local, not network)
┌──────────────▼──────────────────────────┐
│  VM Guest (Isolated)                    │
│  - No network access to host            │
│  - Trusts vsock connections             │
│  - No authentication layer              │
└─────────────────────────────────────────┘
```

### Multiple VMs

**Managing Multiple Connections:**

```bash
# Create multiple VMs
for i in {1..3}; do
  VM_JSON=$(curl -s -X POST http://$LB_IP/vm \
    -H "Content-Type: application/json" \
    -d "{\"vcpus\":1,\"memory_mb\":128,\"ssh_keys\":[\"$(cat ~/.ssh/id_ed25519.pub)\"]}")
  
  VM_ID=$(echo "$VM_JSON" | jq -r '.id')
  echo "Created VM $i: $VM_ID"
done

# List all VMs
curl http://$LB_IP/internal/health | jq .
```

**SSH to specific VM:**
```bash
# Option 1: By VM ID
ssh vm-29db6982-33b3-4829-a046-7d774c4933eb@<bastion-ip>

# Option 2: Save VM ID in variable
VM_ID="29db6982-33b3-4829-a046-7d774c4933eb"
ssh vm-$VM_ID@<bastion-ip>
```

**SSH Config for Convenience:**
```bash
# ~/.ssh/config
Host vm-*
  User %h
  HostName <bastion-ip>
  ForwardAgent yes
  StrictHostKeyChecking no
  UserKnownHostsFile /dev/null
  LogLevel ERROR

# Usage:
ssh vm-29db6982-33b3-4829-a046-7d774c4933eb
# Automatically uses bastion IP
```

### Worker Direct Access

**Bypass Gateway (Advanced):**

You can SSH directly to worker's Warlock SSH port (if you know which worker):

```bash
# From bastion
ssh bastionuser@<bastion-ip>

# Inside bastion
ssh vm-29db6982...@10.10.0.3 -p 2222
```

This skips the gateway lookup but requires knowing which worker hosts the VM.

## FAQ

### Q: Why do I need `ssh-add`?

**A:** SSH agent forwarding requires keys to be **loaded in the agent**. The `-i` flag only uses the key for the immediate connection but doesn't forward it through the chain. Since your connection goes bastion → worker → VM, the key must be forwarded.

### Q: Why two different IPs for SSH vs API?

**A:** 
- **Bastion IP:** Dedicated SSH gateway, stable floating IP, single purpose
- **Load Balancer IP:** HTTP(S) endpoint, can have SSL certificate, can have domain name, scales gateway instances

This separation improves security (SSH isolated) and scalability (API can scale).

### Q: Why am I automatically root?

**A:** The VM guest OS is configured for minimal setup. Authentication happens at the Warlock SSH layer, so once you're authenticated, the VM trusts the connection and provides immediate root access via `/bin/bash -l`.

### Q: Can I use a different user inside VMs?

**A:** Not currently. All VMs use root login. Multi-user support inside VMs is planned for the future, which would require:
- cloud-init to provision users
- PAM configuration in guest OS
- Per-user authorized_keys management

### Q: What if I lose access to my SSH key?

**A:** You'll need to delete and recreate the VM with a new key. There's no password fallback since root password is cleared.

### Q: Can I disable the "chdir" warning?

**A:** Yes, but it's harmless. You could suppress it with SSH config:
```
Host vm-*
  LogLevel ERROR
```

### Q: Why does the proxy query the gateway?

**A:** The bastion doesn't know which worker hosts which VM. The gateway maintains a registry of VM locations updated by worker heartbeats. This allows VMs to move between workers (future feature) without updating bastion config.

### Q: How many VMs can I have per worker?

**A:** Limited by worker capacity. With 1 vCPU worker, you can have:
- 1 VM with 1 vCPU
- ~4 VMs with shared vCPU (not currently supported)

Memory is typically the limiting factor. Check capacity:
```bash
curl http://<lb-ip>/internal/health
```

### Q: What happens if a worker crashes?

**A:** 
- Gateway marks worker unhealthy after missed heartbeat (30s timeout)
- SSH connections to VMs on that worker will fail with "VM not found"
- VMs are not automatically migrated (future feature)

### Q: Can I SSH from VM to VM?

**A:** Not directly. VMs are isolated. You could:
1. SSH from your machine to VM1
2. Open another terminal
3. SSH from your machine to VM2

VM-to-VM networking is a planned feature.

### Q: How do I copy files to/from VMs?

**A:** Use `scp` or `rsync` with the same syntax:

```bash
# Copy TO VM
scp file.txt vm-$VM_ID@<bastion-ip>:/root/

# Copy FROM VM
scp vm-$VM_ID@<bastion-ip>:/root/file.txt ./

# Rsync (more efficient)
rsync -av ./dir/ vm-$VM_ID@<bastion-ip>:/root/dir/
```

### Q: Can I run commands without interactive SSH?

**A:** Yes:

```bash
# Run single command
ssh vm-$VM_ID@<bastion-ip> 'uname -a'

# Run multiple commands
ssh vm-$VM_ID@<bastion-ip> 'whoami && hostname && ip addr'

# Pipe output
ssh vm-$VM_ID@<bastion-ip> 'cat /etc/os-release' | grep VERSION
```

### Q: What's the VM's network configuration?

**A:** Each VM gets:
- Private IP: `172.16.0.2/24` (first VM), `172.16.1.2/24` (second), etc.
- NAT'd internet access via worker
- No inbound network access (no external ports)
- vsock for console (not network-based)

To reach services in VM from outside, you'd need port forwarding (not currently implemented).
