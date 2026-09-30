# MEASUREMENT SPIKE (TASK-50 phase 4): the throwaway "host" playbooks/bundle-render.yml renders
# into. It only has to look enough like a docker_compose VM for la-compose and the ala-install
# roles to render: python for the modules, sudo for become, rsync for synchronize, cron and
# sysctl for the host-state tasks, the docker CLI + compose plugin for `docker compose config`
# (no daemon: it never runs a container), and the VM's users with the VM's uids so the bundle's
# owners match.
FROM python:3.11-slim-bookworm
RUN apt-get update && apt-get install -y --no-install-recommends \
      sudo git rsync curl ca-certificates gnupg acl cron iproute2 procps \
 && install -m 0755 -d /etc/apt/keyrings \
 && curl -fsSL https://download.docker.com/linux/debian/gpg -o /etc/apt/keyrings/docker.asc \
 && echo "deb [signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/debian bookworm stable" \
      > /etc/apt/sources.list.d/docker.list \
 && apt-get update && apt-get install -y --no-install-recommends docker-ce-cli docker-compose-plugin \
 && rm -rf /var/lib/apt/lists/*
RUN groupadd -g 999 docker && groupadd -g 1000 ubuntu && useradd -u 1000 -g 1000 -m -s /bin/bash ubuntu
# Host kernel settings (image-service's TCP keepalive) cannot be applied from an unprivileged
# container. They are host prep, not bundle content: log them and carry on.
RUN printf '#!/bin/sh\n/usr/sbin/sysctl "$@" 2>/dev/null || { echo "render: sysctl $* skipped" >&2; exit 0; }\n' \
      > /usr/local/sbin/sysctl && chmod +x /usr/local/sbin/sysctl
# The VMs run become as root with umask 027 (login.defs), so files no task gives a mode come out
# 0640/0750 there. Modules run through this interpreter to get the same.
RUN printf '#!/bin/sh\numask 027\nexec /usr/local/bin/python3 "$@"\n' > /usr/local/bin/python-render \
 && chmod +x /usr/local/bin/python-render
CMD ["sleep", "infinity"]
