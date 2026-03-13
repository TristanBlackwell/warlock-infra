# VM SSH Access Workaround

> **⚠️ HISTORICAL DOCUMENT**
> 
> This document describes the original problem and workaround solutions.
> **The NSS module (Option 2) has been implemented** and is now the production solution.
> 
> See [NSS-MODULE-IMPLEMENTATION.md](NSS-MODULE-IMPLEMENTATION.md) for current implementation details.

## Issue

SSH to Firecracker VMs via `ssh vm-<uuid>@bastion` doesn't work because:
1. SSH requires users to exist in `/etc/passwd` before attempting authentication
2. We can't pre-create all possible VM IDs
3. `AuthorizedKeysCommand` only runs AFTER user validation

## Workaround Options

### Option 1: Use wrapper script (Recommended for now)

Create a local alias:
```bash
# Add to ~/.bashrc or ~/.zshrc
vm-ssh() {
  local vm_id="$1"
  ssh -i ~/.ssh/warlock_ed25519 bastionuser@129.212.202.200 -t "/usr/local/bin/vm-ssh-direct $vm_id"
}

# Usage:
vm-ssh 03c3f47c-c865-48e8-8b50-5dcd5c642dce
```

Create `/usr/local/bin/vm-ssh-direct` on bastion:
```bash
#!/bin/bash
VM_ID="$1"
API_URL="http://10.10.0.2:8080"
LOCATION=$(curl -sf "$API_URL/vm/$VM_ID/location" || {
    echo "Error: VM '$VM_ID' not found" >&2
    exit 1
})
WORKER_IP=$(echo "$LOCATION" | jq -r '.worker_ip')
PORT=$(echo "$LOCATION" | jq -r '.port // 2222')
exec ssh -o StrictHostKeyChecking=no vm-$VM_ID@$WORKER_IP -p "$PORT"
```

### Option 2: NSS Module (Production solution)

Implement a custom NSS module that returns user info for any `vm-*` username:
- Install `libnss-extrausers` or create custom NSS module
- Configure `/etc/nsswitch.conf` to use it
- Allows `vm-*` users to be "created" dynamically

### Option 3: Pre-create users via API

When creating a VM via API, also call bastion to create the user:
```bash
# After creating VM
VM_ID="abc-123"
ssh bastionuser@bastion "sudo useradd -M -s /usr/local/bin/vm-ssh-proxy vm-$VM_ID"

# Then connect
ssh vm-$VM_ID@bastion
```

## Status

✅ **IMPLEMENTED**: Option 2 (NSS Module) has been implemented and deployed.

See [NSS-MODULE-IMPLEMENTATION.md](NSS-MODULE-IMPLEMENTATION.md) for:
- Complete implementation details
- Installation instructions
- Testing procedures
- Troubleshooting guide

## Historical Recommendation

~~For production, implement Option 2 (NSS module).~~
~~For testing/MVP, use Option 1 (wrapper script).~~

**Current Status**: NSS module is production-ready and deployed via cloud-init.
