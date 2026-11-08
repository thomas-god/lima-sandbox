#!/usr/bin/env bash
# build-image.sh
set -euo pipefail
limactl delete -f builder 2>/dev/null || true
limactl start --tty=false --name=builder ./lima-builder.yaml
limactl shell builder sudo cloud-init clean --logs
limactl stop builder
DIR=$(limactl list builder --format '{{.Dir}}')
sudo mkdir -p /srv/lima-images
sudo qemu-img convert -O qcow2 "$DIR/disk" /srv/lima-images/base.qcow2
sudo chmod 0444 /srv/lima-images/base.qcow2
