#!/bin/bash
# Alibaba ECS init: create the test data path and make sure key-based root SSH works.
#   The key pair is written into root's authorized_keys by Alibaba itself; the
#   drop-in only pins the settings gendata relies on, in case the image changes
#   them. Ubuntu includes /etc/ssh/sshd_config.d/*.conf near the top of
#   sshd_config, and the first value read wins.
#   The root filesystem is grown to the whole system disk by cloud-init's growpart.
set -e

mkdir -p /etc/ssh/sshd_config.d
printf 'PermitRootLogin prohibit-password\nPubkeyAuthentication yes\n' > /etc/ssh/sshd_config.d/99-cm-centipede.conf

mkdir -p "${data_path}"
chmod 755 "${data_path}"

systemctl restart ssh 2>/dev/null || systemctl restart sshd 2>/dev/null || true
