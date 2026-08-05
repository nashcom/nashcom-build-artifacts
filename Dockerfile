# nashcom-build-artifacts — static openssl/libcurl/zlib build environment
#
# Builds static openssl + libcurl + zlib against UBI9 (RHEL 9 ABI), for use
# in Domino C-API addins that need an independent, statically-linked HTTPS
# client (see docs/why-static-linking.md for why dynamic linking
# on Linux is not safe for this use case).
#
# This image is a build *environment*, not a multi-stage app build: the
# actual compiling happens via `docker run` with /project (build scripts)
# and /depends (artifact output) bind-mounted from the host. See build.sh.
#
# Usage:
#   docker build -t nashcom-build-artifacts:latest .
#   ./build.sh

FROM registry.access.redhat.com/ubi9:latest

RUN dnf install -y \
        gcc gcc-c++ glibc-static libstdc++-static make autoconf automake libtool xz pkgconf-pkg-config \
        openssl-devel zlib-devel libcurl-devel \
        perl-FindBin perl-IPC-Cmd perl-core \
    && dnf clean all

ARG UID=1000 GID=1000

RUN groupadd --gid $GID build && \
    useradd --uid $UID --gid build --shell /bin/bash --create-home build && \
    mkdir -p /depends /build && chown build:build /depends /build

USER build:build

WORKDIR /project

ENTRYPOINT ["/bin/bash"]
