#!/usr/bin/env bash

set -euo pipefail

usage() {
  cat <<'EOF'
Usage:
  ./package.sh
  ./package.sh --check

Build or verify the committed ZIP and TAR release artifacts from the current
bundle directory. Archives never serve as installation sources for bootstrap.
EOF
}

mode="build"
case "${1:-}" in
  "")
    ;;
  --check)
    mode="check"
    ;;
  --help | -h)
    usage
    exit 0
    ;;
  *)
    usage >&2
    exit 2
    ;;
esac

bundle_root="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
work_root="$(mktemp -d)"
trap 'rm -rf "$work_root"' EXIT
package_name="codex-claude-skills"
expected_root="$work_root/expected/$package_name"

mkdir -p "$expected_root"
cp -R \
  "$bundle_root/.agents" \
  "$bundle_root/.claude" \
  "$bundle_root/review-hooks" \
  "$bundle_root/scripts" \
  "$bundle_root/tests" \
  "$expected_root/"
cp \
  "$bundle_root/README.md" \
  "$bundle_root/LICENSE" \
  "$bundle_root/CLAUDE.md.codex-skills-snippet.md" \
  "$bundle_root/bootstrap.sh" \
  "$bundle_root/doctor.sh" \
  "$bundle_root/install.sh" \
  "$bundle_root/package.sh" \
  "$bundle_root/preferences.example.json" \
  "$expected_root/"

tar_path="$bundle_root/codex-claude-skills.tar.gz"
zip_path="$bundle_root/codex-claude-skills.zip"

if [ "$mode" = "build" ]; then
  tar -C "$work_root/expected" -czf "$tar_path" "$package_name"
  (
    cd "$work_root/expected"
    python3 -m zipfile -c "$zip_path" "$package_name"
  )
  echo "[package] rebuilt $(basename "$tar_path") and $(basename "$zip_path")"
  exit 0
fi

if [ ! -f "$tar_path" ] || [ ! -f "$zip_path" ]; then
  echo "[package] release archives are missing" >&2
  exit 1
fi

mkdir -p "$work_root/tar" "$work_root/zip"
tar -C "$work_root/tar" -xzf "$tar_path"
python3 -m zipfile -e "$zip_path" "$work_root/zip"

if ! diff -qr "$expected_root" "$work_root/tar/$package_name"; then
  echo "[package] TAR archive is stale" >&2
  exit 1
fi

if ! diff -qr "$expected_root" "$work_root/zip/$package_name"; then
  echo "[package] ZIP archive is stale" >&2
  exit 1
fi

echo "[package] release archives match the bundle"
