#!/usr/bin/env bash
set -euo pipefail

repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_dir"

image_name="dingtalk-cp-bot:openclaw-check"
docker build --quiet --network host -t "$image_name" . >/dev/null

docker run --rm --network host \
  --env-file "$repo_dir/.env" \
  -e COMMON_DIR=/opt/common \
  -e TZ=Asia/Shanghai \
  -v "$repo_dir/downloads:/app/downloads" \
  -v "$repo_dir/files:/app/files:ro" \
  -v "${COMMON_DIR:-/home/yida/Project/automation}:/opt/common:ro" \
  "$image_name" \
  python openclaw_check.py "$@"
