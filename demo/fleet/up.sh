#!/bin/bash
# up.sh: starts the four servers from Reachly's recorded demo (bastion, web-01, db-01, build-box), with the incident
# set up on web-01: log rotation has been off for 15 days, the nginx access log has filled /var, and checkout fails.
# Run it again for a fresh incident. down.sh removes the containers and the network it starts.
#
# Bastion port: 127.0.0.1:2200, or REACHLY_DEMO_PORT=2201 ./up.sh
set -euo pipefail
cd "$(dirname "$0")"
state="$(pwd)/.state"
port=${REACHLY_DEMO_PORT:-2200}
net=reachly-demo-net
label=reachly.demo
hosts=(bastion web-01 db-01 build-box)

for tool in docker ssh ssh-keygen python3 shasum; do
  command -v "$tool" >/dev/null || { echo "up.sh needs $tool." >&2; exit 1; }
done
docker info >/dev/null 2>&1 || { echo "Docker isn't running. Start Docker Desktop (or the Docker daemon) and run up.sh again." >&2; exit 1; }

# 1. The image, tagged with a hash of its files, so it is built when missing and again after an edit.
tag=$(cd image && find . -type f ! -name .DS_Store | LC_ALL=C sort | xargs shasum -a 256 | shasum -a 256 | cut -c1-12)
image=reachly-demo-fleet:$tag
if ! docker image inspect "$image" >/dev/null 2>&1; then
  echo "Building $image (a minute or two the first time)..."
  docker build -q -t "$image" image >/dev/null
fi

# 2. Keys: a host key per server and one client key. They are made once and kept in .state, so ssh and Reachly
#    keep trusting the servers across runs.
mkdir -p "$state/keys" && chmod 700 "$state"
[ -f "$state/id_ed25519" ] || ssh-keygen -q -t ed25519 -N '' -C reachly-demo -f "$state/id_ed25519"
for h in "${hosts[@]}"; do
  mkdir -p "$state/keys/$h"
  [ -f "$state/keys/$h/host_key" ] || ssh-keygen -q -t ed25519 -N '' -C "$h" -f "$state/keys/$h/host_key"
done

# 3. Clear the previous run. Only containers and a network carrying this demo's label are ever replaced, and
#    nothing is removed unless all of them are this demo's.
for h in "${hosts[@]}"; do
  name=reachly-demo-$h
  if docker container inspect "$name" >/dev/null 2>&1 &&
    [ "$(docker container inspect -f "{{index .Config.Labels \"$label\"}}" "$name")" != fleet ]; then
    echo "A container called $name exists and isn't from this demo, so up.sh leaves it alone. Rename or remove it first." >&2
    exit 1
  fi
done
if docker network inspect "$net" >/dev/null 2>&1 &&
  [ "$(docker network inspect -f "{{index .Labels \"$label\"}}" "$net")" != fleet ]; then
  echo "A network called $net exists and isn't from this demo, so up.sh leaves it alone. Remove it first." >&2
  exit 1
fi
for h in "${hosts[@]}"; do
  docker rm -f "reachly-demo-$h" >/dev/null 2>&1 || true
done
if (echo >"/dev/tcp/127.0.0.1/$port") 2>/dev/null; then
  echo "Port $port on 127.0.0.1 is in use. Pick another one: REACHLY_DEMO_PORT=2201 $0" >&2
  exit 1
fi

# 4. The client side: ssh_config, known_hosts and reachly-demo.reachly for File > Import... in Reachly.
python3 write_configs.py "$state" "$port"

# 5. Fresh logs for web-01. Their times are relative to now: the disk filled 50 minutes before this run.
echo "Writing web-01's logs (about 530 MB)..."
python3 gen_logs.py "$state/logs" >/dev/null

# 6. The network and the servers.
docker network inspect "$net" >/dev/null 2>&1 || docker network create --label "$label=fleet" "$net" >/dev/null

run() { # run HOST "ROLE TEXT" [more docker run options]
  local h=$1 role=$2
  shift 2
  docker run -d --name "reachly-demo-$h" --hostname "$h" --label "$label=fleet" \
    --network "$net" --network-alias "$h" -e ROLE_TEXT="$role" \
    -v "$state/keys/$h:/keys/host:ro" -v "$state/id_ed25519.pub:/keys/authorized_keys:ro" \
    "$@" "$image" >/dev/null
}
echo "Starting bastion, web-01, db-01 and build-box..."
# Only the bastion publishes a port, on 127.0.0.1; the others are reached through it by name.
run bastion "jump host" -p "127.0.0.1:$port:22"
# web-01 runs --privileged for one reason: its /var is a small ext4 volume of its own, on a loop device under
# device-mapper (see entrypoint.sh), so /var can fill up while / still has room, as on the real server. That needs
# the loop and device-mapper devices, which an unprivileged container can't use. No other server gets it.
run web-01 "production · nginx" --privileged -v "$state/logs:/seed:ro"
run db-01 "production · database"
run build-box "lab · CI runner"

# 7. Wait until each server takes the key through the bastion. web-01 takes longest: it fills its disk before sshd starts.
for h in "${hosts[@]}"; do
  for try in $(seq 1 90); do
    ssh -F "$state/ssh_config" -o BatchMode=yes -o ConnectTimeout=5 "$h" true 2>/dev/null && break
    if [ "$(docker container inspect -f '{{.State.Running}}' "reachly-demo-$h")" != true ] || [ "$try" = 90 ]; then
      echo "reachly-demo-$h didn't come up. The end of its log:" >&2
      docker logs --tail 30 "reachly-demo-$h" >&2
      exit 1
    fi
    sleep 2
  done
done

cat <<EOF

The demo fleet is up.
  bastion     127.0.0.1:$port, user jump
  web-01      through the bastion, user deploy. /var is full and checkout fails.
  db-01       through the bastion, user deploy
  build-box   through the bastion, user deploy

From a terminal:  ssh -F "$state/ssh_config" web-01
In Reachly:       File > Import... (Shift-Command-O), choose "$state/reachly-demo.reachly"
Then ask the question in demo/README.md. When you're done: $(pwd)/down.sh
EOF
