#!/bin/bash
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")"

ARTIFACTS_DIR="${ARTIFACTS_DIR:-/local/nashcom-build-artifacts}"
CONTAINER_IMAGE="${CONTAINER_IMAGE:-hclcom/domino:capi}"

capi_container()
{
  docker run ${DOCKER_OPTIONS:-} --rm -w /build --name capi --hostname capi --entrypoint= \
    -v "$(pwd)":/build \
    -v "${ARTIFACTS_DIR}/latest":/depends \
    -u 0 \
    -e LOTUS=/opt/hcl/domino \
    -e Notes_ExecDirectory=/opt/hcl/domino/notes/latest/linux \
    -e LD_LIBRARY_PATH=/opt/hcl/domino/notes/latest/linux \
    -e INCLUDE=/opt/hcl/domino/notesapi/include \
    -e CURL_SRC_DIR=/depends/curl \
    -e OPENSSL_SRC_DIR=/depends/openssl \
    -e ZLIB_SRC_DIR=/depends/zlib \
    "${CONTAINER_IMAGE}" "$@"
}

if [ -z "${1:-}" ]; then
  DOCKER_OPTIONS=-it
  capi_container bash
else
  capi_container "$@"
fi
