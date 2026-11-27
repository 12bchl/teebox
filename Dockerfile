# slim: its dpkg path-excludes drop /usr/share/{doc,man,...} for every later apt layer (~190MB)
FROM debian:forky-slim

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt-get install -y --no-install-recommends \
        git \
        ripgrep \
        curl \
        ca-certificates \
        jq \
        less \
        openssh-client \
        sudo \
    && rm -rf /var/lib/apt/lists/*

# host NODE_EXTRA_CA_CERTS (ca/ is empty without one), before any HTTPS step. Not appended
# to the bundle: a later ca-certificates reconfigure regenerates it and drops the append.
COPY ca/ /usr/local/share/ca-certificates/
ARG EXTRA_CA=
RUN if [ -n "$EXTRA_CA" ]; then \
        openssl x509 -in /usr/local/share/ca-certificates/extra-ca.crt -noout -subject \
            || { echo "teebox: NODE_EXTRA_CA_CERTS is not valid PEM" >&2; exit 1; }; \
        update-ca-certificates; \
    fi
# Debian curl/git/openssl/go read the system store already; node and python
# requests ship their own roots.
ENV NODE_EXTRA_CA_CERTS=${EXTRA_CA:+/usr/local/share/ca-certificates/extra-ca.crt} \
    REQUESTS_CA_BUNDLE=/etc/ssl/certs/ca-certificates.crt

RUN curl -fsSL https://deb.nodesource.com/setup_22.x | bash - \
    && apt-get install -y --no-install-recommends nodejs \
    && rm -rf /var/lib/apt/lists/*

# no buildx plugin: nested builds can't use BuildKit
ARG DOCKER_CLI_VERSION=29.8.0
RUN curl -fsSL "https://download.docker.com/linux/static/stable/x86_64/docker-${DOCKER_CLI_VERSION}.tgz" \
        | tar -xz -C /tmp \
    && mv /tmp/docker/docker /usr/local/bin/docker \
    && rm -rf /tmp/docker

RUN apt-get update && apt-get install -y --no-install-recommends \
        build-essential cmake pkg-config python3 python3-pip \
    && pip3 install --no-cache-dir --break-system-packages conan \
    && rm -rf /var/lib/apt/lists/*

ARG GO_VERSION=latest
RUN set -eux; \
    v="$GO_VERSION"; \
    if [ "$v" = latest ]; then v="$(curl -fsSL https://go.dev/VERSION?m=text | head -1)"; else v="go$v"; fi; \
    curl -fsSL "https://go.dev/dl/${v}.linux-amd64.tar.gz" | tar -C /usr/local -xz \
    && /usr/local/go/bin/go version \
    && rm -rf /usr/local/go/test /usr/local/go/api /usr/local/go/doc  # ~29MB; toolchain self-tests + `go tool api` data
ENV GOPATH=/home/agent/go \
    PATH=/usr/local/go/bin:/home/agent/go/bin:$PATH

# agent last of the heavy layers: bumps miss only this, other agents share all above
ARG AGENT_PKG
RUN test -n "$AGENT_PKG" \
    && npm install -g "$AGENT_PKG" \
    && npm cache clean --force

# user last: a different host uid reuses every heavy layer
ARG UID=1000
ARG GID=1000
RUN groupadd -g ${GID} agent \
    && useradd -m -u ${UID} -g ${GID} -s /bin/bash agent \
    && echo 'agent ALL=(ALL) NOPASSWD:ALL' > /etc/sudoers.d/agent \
    && chmod 0440 /etc/sudoers.d/agent

# /home/agent is the home volume mountpoint: image content seeds only fresh volumes,
# so add nothing there (use apply_home)
USER agent
ENV HOME=/home/agent \
    LANG=C.UTF-8

# bind-mounted by the wrapper, so edits never rebuild
ENTRYPOINT ["/opt/teebox/entrypoint.sh"]
