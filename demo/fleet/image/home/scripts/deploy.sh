#!/bin/bash
# Deploys a release of the shop front end.
set -euo pipefail
release=${1:?release}
rsync -a "releases/$release/" /var/www/shop/
sudo systemctl reload nginx
