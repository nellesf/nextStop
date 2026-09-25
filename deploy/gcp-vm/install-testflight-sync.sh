#!/usr/bin/env bash
set -euo pipefail

if [[ $(id -u) -ne 0 ]]; then
  echo "Run this installer on the staging VM with sudo." >&2
  exit 1
fi

source_directory=$(cd "$(dirname "$0")" && pwd)
destination=/opt/nextstop/operations/testflight-sync

# Credentials are provisioned separately and are never copied from the repository.
test -f /etc/nextstop/testflight-sync.json
/usr/bin/python3 -c 'import cryptography' || {
  echo "Install the Ubuntu python3-cryptography package before activation." >&2
  exit 1
}

# Complete the read-only Apple check before installing/enabling the timer.
timeout 150 /usr/bin/python3 "$source_directory/read-testflight-builds.py" >/dev/null

# A timer upgrade must not replace scripts while its previous run is applying
# or rolling back a change. Stop new starts, then wait for that bounded run.
timer_was_active=false
if systemctl is-active --quiet nextstop-testflight-sync.timer; then
  timer_was_active=true
  systemctl stop nextstop-testflight-sync.timer
fi
restore_timer() {
  if [[ "$timer_was_active" == true ]]; then
    systemctl start nextstop-testflight-sync.timer
  fi
}
trap restore_timer EXIT
deadline=$((SECONDS + 520))
while [[ $(systemctl show nextstop-testflight-sync.service --property=ActiveState --value) == activating ]]; do
  if (( SECONDS >= deadline )); then
    echo "The existing sync is still active; retry installation after it completes." >&2
    exit 1
  fi
  sleep 2
done

install -d -m 755 "$destination"
for script in read-testflight-builds.py allow-testflight-build.py sync-testflight-builds.py; do
  install -m 644 "$source_directory/$script" "$destination/$script"
done
install -m 644 "$source_directory/nextstop-testflight-sync.service" /etc/systemd/system/
install -m 644 "$source_directory/nextstop-testflight-sync.timer" /etc/systemd/system/
systemctl daemon-reload
systemctl start nextstop-testflight-sync.service
systemctl enable --now nextstop-testflight-sync.timer
timer_was_active=false
systemctl is-active nextstop-testflight-sync.timer
