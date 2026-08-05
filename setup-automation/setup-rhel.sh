#!/bin/bash
USER=rhel

echo "Adding wheel" > /root/post-run.log
usermod -aG wheel rhel

echo "Setup build host for operations lab" > /tmp/progress.log
chmod 666 /tmp/progress.log

# Set up libvirt
systemctl enable --now libvirtd
sed -i 's/hosts:\s\+ files/& libvirt libvirt_guest/' /etc/nsswitch.conf

# Set up registry authentication
mkdir -p ~/.config/containers
cat <<EOF> ~/.config/containers/auth.json
{
    "auths": {
      "registry.redhat.io": {
        "auth": "${REGISTRY_PULL_TOKEN}"
      }
    }
  }
EOF

# Pull needed images
BOOTC_RHEL_VER=10.1
podman pull registry.redhat.io/rhel10/rhel-bootc:$BOOTC_RHEL_VER
podman pull registry.redhat.io/rhel10/bootc-image-builder:$BOOTC_RHEL_VER

# Generate SSH key
ssh-keygen -t ed25519 -f ~/.ssh/${GUID}key -N '' -C "Lab SSH Key"

# Create config.toml
cat <<EOF> /root/config.toml
[[customizations.user]]
name = "core"
password = "redhat"
groups = ["wheel"]
key = "$(cat ~/.ssh/${GUID}key.pub)"
EOF

# Build and deploy the operations VM with base image
cd ~
podman run --rm --privileged --security-opt label=type:unconfined_t \
  --volume ./config.toml:/config.toml \
  --volume /var/lib/containers/storage:/var/lib/containers/storage \
  --volume .:/output \
  registry.redhat.io/rhel10/bootc-image-builder:10.1 \
  --type qcow2 \
  registry.redhat.io/rhel10/rhel-bootc:$BOOTC_RHEL_VER

cp qcow2/disk.qcow2 /var/lib/libvirt/images/ops-vm.qcow2

virt-install --name ops-vm \
  --disk /var/lib/libvirt/images/ops-vm.qcow2 \
  --import --memory 4096 --graphics none \
  --osinfo rhel10-unknown --noautoconsole --noreboot

virsh start ops-vm

# Wait script for ops-vm
cat <<'SCRIPT'> /root/.wait_for_ops_vm.sh
#!/bin/bash
echo "Waiting for VM 'ops-vm' to be running..."
VM_NAME=ops-vm
while true; do
    VM_STATE=$(virsh domstate "$VM_NAME" 2>/dev/null)
    if [[ "$VM_STATE" == "running" ]]; then
        break
    fi
    sleep 10
done
echo "Waiting for SSH to be available..."
while true; do
    if ping -c 1 -W 1 ${VM_NAME} &>/dev/null; then
        break
    fi
    sleep 5
done
ssh -i ~/.ssh/${GUID}key -o StrictHostKeyChecking=no core@${VM_NAME}
SCRIPT

chmod u+x /root/.wait_for_ops_vm.sh

# Export environment variables
echo "export GUID=${GUID}" >> /etc/profile.d/lab.sh
echo "export DOMAIN=${DOMAIN}" >> /etc/profile.d/lab.sh

echo "Operations lab setup complete" >> /tmp/progress.log
