#!/bin/bash
# Download and extract RapidJSON 

set -euo pipefail
source /project/lib/common.sh
source /project/versions.env

curl -fsSL \
  https://github.com/Tencent/rapidjson/archive/refs/heads/master.tar.gz \
  -o /tmp/rapidjson.tar.gz

tar -xzf /tmp/rapidjson.tar.gz -C /tmp

mkdir -p /depends/rapidjson/include
cp -a /tmp/rapidjson-master/include/rapidjson /depends/rapidjson/include/

rm -rf /tmp/rapidjson.tar.gz /tmp/rapidjson-master

MARKER=/depends/rapidjson/.built-version
RAPID_JSON_VERSION="v1.1.0"
mark_built "${MARKER}" "${RAPID_JSON_VERSION}"

echo
