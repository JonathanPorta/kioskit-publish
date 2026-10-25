#!/usr/bin/env bash
# surfaces.test.sh — kioskit#137 AC-14: release-surfaces.yaml passes blessed's
# canonical validate-surfaces.sh, in ordinary CI and offline.
#
# The validator, its schema and its JSON-Schema library come from blessed's
# signed public script export (scripts/release/, bound to the signed manifest
# by `make verify-scripts`). It pins Mike Farah yq EXACTLY (4.53.2) and refuses
# any other build, so YQ_BIN must point at that version; CI installs it from
# the upstream release, checksum-verified.
#
# On top of the canonical verdict, the repo-specific values are asserted
# (kind, owner_repo, producer, transport), and negative controls are run
# through the same canonical validator.
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
F="$ROOT/release-surfaces.yaml"
VALIDATE="$ROOT/scripts/release/validate-surfaces.sh"

fail=0
ok() { echo "  ✓ $1"; }
no() {
  echo "  ✗ $1"
  fail=1
}
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
YQ="${YQ_BIN:-yq}"

echo "── canonical blessed validate-surfaces.sh ($(jq -r .tag "$ROOT/.blessed/export/SOURCE.json"); $("$YQ" --version 2>&1 | sed 's/.*version /yq /')) ──"
out="$(bash "$VALIDATE" --file "$F" 2>&1)"
rc=$?
if [ "$rc" = 0 ]; then
  ok "${out//$ROOT\//}"
else
  no "validate-surfaces.sh exit $rc: $(echo "$out" | tr '\n' ' ')"
  [ "$rc" = 2 ] && echo "    (exit 2 is a tooling error: set YQ_BIN to mikefarah yq 4.53.2)"
fi

echo "── repo-specific values ──"
q() { "$YQ" -r "$1" "$F"; }
[ "$(q '.surfaces | length')" = "1" ] && ok "exactly one surface" || no "want exactly one surface"
check() {
  local got
  got="$(q ".surfaces[0].$1")"
  [ "$got" = "$2" ] && ok "$1: $2" || no "$1 is [$got], want [$2]"
}
check kind public-github-mirror
check owner_repo JonathanPorta/kioskit-publish
check 'producer_repos | join(",")' JonathanPorta/kioskd
check promotion_transport workflow_dispatch

echo "── negative controls through the canonical validator ──"
neg() { # name | expected substring | file
  local name="$1" want="$2" f="$3" out rc
  out="$(bash "$VALIDATE" --file "$f" 2>&1)"
  rc=$?
  if [ "$rc" = 1 ] && grep -Fq -- "$want" <<<"$out"; then
    ok "$name → $(grep -F -- "$want" <<<"$out" | head -n 1)"
  else
    no "$name: want INVALID (exit 1) mentioning [$want]; got exit $rc: $(echo "$out" | tr '\n' ' ')"
  fi
}
"$YQ" 'del(.surfaces[0].consumer_contract)' "$F" >"$TMP/no-cc.yaml"
neg missing-consumer_contract "consumer_contract" "$TMP/no-cc.yaml"
{
  cat "$F"
  echo "product: duplicate"
} >"$TMP/dup.yaml"
neg duplicate-key "duplicate mapping keys" "$TMP/dup.yaml"
"$YQ" '.surfaces[0].public_base_url = "https://example.com/downloads/"' "$F" >"$TMP/dl.yaml"
neg mirror-download-field "matched forbidden not-schema" "$TMP/dl.yaml"
"$YQ" '.surfaces[0].promotion_transport = "push"' "$F" >"$TMP/tr.yaml"
neg bad-transport "promotion_transport" "$TMP/tr.yaml"

if [ "$fail" -ne 0 ]; then
  echo "surfaces: FAILED"
  exit 1
fi
echo "surfaces: OK"
