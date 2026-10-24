#!/bin/bash
# Copyright (c) 2026 Unofficial Sakura macOS port contributors
# SPDX-License-Identifier: Zlib
# Copy a bounded source snapshot without touching the original checkout/history.
set -euo pipefail
source_root="$(cd "$(dirname "$0")/.." && pwd)"
mkdir -p "$source_root/build"
snapshot_dir="$(mktemp -d "$source_root/build/macos-public-source.XXXXXX")"
cd "$source_root"
rsync -aR --exclude='.DS_Store' --exclude='._*' --exclude='__pycache__/' --exclude='*.pyc' \
  LICENSE LICENSE.macos NOTICE.md README.md README.en.md CONTRIBUTING.md SECURITY.md \
  THIRD_PARTY_NOTICES.md sakura_editor_macos_port_design.md \
  core app platform/mac ui/mac tests/portable tests/mac tests/performance cmake \
  docs/macos-development.md docs/ASSET_PROVENANCE.md docs/RELEASING.md \
  tools/check_macos_publication.py tools/export_macos_snapshot.sh \
  .github/ISSUE_TEMPLATE .github/PULL_REQUEST_TEMPLATE.md \
  .github/workflows/macos.yml .github/workflows/release-macos.yml \
  "$snapshot_dir/"
cp "$source_root/cmake/MacSnapshotRoot.txt" "$snapshot_dir/CMakeLists.txt"
cp "$source_root/cmake/MacSnapshot.gitignore" "$snapshot_dir/.gitignore"
python3 "$snapshot_dir/tools/check_macos_publication.py" --mac-snapshot >&2
printf '%s\n' "$snapshot_dir"
