#!/usr/bin/env bash
# verify-publisher.sh — verify a downloaded kioskit-publish release BEFORE
# anything executes it. FAIL CLOSED. Every workflow in this repository that
# touches the binary runs this first (kioskit#137 AC-5).
#
# Checks, each named in its failure message as FAILED [<check>]:
#   download            every expected file is present and a regular file
#   pinned-key          the pinned public key is the ACTIVE ed25519 key of that
#                       key id in the committed trust store
#   digest              sha256(binary) equals the pinned PUBLISHER_SHA256
#   binary-signature    the binary's detached ed25519 signature verifies
#   manifest-signature  release-candidate.json's signature verifies
#   manifest-entry      the signed manifest is this version's kioskd candidate,
#                       signed by the pinned key id, and lists exactly this
#                       binary (id linux-amd64-kioskit-publish) with this digest
#   sha256sums          (--require-sha256sums) SHA256SUMS is the file the signed
#                       manifest digests, and it lists the binary's digest
# Signatures are verified by the blessed ed25519-detached-v1 verifier
# (scripts/signing/verify.sh, from the signed public script export).
#
# Only after every check passes, --install copies the binary to PATH with mode
# 0755. Nothing here executes the binary.
#
# --sha256-from-signed-manifest (mirror.yml only): there is no digest pin yet,
# so the digest is taken from the manifest AFTER its signature verifies; the
# manifest checks then run first.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VERIFY="$HERE/signing/verify.sh"
ARTIFACT_ID="linux-amd64-kioskit-publish"
PRODUCER_REPO="JonathanPorta/kioskd"

usage() {
  cat >&2 <<'EOF'
Usage: verify-publisher.sh --dir DIR --version X.Y.Z (--sha256 HEX | --sha256-from-signed-manifest)
         --key-id KEY_ID --pubkey-b64 B64 --trust-store STORE.json
         [--require-sha256sums] [--install PATH]
EOF
  exit 2
}

dir="" version="" pin_sha="" from_manifest=0 key_id="" pin_pub="" store="" want_sums=0 install=""
while [ $# -gt 0 ]; do
  case "$1" in
    --dir) dir="${2:-}" && shift 2 ;;
    --version) version="${2:-}" && shift 2 ;;
    --sha256) pin_sha="${2:-}" && shift 2 ;;
    --sha256-from-signed-manifest) from_manifest=1 && shift ;;
    --key-id) key_id="${2:-}" && shift 2 ;;
    --pubkey-b64) pin_pub="${2:-}" && shift 2 ;;
    --trust-store) store="${2:-}" && shift 2 ;;
    --require-sha256sums) want_sums=1 && shift ;;
    --install) install="${2:-}" && shift 2 ;;
    -h | --help) usage ;;
    *)
      printf 'verify-publisher: unexpected argument: %s\n' "$1" >&2
      usage
      ;;
  esac
done

fail() { # $1=check  $2=message
  printf '::error title=publisher verification failed::[%s] %s\n' "$1" "$2"
  printf 'verify-publisher: FAILED [%s]: %s\n' "$1" "$2" >&2
  exit 1
}
pass() { printf 'verify-publisher: ok [%s] %s\n' "$1" "$2"; }

sha256_of() {
  if command -v sha256sum >/dev/null 2>&1; then sha256sum -- "$1" | cut -d' ' -f1; else shasum -a 256 -- "$1" | cut -d' ' -f1; fi
}

# ── inputs (usage errors, not verification results) ──
[ -n "$dir" ] && [ -n "$version" ] && [ -n "$key_id" ] && [ -n "$pin_pub" ] && [ -n "$store" ] || usage
if [ "$from_manifest" = 1 ]; then [ -z "$pin_sha" ] || usage; else [ -n "$pin_sha" ] || usage; fi
printf '%s' "$version" | grep -Eqx '[0-9]+\.[0-9]+\.[0-9]+' || fail pins "version is not X.Y.Z: $version"
[ "$from_manifest" = 1 ] || printf '%s' "$pin_sha" | grep -Eqx '[0-9a-f]{64}' || fail pins "pinned sha256 is not 64 lowercase hex"
printf '%s' "$key_id" | grep -Eqx '[a-z0-9][a-z0-9-]*' || fail pins "key id is malformed: $key_id"
printf '%s' "$pin_pub" | grep -Eqx '[A-Za-z0-9+/]{43}=' || fail pins "pinned public key is not a raw ed25519 key in base64"
[ -x "$VERIFY" ] || [ -f "$VERIFY" ] || fail tooling "blessed verifier not found: $VERIFY"
command -v jq >/dev/null 2>&1 || fail tooling "jq is required"

bin="kioskit-publish_${version}_linux_amd64"
B="$dir/$bin"
M="$dir/release-candidate.json"
S="$dir/SHA256SUMS"

# ── download ──
need=("$B" "$B.sig" "$M" "$M.sig")
[ "$want_sums" = 1 ] && need+=("$S")
for f in "${need[@]}"; do
  { [ -f "$f" ] && [ ! -L "$f" ]; } || fail download "missing or not a regular file: $(basename "$f")"
done
pass download "${#need[@]} files present"

