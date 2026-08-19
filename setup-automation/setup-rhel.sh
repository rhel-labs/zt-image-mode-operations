#!/bin/bash
set -x
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
podman pull registry.redhat.io/rhel10/bootc-image-builder
podman pull quay.io/fedora/fedora-bootc:latest
podman pull ghcr.io/rhel-labs/im-workshop-ops:latest

# set up SSL for fully functioning registry
dnf install -y https://dl.fedoraproject.org/pub/epel/epel-release-latest-10.noarch.rpm
dnf install -y certbot

CERT_DIR="/etc/letsencrypt/live/registry-${GUID}.${DOMAIN}"
CERT_MAX_RETRIES=3
CERT_RETRY=0
while [ $CERT_RETRY -lt $CERT_MAX_RETRIES ]; do
    set +x
    certbot certonly --eab-kid "${ZEROSSL_EAB_KEY_ID}" --eab-hmac-key "${ZEROSSL_HMAC_KEY}" --server "https://acme.zerossl.com/v2/DV90" --standalone --preferred-challenges http -d registry-"${GUID}"."${DOMAIN}" --non-interactive --agree-tos -m trackbot@instruqt.com -v
    rm -f /var/log/letsencrypt/letsencrypt.log
    set -x

    if [ -f "$CERT_DIR/fullchain.pem" ] && [ -f "$CERT_DIR/privkey.pem" ]; then
        echo "SSL certificates obtained successfully" >> /tmp/progress.log
        break
    fi

    CERT_RETRY=$((CERT_RETRY + 1))
    echo "Certificate attempt $CERT_RETRY of $CERT_MAX_RETRIES failed, retrying in 15 seconds..." >> /tmp/progress.log
    sleep 15
done

if [ ! -f "$CERT_DIR/fullchain.pem" ] || [ ! -f "$CERT_DIR/privkey.pem" ]; then
    echo "FATAL: Failed to obtain SSL certificates after $CERT_MAX_RETRIES attempts" >> /tmp/progress.log
    echo "FATAL: Registry cannot start without TLS certificates. Aborting setup." >> /tmp/progress.log
    exit 1
fi

# set up http based auth for registry
mkdir .auth
podman run --rm --entrypoint htpasswd quay.io/hummingbird/httpd:2 -Bbn core redhat > .auth/htpasswd
podman rmi quay.io/hummingbird/httpd:2

# run a local registry with authentication and the provided certs
podman run --privileged -d \
  --name registry \
  -p 443:5000 \
  -v `pwd`/.auth:/auth:Z  \
  -e "REGISTRY_AUTH=htpasswd" \
  -e "REGISTRY_AUTH_HTPASSWD_REALM=Registry Realm" \
  -e "REGISTRY_AUTH_HTPASSWD_PATH=/auth/htpasswd" \
  -v /etc/letsencrypt/live/registry-"${GUID}"."${DOMAIN}"/fullchain.pem:/certs/fullchain.pem \
  -v /etc/letsencrypt/live/registry-"${GUID}"."${DOMAIN}"/privkey.pem:/certs/privkey.pem \
  -e REGISTRY_HTTP_TLS_CERTIFICATE=/certs/fullchain.pem \
  -e REGISTRY_HTTP_TLS_KEY=/certs/privkey.pem \
  quay.io/mmicene/registry:2

# Validate registry container is running
sleep 5
if ! podman ps --filter name=registry --format '{{.Names}}' | grep -q registry; then
    echo "FATAL: Registry container failed to start. Checking logs:" >> /tmp/progress.log
    podman logs registry >> /tmp/progress.log 2>&1
    exit 1
fi

# Validate registry is responding (401 = auth required = TLS and registry working)
REG_MAX_RETRIES=5
REG_RETRY=0
while [ $REG_RETRY -lt $REG_MAX_RETRIES ]; do
    HTTP_CODE=$(curl -sk -o /dev/null -w '%{http_code}' https://registry-${GUID}.${DOMAIN}/v2/ 2>/dev/null)
    if [ "$HTTP_CODE" = "401" ] || [ "$HTTP_CODE" = "200" ]; then
        echo "Registry is responding (HTTP $HTTP_CODE)" >> /tmp/progress.log
        break
    fi
    REG_RETRY=$((REG_RETRY + 1))
    echo "Registry not responding yet (HTTP $HTTP_CODE), retry $REG_RETRY of $REG_MAX_RETRIES..." >> /tmp/progress.log
    sleep 5
done

if [ $REG_RETRY -eq $REG_MAX_RETRIES ]; then
    echo "FATAL: Registry is not responding after $REG_MAX_RETRIES attempts. Aborting setup." >> /tmp/progress.log
    podman logs registry >> /tmp/progress.log 2>&1
    exit 1
fi

# Add name based resolution for internal IPs
echo "10.0.2.2 rhel.${GUID}.${DOMAIN}" >> /etc/hosts
echo "10.0.2.2 registry-${GUID}.${DOMAIN}" >> /etc/hosts
cp /etc/hosts ~/etc/hosts

# Generate SSH key
ssh-keygen -t ed25519 -f ~/.ssh/${GUID}key -N '' -C "Lab SSH Key"

podman login -u core -p redhat registry-${GUID}.${DOMAIN}
podman login -u core -p redhat registry-${GUID}.${DOMAIN} --authfile=/tmp/auth.json

#podman tag ghcr.io/rhel-labs/im-workshop-ops:latest registry-${GUID}.${DOMAIN}/bootc
#podman push registry-${GUID}.${DOMAIN}/bootc


cat << EOF > /tmp/Containerfile.lab
FROM ghcr.io/rhel-labs/im-workshop-ops:latest
COPY auth.json /etc/ostree/auth.json
EOF

pushd /tmp
podman build -t registry-${GUID}.${DOMAIN}/bootc -f Containerfile.lab
podman push registry-${GUID}.${DOMAIN}/bootc
rm /tmp/Containerfile.lab
popd


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
  registry-${GUID}.${DOMAIN}/bootc

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

# Clone the examples directory from the lab's git repo
EXAMPLE=examples
TMPDIR=/tmp/lab
git clone --single-branch --branch ${GIT_BRANCH:-main} --no-checkout --depth=1 --filter=tree:0 ${GIT_REPO} $TMPDIR
git -C $TMPDIR sparse-checkout set --no-cone /${EXAMPLE}
git -C $TMPDIR checkout
if [ -d $TMPDIR/${EXAMPLE} ]; then
    #podman login -u core -p redhat registry-${GUID}.${DOMAIN} --authfile=$TMPDIR/$EXAMPLE/auth.json
    mv /tmp/auth.json $TMPDIR/$EXAMPLE/auth.json
    cp -r $TMPDIR/${EXAMPLE} /root/${EXAMPLE}
    mv $TMPDIR/${EXAMPLE} ${EXAMPLE}
fi
rm -rf $TMPDIR

mkdir ~/scratch
git clone --single-branch --branch bootc https://github.com/rhel-labs/python-hostinfo.git /root/bootc-version
cp ~/examples/examples/auth.json ~/bootc-version/etc/ostree/


# Export environment variables
echo "export GUID=${GUID}" >> /etc/profile.d/lab.sh
echo "export DOMAIN=${DOMAIN}" >> /etc/profile.d/lab.sh

echo "Operations lab setup complete" >> /tmp/progress.log
