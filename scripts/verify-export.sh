#!/usr/bin/env bash
# verify-export.sh — OFFLINE proof that every vendored blessed file is the signed
# public export's file (kioskit#137 review F2). Run by `make verify-scripts`,
# first in `make check`.
#
#   1. The pinned export key (scripts/.blessed-export-version) is the active key
#      in the committed .blessed/export-trust-store.json.
#   2. .blessed/export/MANIFEST.sha256.sig verifies over MANIFEST.sha256 with that
#      key, using plain OpenSSL: the verifier being checked never vouches for
#      itself.
#   3. Every installed file equals its signed manifest entry, byte for byte:
#        signing/*                     -> scripts/signing/*
#        release/lib/lib-json-schema.sh -> scripts/release/lib/lib-json-schema.sh
#        release/validate-surfaces.sh   -> scripts/release/validate-surfaces.sh
#        release/references/release-surfaces.schema.json
#                                       -> scripts/release/references/release-surfaces.schema.json
#        LICENSE, SOURCE.json           -> .blessed/export/
#      and scripts/signing/ and scripts/release/ hold nothing else (closed set).
#      A per-category MANIFEST.sha256 inside scripts/signing/ is itself just one
#      of the signed files, so rewriting it cannot vouch for a changed script.
#   4. The signed SOURCE.json names exactly the pinned export, tag, mirror,
#      source repository and signing key.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
# shellcheck source=scripts/.blessed-export-version
. scripts/.blessed-export-version
OPENSSL="${OPENSSL_BIN:-openssl}"
STORE=.blessed/export-trust-store.json
M=.blessed/export/MANIFEST.sha256

refuse() {
  echo "verify-export: FAILED: $*" >&2
  exit 1
}
sha256_of() { if command -v sha256sum >/dev/null 2>&1; then sha256sum -- "$1" | cut -d' ' -f1; else shasum -a 256 -- "$1" | cut -d' ' -f1; fi; }

case "$("$OPENSSL" version 2>/dev/null)" in
  "OpenSSL "[3-9]* | "OpenSSL "[1-9][0-9]*) ;;
  *) refuse "need OpenSSL >= 3 (set OPENSSL_BIN); got: $("$OPENSSL" version 2>/dev/null || echo none)" ;;
esac

# 1. Key pin.
pub="$(jq -r --arg k "$EXPORT_KEY_ID" '.keys[$k] | select(.status == "active" and .profile == "ed25519-detached-v1") | .public_key_base64' "$STORE" 2>/dev/null || true)"
[ -n "$pub" ] && [ "$pub" = "$EXPORT_PUBKEY_B64" ] || refuse "$STORE does not hold the pinned $EXPORT_KEY_ID key as active"

# 2. Signature over the outer manifest.
[ -f "$M" ] && [ -f "$M.sig" ] || refuse "missing $M or its .sig"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
printf -- '-----BEGIN PUBLIC KEY-----\nMCowBQYDK2VwAyEA%s\n-----END PUBLIC KEY-----\n' "$pub" >"$tmp/pub.pem"
[ "$(wc -c <"$M.sig" | tr -d ' ')" = 88 ] || refuse "$M.sig is not an 88-byte ed25519-detached-v1 signature"
"$OPENSSL" base64 -d -A <"$M.sig" >"$tmp/sig.raw" 2>/dev/null || refuse "$M.sig is not base64"
"$OPENSSL" pkeyutl -verify -pubin -inkey "$tmp/pub.pem" -rawin -sigfile "$tmp/sig.raw" -in "$M" >/dev/null 2>&1 ||
  refuse "$M.sig does not verify with $EXPORT_KEY_ID"
if grep -Evxq '[0-9a-f]{64}  [A-Za-z0-9_.-]+(/[A-Za-z0-9_.-]+)*' "$M"; then refuse "$M has a malformed line"; fi
echo "verify-export: ok — MANIFEST.sha256 is signed by $EXPORT_KEY_ID ($EXPORT_TAG)"

# 3. Installed files equal their signed entries; closed set.
dst_of() {
  case "$1" in
    signing/* | release/lib/lib-json-schema.sh | release/validate-surfaces.sh | release/references/release-surfaces.schema.json) echo "scripts/$1" ;;
    LICENSE | SOURCE.json) echo ".blessed/export/$1" ;;
    *) echo "" ;;
  esac
}
n=0
bad=0
expected=""
while read -r sha path; do
  dst="$(dst_of "$path")"
  [ -n "$dst" ] || continue
  expected="$expected$dst"$'\n'
  if [ ! -f "$dst" ] || [ -L "$dst" ]; then
    echo "verify-export: FAILED: $dst (signed as $path) is missing" >&2
    bad=1
    continue
  fi
  got="$(sha256_of "$dst")"
  if [ "$got" != "$sha" ]; then
    # Report every mismatch, not just the first.
    echo "verify-export: FAILED: $dst differs from its signed entry $path (sha256 $got, signed $sha)" >&2
    bad=1
    continue
  fi
  n=$((n + 1))
done <"$M"
[ "$bad" = 0 ] || exit 1
while IFS= read -r f; do
  [ -z "$f" ] && continue
  grep -Fqx "$f" <<<"$expected" || refuse "$f is not a file of the signed export (closed set)"
done < <(find scripts/signing scripts/release \( -type f -o -type l \) | LC_ALL=C sort)
echo "verify-export: ok — $n installed files match their signed entries; scripts/signing and scripts/release hold nothing else"

# 4. Identity.
mismatch="$(jq -r --arg e "$EXPORT_NAME" --arg t "$EXPORT_TAG" --arg m "$EXPORT_MIRROR" --arg r "$EXPORT_SOURCE_REPO" --arg k "$EXPORT_KEY_ID" '[
  (if .schema == "blessed/script-export-source/v1" then empty else "schema" end),
  (if .export == $e then empty else "export" end),
  (if .tag == $t then empty else "tag" end),
  (if .mirror_repo == $m then empty else "mirror_repo" end),
  (if .source_repo == $r then empty else "source_repo" end),
  (if .signing.key_id == $k then empty else "signing.key_id" end)
] | join(" ")' .blessed/export/SOURCE.json)"
[ -z "$mismatch" ] || refuse "the signed SOURCE.json differs from the pins: $mismatch"
echo "verify-export: OK"
