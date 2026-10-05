#!/usr/bin/env bash
set -euo pipefail
repo_root="$(cd "$(dirname "$0")/../.." && pwd)"
source_commit=5406950b02c102fadb917177d4c7b37615f86340
artifact_id="$(gh api 'repos/rustdesk/rustdesk/actions/artifacts?name=bridge-artifact&per_page=100' \
  --jq ".artifacts[] | select(.workflow_run.head_sha == \"$source_commit\" and .expired == false) | .id" | head -1)"
if [[ -z "$artifact_id" ]]; then
  echo 'The matching upstream bridge artifact has expired. Regenerate it using .github/workflows/bridge.yml at the pinned source commit.' >&2
  exit 1
fi
archive="$(mktemp -t rustdesk-bridge)"
trap 'rm -f "$archive"' EXIT
gh api "repos/rustdesk/rustdesk/actions/artifacts/$artifact_id/zip" > "$archive"
unzip -o "$archive" -d "$repo_root"
