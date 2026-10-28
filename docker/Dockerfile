# A "fresh machine" for testing install.sh: a non-root user with sudo and only
# what the installer needs to start (curl, CA certificates). No git: CloudKit
# is downloaded as a tarball, like on a minimal server. Built by docker/run.sh.
#
# Targets:
#   fresh  nothing installed (docker-fresh)
#   deps   fresh + CloudKit's dependencies, installed by install.sh at build
#          time and cached until install.sh changes (docker-shell)
#
#   docker build -f docker/Dockerfile --build-context repo=. --target fresh -t cloudkit-dev docker
#   docker build ... --build-arg BASE_IMAGE=fedora:41 --build-arg USER_SHELL=/bin/zsh
#   docker build ... --target deps --build-arg DEPS=aws

ARG BASE_IMAGE=ubuntu:24.04
FROM ${BASE_IMAGE} AS fresh

ARG USER_NAME=dev
ARG USER_SHELL=/bin/bash

RUN set -eux; \
    pkgs="ca-certificates curl sudo"; \
    case "${USER_SHELL}" in */zsh) pkgs="$pkgs zsh" ;; esac; \
    if command -v apt-get > /dev/null; then \
      apt-get update; \
      DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends $pkgs; \
      rm -rf /var/lib/apt/lists/*; \
    elif command -v dnf > /dev/null; then \
      dnf install -y --setopt=install_weak_deps=False $pkgs; \
      dnf clean all; \
    else \
      echo "Unsupported base image: no apt-get or dnf" >&2; exit 1; \
    fi; \
    useradd -m -s "${USER_SHELL}" "${USER_NAME}"; \
    echo "${USER_NAME} ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/90-${USER_NAME}; \
    chmod 0440 /etc/sudoers.d/90-${USER_NAME}

COPY --chmod=0755 test-install.sh /usr/local/bin/ck-test-install

USER ${USER_NAME}
WORKDIR /home/${USER_NAME}
ENV SHELL=${USER_SHELL}

ENTRYPOINT ["ck-test-install"]
CMD ["shell"]

FROM fresh AS deps

ARG DEPS=all

# Only the dependency step runs: a stub main.sh makes the installer skip
# downloading CloudKit, and no rc file is touched, so the container still gets
# a clean CloudKit install. Caches and gcloud's backup copy are dropped to keep
# the image small.
COPY --from=repo install.sh /tmp/install.sh
RUN set -eux; \
    mkdir /tmp/ck-stub && touch /tmp/ck-stub/main.sh; \
    bash /tmp/install.sh "--${DEPS}" --yes --no-rc --no-setup --dir /tmp/ck-stub; \
    rm -rf /tmp/ck-stub; \
    sudo rm -rf /tmp/install.sh /var/lib/apt/lists/* /var/cache/dnf \
      /usr/lib/google-cloud-sdk/.install/.backup "$HOME/.cache"