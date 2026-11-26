#!/bin/bash
# Starts one demo server. The hostname picks the role; web-01 also gets the incident.
# up.sh mounts /keys/host (this server's host key), /keys/authorized_keys (the client's public key)
# and, on web-01, /seed (the logs gen_logs.py wrote).
set -e
install -m 600 /keys/host/host_key /etc/ssh/ssh_host_ed25519_key
install -m 644 /keys/host/host_key.pub /etc/ssh/ssh_host_ed25519_key.pub
install -m 644 /keys/authorized_keys /etc/ssh/authorized_keys_demo
role=$(hostname)
printf '\n  %s · %s\n\n' "$role" "${ROLE_TEXT:-production}" > /etc/motd
if [ "$role" = "web-01" ]; then
  # /var is its own small ext4 volume, as on a real server with LVM, so it can fill up while / has room.
  # It is a file on a loop device under a device-mapper target, which is why web-01 runs --privileged.
  # The kernel names are ours alone (reachly-demo-var, /.reachly-demo/var.img); the node is called
  # /dev/mapper/vg0-var so df shows what a real server would.
  dm=reachly-demo-var img=/.reachly-demo/var.img
  # A volume left by an earlier run that did not clean up is still known to the kernel: let it go first.
  dmsetup remove --retry "$dm" 2>/dev/null || true
  losetup -a | grep -F "$img" | cut -d: -f1 | xargs -r -n1 losetup -d 2>/dev/null || true
  mkdir -p "$(dirname "$img")" && truncate -s 720M "$img"
  loop=$(losetup -f --show "$img")
  mkfs.ext4 -q -L var "$loop"
  dmsetup create "$dm" --noudevsync --table "0 $(blockdev --getsz "$loop") linear $loop 0"
  mkdir -p /dev/mapper && rm -f /dev/mapper/vg0-var
  mknod /dev/mapper/vg0-var b $(dmsetup info -c --noheadings -o major,minor "$dm" | tr ':' ' ')
  mount /dev/mapper/vg0-var /mnt && cp -a /var.dist/. /mnt/ && umount /mnt
  mount /dev/mapper/vg0-var /var && rm -rf /var.dist
  # Both go away on their own once the container stops and /var is unmounted, so nothing is left in the kernel.
  dmsetup remove --deferred "$dm"
  losetup -d "$loop"
  install -d -o www-data -g adm -m 755 /var/log/nginx
  cp /seed/logrotate.status /var/lib/logrotate/status
  cp /seed/error.log /seed/access.log.1 /seed/access.log.2.gz /seed/access.log.3.gz /var/log/nginx/
  cp /seed/orders-api.log /var/log/shop/orders-api.log
  while read -r order ts; do echo "{\"order\":\"$order\",\"items\":2}" > /var/lib/shop/orders/$order.json; touch -d "@$ts" /var/lib/shop/orders/$order.json; done < /seed/orders.txt
  chown -R www-data:www-data /var/lib/shop; chown -R www-data:adm /var/log/nginx /var/log/shop; chmod 640 /var/log/nginx/* /var/log/shop/*
  touch -d "16 days ago" /var/log/nginx/access.log.1 /var/log/nginx/access.log.2.gz /var/log/nginx/access.log.3.gz
  # Start the services first so the log lines carry nginx's real worker pid.
  setsid -f runuser -u www-data -- /usr/local/bin/orders-api >/dev/null 2>&1
  nginx; sleep 0.5
  worker=$(pgrep -u www-data -x nginx | head -1)
  sed -i "s/ 29#29: / $worker#$worker: /" /var/log/nginx/error.log
  # Old package downloads take the space the log doesn't, so the log fills the disk just before the newest lines.
  # Space left for www-data, which nginx and the orders API run as; ext4 keeps the rest for root.
  avail() { sync; runuser -u www-data -- df --output=avail -B1 /var | tail -1 | tr -d ' '; }
  archives=/var/cache/apt/archives
  extra=$(( $(avail) - $(stat -c %s /seed/access.log) + 8192 ))
  if [ "$extra" -gt 0 ]; then
    head -c $(( extra * 62 / 100 )) /dev/urandom > $archives/linux-firmware_20240318.git3b128b60-0ubuntu2.9_amd64.deb
    head -c $(( extra * 21 / 100 )) /dev/urandom > $archives/linux-modules-6.8.0-88-generic_6.8.0-88.89_amd64.deb
    head -c $(( extra * 17 / 100 )) /dev/urandom > $archives/linux-image-6.8.0-88-generic_6.8.0-88.89_amd64.deb
  fi
  # nginx writes as www-data, so the disk fills up to the blocks ext4 keeps for root.
  runuser -u www-data -- cp /seed/access.log /var/log/nginx/access.log 2>/dev/null || true
  # ext4 reports a full disk a little early while it still holds blocks back, and can give some back after a sync:
  # carry on from where the copy stopped until nothing is left. Should the log run out first, the package cache takes
  # the last blocks. Either way not one block is free, so no order can be saved.
  for _ in $(seq 1 10); do
    [ "$(avail)" -gt 0 ] || break
    runuser -u www-data -- bash -c 'tail -c +$(( $(stat -c %s /var/log/nginx/access.log) + 1 )) /seed/access.log >> /var/log/nginx/access.log' 2>/dev/null || true
  done
  for _ in 1 2 3; do
    left=$(avail)
    [ "$left" -gt 0 ] || break
    head -c "$left" /dev/urandom >> $archives/linux-image-6.8.0-88-generic_6.8.0-88.89_amd64.deb || true
  done
  [ "$(avail)" = 0 ] || echo "warning: /var still has $(avail) bytes free for www-data; checkout may not fail" >&2
  touch -d "23 days ago" $archives/*.deb 2>/dev/null || true
  chmod 640 /var/log/nginx/access.log
  touch -d "50 minutes ago" /var/log/nginx/access.log /var/log/nginx/error.log; touch -d "$(tail -1 /var/log/shop/orders-api.log | cut -c1-19) UTC" /var/log/shop/orders-api.log
fi
if [ "$role" = "build-box" ]; then
  mkdir -p /home/deploy/.cache/pip /home/deploy/builds
  head -c 300M /dev/zero > /home/deploy/.cache/pip/wheels.tar; head -c 120M /dev/zero > /home/deploy/builds/app-1.4.2.tar
  chown -R deploy:deploy /home/deploy
fi
exec /usr/sbin/sshd -D -e
