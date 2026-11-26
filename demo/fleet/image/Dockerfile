# One image for all four demo servers; the container's hostname picks the role (see entrypoint.sh).
# No keys are baked in: up.sh mounts the host key and the client's public key at /keys when it starts a container.
FROM ubuntu:24.04
ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update && apt-get install -y --no-install-recommends openssh-server nginx procps iproute2 less curl logrotate sudo ca-certificates htop python3 dmsetup e2fsprogs util-linux \
 && rm -rf /var/lib/apt/lists/* && mkdir -p /run/sshd \
 && useradd -m -s /bin/bash -G adm deploy && useradd -m -s /bin/bash jump \
 && echo 'deploy ALL=(ALL) NOPASSWD:ALL' > /etc/sudoers.d/deploy && passwd -d deploy >/dev/null && passwd -l jump >/dev/null \
 && sed -i 's/^#\?force_color_prompt=.*/force_color_prompt=yes/' /home/deploy/.bashrc /home/jump/.bashrc \
 && rm -f /etc/update-motd.d/* /etc/legal
COPY sshd_demo.conf /etc/ssh/sshd_config.d/hardening.conf
COPY systemctl /usr/local/bin/systemctl
COPY journalctl /usr/local/bin/journalctl
COPY orders-api.py /usr/local/bin/orders-api
COPY logrotate-shop /etc/logrotate.d/shop
COPY shop.conf /etc/nginx/sites-available/shop.example.org
COPY home /home/deploy
# The shop, its orders API as a unit file, and no logrotate timer: that missing timer is the root cause of the incident.
RUN rm -f /etc/nginx/sites-enabled/default && ln -s /etc/nginx/sites-available/shop.example.org /etc/nginx/sites-enabled/ \
 && mkdir -p /var/www/shop /var/lib/shop/orders /var/log/shop && echo '<h1>Shop</h1>' > /var/www/shop/index.html \
 && chown -R www-data:www-data /var/lib/shop /var/log/shop && chown -R deploy:deploy /home/deploy \
 && rm -f /etc/systemd/system/timers.target.wants/logrotate.timer \
 && printf '[Unit]\nDescription=Shop orders API\nAfter=network.target\n\n[Service]\nUser=www-data\nExecStart=/usr/local/bin/orders-api\nRestart=always\n\n[Install]\nWantedBy=multi-user.target\n' > /usr/lib/systemd/system/orders-api.service \
 && cp -a /var /var.dist
COPY entrypoint.sh /entrypoint.sh
RUN chmod 755 /usr/local/bin/systemctl /usr/local/bin/journalctl /usr/local/bin/orders-api /entrypoint.sh && rm -f /etc/ssh/ssh_host_*
LABEL reachly.demo="fleet"
ENTRYPOINT ["/entrypoint.sh"]
