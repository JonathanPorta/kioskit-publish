#!/usr/bin/env bash
# sync-blessed-export.sh — install scripts/signing/ from the pinned blessed-cicd
# PUBLIC script export (scripts/.blessed-export-version).
#
# This is blessed-cicd scripts/INSTALL.md's public-consumer install block,
# narrowed to the one category this repository uses (signing/). The checks are
# the same and all run before any file here changes:
#   1. origin: MANIFEST.sha256.sig verifies with the export key pinned in the
#      committed .blessed/export-trust-store.json (plain OpenSSL, so trust does
#      not depend on a verifier shipped inside the export);
#   2. closed set: the archive holds exactly the signed manifest's regular files
#      (no link, special file, absolute or '..' path) and every digest matches;
#   3. identity: the signed SOURCE.json names exactly the pinned export, tag,
#      mirror, source repository and signing key.
# Only then are the listed signing/ files, the JSON-Schema validator
# (release/lib/lib-json-schema.sh), LICENSE and SOURCE.json copied in. The
# mapping is the one scripts/verify-export.sh re-checks offline in make check.
# Needs network and gh; `make verify-scripts` re-checks the result offline.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
# shellcheck source=scripts/.blessed-export-version
. scripts/.blessed-export-version

MIRROR="$EXPORT_MIRROR"
EXPORT="$EXPORT_NAME"
TAG="$EXPORT_TAG"
STORE=.blessed/export-trust-store.json
KEY_ID="$EXPORT_KEY_ID"
SOURCE_REPO="$EXPORT_SOURCE_REPO"
OPENSSL="${OPENSSL_BIN:-openssl}"

refuse() {
  echo "sync-blessed-export: refused: $*" >&2
  exit 1
}
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

gh release download "$TAG" -R "$MIRROR" -D "$tmp" \
  -p "$TAG.tar.gz" -p MANIFEST.sha256 -p MANIFEST.sha256.sig -p SOURCE.json

# 1. Origin.
pub="$(jq -r --arg k "$KEY_ID" '.keys[$k] | select(.status == "active") | .public_key_base64' "$STORE")"
grep -qxE '[A-Za-z0-9+/]{43}=' <<<"$pub" || refuse "$KEY_ID is not an active key in $STORE"
printf -- '-----BEGIN PUBLIC KEY-----\nMCowBQYDK2VwAyEA%s\n-----END PUBLIC KEY-----\n' "$pub" >"$tmp/pub.pem"
"$OPENSSL" base64 -d -A <"$tmp/MANIFEST.sha256.sig" >"$tmp/sig.raw"
"$OPENSSL" pkeyutl -verify -pubin -inkey "$tmp/pub.pem" -rawin -sigfile "$tmp/sig.raw" -in "$tmp/MANIFEST.sha256" >/dev/null ||
  refuse "MANIFEST.sha256.sig does not verify with $KEY_ID"

# 2. Closed set.
tgz="$tmp/$TAG.tar.gz"
if grep -Evxq '[0-9a-f]{64}  [A-Za-z0-9_.-]+(/[A-Za-z0-9_.-]+)*' "$tmp/MANIFEST.sha256"; then
  refuse "MANIFEST.sha256 has a line that is not '<sha256>  <relative path>'"
fi
listed="$(cut -c67- "$tmp/MANIFEST.sha256" | LC_ALL=C sort)"
if grep -Eq '(^|/)\.\.?(/|$)' <<<"$listed"; then refuse "MANIFEST.sha256 lists a '.' or '..' path"; fi
[ -z "$(uniq -d <<<"$listed")" ] || refuse "MANIFEST.sha256 lists a path twice"
while IFS= read -r f; do
  case "$f" in release/* | signing/* | checkers/* | LICENSE | SOURCE.json) ;; *) refuse "MANIFEST.sha256 lists $f" ;; esac
done <<<"$listed"
want="$({
  printf 'd %s\nf %s/MANIFEST.sha256\n' "$EXPORT" "$EXPORT"
  awk -v e="$EXPORT" '{ print "f " e "/" $0; p = e; n = split($0, s, "/"); for (i = 1; i < n; i++) { p = p "/" s[i]; print "d " p } }' <<<"$listed"
} | LC_ALL=C sort -u)"
types="$(tar -tvzf "$tgz")"
names="$(tar -tzf "$tgz")"
[ "$(wc -l <<<"$types")" -eq "$(wc -l <<<"$names")" ] || refuse "the archive listing is ambiguous"
if grep -vq '^[-d]' <<<"$types"; then refuse "archive entry is a link or special file: $(grep -v '^[-d]' <<<"$types" | head -n 1)"; fi
while IFS= read -r n; do
  grep -Fxq -e "d ${n%/}" -e "f $n" <<<"$want" || refuse "archive entry is not in the signed manifest: $n"
done <<<"$names"
stage="$(mktemp -d "$tmp/stage.XXXXXX")"
tar -xzf "$tgz" -C "$stage"
odd="$(cd "$stage" && find . -mindepth 1 ! -type d ! \( -type f -links 1 \))"
[ -z "$odd" ] || refuse "staged entry is a link, hard link or special file: $odd"
found="$(cd "$stage" && { find . -mindepth 1 -type d | sed 's#^\./#d #'; find . -type f | sed 's#^\./#f #'; } | LC_ALL=C sort)"
[ "$found" = "$want" ] || refuse "staged tree is not exactly the signed set"
cmp "$tmp/MANIFEST.sha256" "$stage/$EXPORT/MANIFEST.sha256"
(cd "$stage/$EXPORT" && shasum -a 256 -c MANIFEST.sha256 >/dev/null) || refuse "a file does not match its signed digest"

# 3. Identity.
cmp -s "$tmp/SOURCE.json" "$stage/$EXPORT/SOURCE.json" || refuse "the SOURCE.json release asset is not the signed SOURCE.json"
mismatch="$(jq -r --arg e "$EXPORT" --arg t "$TAG" --arg m "$MIRROR" --arg r "$SOURCE_REPO" --arg k "$KEY_ID" '[
  (if .schema == "blessed/script-export-source/v1" then empty else "schema" end),
  (if .export == $e then empty else "export" end),
  (if .tag == $t then empty else "tag" end),
  (if ($e + "-v" + (.version | tostring)) == $t then empty else "version" end),
  (if .mirror_repo == $m then empty else "mirror_repo" end),
  (if .source_repo == $r then empty else "source_repo" end),
  (if .signing.profile == "ed25519-detached-v1" then empty else "signing.profile" end),
  (if .signing.key_id == $k then empty else "signing.key_id" end)
] | join(" ")' "$stage/$EXPORT/SOURCE.json")"
[ -z "$mismatch" ] || refuse "the signed SOURCE.json differs from the pinned identity: $mismatch"

# 4. Install: only the listed signing/ files, the schema validator, LICENSE and SOURCE.json.
rm -rf scripts/signing scripts/release .blessed/export
while IFS= read -r f; do
  case "$f" in
    signing/* | release/lib/lib-json-schema.sh) dst="scripts/$f" ;;
    LICENSE | SOURCE.json) dst=".blessed/export/$f" ;;
    *) continue ;;
  esac
  mkdir -p "$(dirname "$dst")"
  cp "$stage/$EXPORT/$f" "$dst"
done <<<"$listed"
cp "$tmp/MANIFEST.sha256" "$tmp/MANIFEST.sha256.sig" .blessed/export/
chmod +x scripts/signing/*.sh
bash scripts/verify-export.sh
echo "sync-blessed-export: installed scripts/signing/ and scripts/release/lib/lib-json-schema.sh from $MIRROR@$TAG"
