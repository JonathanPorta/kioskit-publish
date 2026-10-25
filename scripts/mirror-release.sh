#!/usr/bin/env bash
# mirror-release.sh — create the immutable public release v<version> from an
# already VERIFIED kioskd candidate subset (kioskit#137 AC-4, AC-17).
#
# Runs mirror-guard.sh first, so a second run for a version refuses without
# touching the existing tag. Creates the tag at --target (this repository's
# commit) together with the release, uploading exactly the five public files.
# Never --clobber, never moves a tag. With immutable releases enabled, the
# published assets and tag cannot change afterwards.
#
# --mode resume finishes a run that already created the release: it creates
# nothing. It downloads the existing release's assets, requires exactly the five
# public files, verifies them against the signed candidate and the trust store
# (scripts/verify-publisher.sh), and requires each to be byte-identical to the
# freshly fetched, verified candidate. Any difference refuses.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

repo="" version="" dir="" target="" mode="fresh" key_id="" pubkey="" store=""
while [ $# -gt 0 ]; do
  case "$1" in
    --repo) repo="${2:-}" && shift 2 ;;
    --version) version="${2:-}" && shift 2 ;;
    --dir) dir="${2:-}" && shift 2 ;;
    --target) target="${2:-}" && shift 2 ;;
    --mode) mode="${2:-}" && shift 2 ;;
    --key-id) key_id="${2:-}" && shift 2 ;;
    --pubkey-b64) pubkey="${2:-}" && shift 2 ;;
    --trust-store) store="${2:-}" && shift 2 ;;
    *)
      echo "mirror-release: usage: mirror-release.sh --repo OWNER/NAME --version X.Y.Z --dir VERIFIED_DIR --target SHA [--mode fresh|resume --key-id K --pubkey-b64 P --trust-store T]" >&2
      exit 2
      ;;
  esac
done
printf '%s' "$target" | grep -Eqx '[0-9a-f]{40}' || {
  echo "mirror-release: --target is not a full commit SHA: $target" >&2
  exit 2
}
bash "$HERE/mirror-guard.sh" --repo "$repo" --version "$version" --mode "$mode"

bin="kioskit-publish_${version}_linux_amd64"
files=("$dir/$bin" "$dir/$bin.sig" "$dir/release-candidate.json" "$dir/release-candidate.json.sig" "$dir/SHA256SUMS")
for f in "${files[@]}"; do
  [ -f "$f" ] || {
    echo "mirror-release: missing verified file: $f" >&2
    exit 1
  }
done
if [ "$mode" = resume ]; then
  [ -n "$key_id" ] && [ -n "$pubkey" ] && [ -n "$store" ] || {
    echo "mirror-release: resume needs --key-id, --pubkey-b64 and --trust-store" >&2
    exit 2
  }
  existing="$(mktemp -d)"
  trap 'rm -rf "$existing"' EXIT
  names="$(gh api "repos/$repo/releases/tags/v$version" --jq '.assets[].name' | LC_ALL=C sort)"
  want="$(for f in "${files[@]}"; do basename "$f"; done | LC_ALL=C sort)"
  [ "$names" = "$want" ] || {
    echo "mirror-release: refused: release v$version assets are [$(tr "\n" " " <<<"$names")], want exactly [$(tr "\n" " " <<<"$want")]" >&2
    exit 1
  }
  gh release download "v$version" --repo "$repo" --dir "$existing"
  bash "$HERE/verify-publisher.sh" --dir "$existing" --version "$version" --sha256-from-signed-manifest --require-sha256sums \
    --key-id "$key_id" --pubkey-b64 "$pubkey" --trust-store "$store" || {
    echo "mirror-release: refused: the existing release v$version does not verify" >&2
    exit 1
  }
  for f in "${files[@]}"; do
    cmp -s "$f" "$existing/$(basename "$f")" || {
      echo "mirror-release: refused: existing asset $(basename "$f") differs from the verified kioskd candidate" >&2
      exit 1
    }
  done
  echo "mirror-release: resume — release v$version exists, verifies and matches the candidate byte for byte; created nothing"
  exit 0
fi
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
