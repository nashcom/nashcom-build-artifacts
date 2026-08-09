#!/bin/bash
# Orchestrator: builds zlib, then openssl, then curl (in that dependency
# order) into /depends, and writes /depends/BUILD_INFO.txt recording what
# was actually built. Run inside the container via the host-side build.sh,
# or directly: docker run ... nashcom-build-artifacts:latest /project/build.sh

set -euo pipefail
source /project/lib/common.sh
source /project/versions.env

mkdir -p /depends

header "Build starting: curl ${CURL_VERSION}, openssl ${OPENSSL_VERSION}, zlib ${ZLIB_VERSION}"

header "Building zlib ${ZLIB_VERSION}"
bash /project/lib/build-zlib.sh

header "Building openssl ${OPENSSL_VERSION}"
bash /project/lib/build-openssl.sh

header "Building curl ${CURL_VERSION}"
bash /project/lib/build-curl.sh

header "Building RapidJSON"
bash /project/lib/build_rapid_json.sh

cat > /depends/BUILD_INFO.txt <<EOF
CURL_VERSION="${CURL_VERSION}"
OPENSSL_VERSION="${OPENSSL_VERSION}"
ZLIB_VERSION="${ZLIB_VERSION}"
BUILT_AT="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
BUILT_ON="$(uname -a)"
BUILT_NPROC="$(nproc)"
BASE_IMAGE="registry.access.redhat.com/ubi9:latest"
EOF

header "Build complete, artifacts in /depends"
