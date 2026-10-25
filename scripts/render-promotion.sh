#!/usr/bin/env bash
# render-promotion.sh — deterministically render the promotion change for a
# mirrored version (kioskit#137 AC-16). Offline; writes only inside --root.
#
#   - bumps PUBLISHER_VERSION and PUBLISHER_SHA256 in kioskit-publish.yml and
#     kioskit-validate.yml (identical values in both);
#   - writes provenance/v<version>.json (blessed/public-github-mirror-provenance/v1)
#     with source_sha taken from the SIGNED manifest;
#   - commits the signed manifest beside it (provenance/v<version>.release-candidate.json
#     and .sig) so test/workflow-contract.test.sh can re-verify the record offline.
#
# The same candidate always renders the same bytes: built_at is the signed
# manifest's created_at, not the wall clock. --dir must already have passed
# scripts/verify-publisher.sh.
set -euo pipefail

root="" dir="" version=""
while [ $# -gt 0 ]; do
  case "$1" in
    --root) root="${2:-}" && shift 2 ;;
    --dir) dir="${2:-}" && shift 2 ;;
    --version) version="${2:-}" && shift 2 ;;
    *)
      echo "render-promotion: usage: render-promotion.sh --root REPO --dir VERIFIED_DIR --version X.Y.Z" >&2
      exit 2
      ;;
  esac
done
printf '%s' "$version" | grep -Eqx '[0-9]+\.[0-9]+\.[0-9]+' || {
  echo "render-promotion: version is not X.Y.Z: $version" >&2
  exit 2
}
M="$dir/release-candidate.json"
[ -f "$M" ] && [ -f "$M.sig" ] || {
  echo "render-promotion: missing $M(.sig)" >&2
  exit 1
}
bin="kioskit-publish_${version}_linux_amd64"
sha="$(jq -r --arg b "$bin" '[.artifacts[] | select(.id == "linux-amd64-kioskit-publish" and .filename == $b) | .sha256] | if length == 1 then .[0] else "" end' "$M")"
printf '%s' "$sha" | grep -Eqx '[0-9a-f]{64}' || {
  echo "render-promotion: the signed manifest does not list $bin" >&2
  exit 1
}

# replace_pin FILE KEY VALUE — exactly one `  KEY: "..."` line, or refuse.
replace_pin() {
  local f="$1" k="$2" v="$3" n
  n="$(grep -Ec "^  $k: \"[^\"]*\"$" "$f" || true)"
  [ "$n" = 1 ] || {
    echo "render-promotion: $f has $n '$k' pin lines, want exactly 1" >&2
    exit 1
  }
  sed -E "s|^  $k: \"[^\"]*\"$|  $k: \"$v\"|" "$f" >"$f.tmp" && mv "$f.tmp" "$f"
}
for wf in kioskit-publish.yml kioskit-validate.yml; do
  replace_pin "$root/.github/workflows/$wf" PUBLISHER_VERSION "$version"
  replace_pin "$root/.github/workflows/$wf" PUBLISHER_SHA256 "$sha"
done

mkdir -p "$root/provenance"
cp "$M" "$root/provenance/v$version.release-candidate.json"
cp "$M.sig" "$root/provenance/v$version.release-candidate.json.sig"
jq --arg v "$version" --arg bin "$bin" '{
    schema: "blessed/public-github-mirror-provenance/v1",
    source_repo: .producer_repo,
    source_ref: .tag,
    source_sha: .source_sha,
    mirror_repo: "JonathanPorta/kioskit-publish",
    mirror_ref: ("v" + $v),
    built_at: .created_at,
    public_files: [$bin, ($bin + ".sig"), "release-candidate.json", "release-candidate.json.sig", "SHA256SUMS"]
  }' "$M" >"$root/provenance/v$version.json"
echo "render-promotion: pins -> $version ($sha); wrote provenance/v$version.json"
