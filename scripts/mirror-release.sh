#!/usr/bin/env bash
# mirror-release.sh — create the immutable public release v<version> from an
# already VERIFIED kioskd candidate subset (kioskit#137 AC-4, AC-17).
#
# Runs mirror-guard.sh first, so a second run for a version refuses without
# touching the existing tag. Creates the tag at --target (this repository's
# commit) together with the release, uploading exactly the five public files.
# Never --clobber, never moves a tag. With immutable releases enabled, the
# published assets and tag cannot change afterwards.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

repo="" version="" dir="" target=""
while [ $# -gt 0 ]; do
  case "$1" in
    --repo) repo="${2:-}" && shift 2 ;;
    --version) version="${2:-}" && shift 2 ;;
    --dir) dir="${2:-}" && shift 2 ;;
    --target) target="${2:-}" && shift 2 ;;
    *)
      echo "mirror-release: usage: mirror-release.sh --repo OWNER/NAME --version X.Y.Z --dir VERIFIED_DIR --target SHA" >&2
      exit 2
      ;;
  esac
done
printf '%s' "$target" | grep -Eqx '[0-9a-f]{40}' || {
  echo "mirror-release: --target is not a full commit SHA: $target" >&2
  exit 2
}
bash "$HERE/mirror-guard.sh" --repo "$repo" --version "$version"

bin="kioskit-publish_${version}_linux_amd64"
files=("$dir/$bin" "$dir/$bin.sig" "$dir/release-candidate.json" "$dir/release-candidate.json.sig" "$dir/SHA256SUMS")
for f in "${files[@]}"; do
  [ -f "$f" ] || {
    echo "mirror-release: missing verified file: $f" >&2
    exit 1
  }
done
source_sha="$(jq -r '.source_sha' "$dir/release-candidate.json")"
sha="$(jq -r '.artifacts[] | select(.id == "linux-amd64-kioskit-publish") | .sha256' "$dir/release-candidate.json")"
notes="$(mktemp)"
trap 'rm -f "$notes"' EXIT
cat >"$notes" <<EOF
kioskit-publish $version for linux/amd64, mirrored unchanged from the signed
kioskd release v$version (source commit $source_sha).

- \`$bin\` sha256 \`$sha\`
- \`$bin.sig\`: ed25519-detached-v1 signature (key \`kioskitd-2026-01\`)
- \`release-candidate.json\` + \`.sig\`: kioskd's signed release manifest
- \`SHA256SUMS\`: kioskd's checksum file (covers the whole kioskd release)

Workflows pin this version only after the promotion PR merges. See README.md.
EOF
gh release create "v$version" "${files[@]}" --repo "$repo" --target "$target" \
  --title "kioskit-publish $version" --notes-file "$notes"
echo "mirror-release: created v$version at $target"
