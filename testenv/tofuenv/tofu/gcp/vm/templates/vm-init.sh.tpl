#!/bin/bash
# GCP VM init (metadata startup-script, run by the guest agent as root on every
# boot): create the test data path, owned by the login account.
#   The guest agent creates ${ssh_user} from the ssh-keys metadata, but on its own
#   schedule - the startup script may well run first. So the account is created
#   here when it is missing; the agent then only adds the key to it. The image
#   grows the root filesystem to the whole boot disk by itself. SFTP cannot sudo,
#   which is why the path belongs to ${ssh_user} rather than root.
set -e

if ! id -u "${ssh_user}" >/dev/null 2>&1; then
    useradd -m -s /bin/bash "${ssh_user}"
fi

mkdir -p "${data_path}"
chown "${ssh_user}:${ssh_user}" "${data_path}"
chmod 755 "${data_path}"
