#!/bin/bash
# Azure VM init (custom_data, run by cloud-init as root): create the test data
# path, owned by the login account.
#   cloud-init has already created ${ssh_user} and written the generated key into
#   its authorized_keys, and grows the root filesystem to the whole OS disk, so
#   neither is done here. SFTP cannot sudo, which is why the path belongs to
#   ${ssh_user} rather than root.
set -e

mkdir -p "${data_path}"
chown "${ssh_user}:${ssh_user}" "${data_path}"
chmod 755 "${data_path}"
