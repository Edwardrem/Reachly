#!/bin/bash
# down.sh: removes the demo fleet's four containers and its network, and nothing else.
# .state keeps the keys and logs, so the next up.sh keeps the same host keys; delete .state to remove those too.
set -euo pipefail
label=reachly.demo
net=reachly-demo-net

for h in bastion web-01 db-01 build-box; do
  name=reachly-demo-$h
  docker container inspect "$name" >/dev/null 2>&1 || continue
  if [ "$(docker container inspect -f "{{index .Config.Labels \"$label\"}}" "$name")" = fleet ]; then
    docker rm -f "$name" >/dev/null && echo "Removed container $name"
  else
    echo "Left container $name alone: it isn't from this demo." >&2
  fi
done
if docker network inspect "$net" >/dev/null 2>&1; then
  if [ "$(docker network inspect -f "{{index .Labels \"$label\"}}" "$net")" = fleet ]; then
    docker network rm "$net" >/dev/null && echo "Removed network $net"
  else
    echo "Left network $net alone: it isn't from this demo." >&2
  fi
fi
images=$(docker image ls -q reachly-demo-fleet | sort -u | tr '\n' ' ')
[ -z "$images" ] || echo "The image stays, so the next up.sh starts quickly. To free its space: docker image rm $images"