# ── pinned-key ──
[ -f "$store" ] || fail pinned-key "trust store not found: $store"
store_pub="$(jq -r --arg k "$key_id" '
  if .schema != "blessed/signing-trust-store/v1" then empty
  else (.keys[$k] // empty) | select(.profile == "ed25519-detached-v1" and .status == "active") | .public_key_base64 end' "$store" 2>/dev/null || true)"
[ -n "$store_pub" ] || fail pinned-key "key id $key_id is not an active ed25519-detached-v1 key in $(basename "$store")"
[ "$store_pub" = "$pin_pub" ] || fail pinned-key "the pinned public key for $key_id does not match the committed trust store"
pass pinned-key "$key_id"

sig_ok() { # $1=file
  bash "$VERIFY" --profile ed25519-detached-v1 --input "$1" --signature "$1.sig" --trust-store "$store" --key-id "$key_id" 2>/dev/null
}

check_digest() {
  local got
  got="$(sha256_of "$B")"
  [ "$got" = "$pin_sha" ] || fail digest "sha256($bin) is $got, pinned $pin_sha"
  pass digest "$got"
}
check_binary_sig() {
  sig_ok "$B" || fail binary-signature "$bin.sig is not a valid $key_id signature over $bin"
  pass binary-signature "$bin.sig"
}
check_manifest_sig() {
  sig_ok "$M" || fail manifest-signature "release-candidate.json.sig is not a valid $key_id signature over release-candidate.json"
  pass manifest-signature "release-candidate.json.sig"
}
check_manifest_entry() {
  local size bad
  size="$(wc -c <"$B" | tr -d ' ')"
  # shellcheck disable=SC2016 # jq program
  bad="$(jq -r --arg v "$version" --arg bin "$bin" --arg sha "$pin_sha" --arg id "$ARTIFACT_ID" \
    --arg k "$key_id" --arg repo "$PRODUCER_REPO" --argjson size "$size" '
    [ (if .schema == "blessed/release-candidate/v1" then empty else "schema is not blessed/release-candidate/v1" end),
      (if .producer_repo == $repo then empty else "producer_repo is not \($repo)" end),
      (if .version == $v and .tag == ("v" + $v) then empty else "manifest is for \(.tag // "?"), not v\($v)" end),
      (if .signing.profile == "ed25519-detached-v1" and .signing.key_id == $k then empty else "manifest names signing key \(.signing.key_id // "?"), not \($k)" end),
      (if (.source_sha | type) == "string" and (.source_sha | test("^[0-9a-f]{40}$")) then empty else "source_sha is not a 40-hex commit" end),
      ( [ (.artifacts // [])[] | select(.id == $id) ] as $a
        | if ($a | length) != 1 then "expected exactly one artifact with id \($id), found \($a | length)"
          else $a[0] as $e
          | (if $e.filename == $bin then empty else "artifact \($id) is \($e.filename), not \($bin)" end),
            (if $e.platform == "linux/amd64" then empty else "artifact \($id) platform is \($e.platform)" end),
            (if $e.sha256 == $sha then empty else "artifact \($id) sha256 is \($e.sha256), pinned \($sha)" end),
            (if $e.signature == ($bin + ".sig") then empty else "artifact \($id) signature is \($e.signature)" end),
            (if $e.size == $size then empty else "artifact \($id) size is \($e.size), file is \($size)" end)
          end ),
      ( [ (.files // [])[] | select(.name == $bin) ] as $f
        | if ($f | length) == 1 and $f[0].sha256 == $sha then empty else "files[] does not list \($bin) with sha256 \($sha)" end )
    ] | join("; ")' "$M" 2>&1)" || fail manifest-entry "release-candidate.json is not valid JSON"
  [ -z "$bad" ] || fail manifest-entry "$bad"
  pass manifest-entry "$ARTIFACT_ID = $bin @ $pin_sha"
}
check_sums() {
  local want got
  want="$(jq -r '[(.files // [])[] | select(.name == "SHA256SUMS" and .role == "checksums") | .sha256] | if length == 1 then .[0] else "" end' "$M")"
  got="$(sha256_of "$S")"
  [ -n "$want" ] && [ "$got" = "$want" ] || fail sha256sums "SHA256SUMS digest $got is not the one the signed manifest records (${want:-none})"
  grep -Fqx "$pin_sha  $bin" "$S" || fail sha256sums "SHA256SUMS does not list $bin with $pin_sha"
  pass sha256sums "matches the signed manifest"
}

check_pinned_order() { check_digest && check_binary_sig && check_manifest_sig && check_manifest_entry; }
if [ "$from_manifest" = 1 ]; then
  check_manifest_sig
  pin_sha="$(jq -r --arg id "$ARTIFACT_ID" '[(.artifacts // [])[] | select(.id == $id) | .sha256] | if length == 1 then .[0] else "" end' "$M")"
  printf '%s' "$pin_sha" | grep -Eqx '[0-9a-f]{64}' || fail manifest-entry "the signed manifest has no single $ARTIFACT_ID artifact with a sha256"
  check_manifest_entry
  check_digest
  check_binary_sig
else
  check_pinned_order
fi
[ "$want_sums" = 1 ] && check_sums

if [ -n "$install" ]; then
  mkdir -p "$(dirname "$install")"
  cp -- "$B" "$install.tmp"
  chmod 0755 "$install.tmp"
  mv -f -- "$install.tmp" "$install"
  pass install "$install"
fi
echo "verify-publisher: OK — kioskit-publish $version ($pin_sha) is the signed $key_id release"
