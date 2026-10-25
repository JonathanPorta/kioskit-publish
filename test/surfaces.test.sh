#!/usr/bin/env bash
# surfaces.test.sh — release-surfaces.yaml declares exactly the AC-14 surface
# (kioskit#137), and, when blessed's validator is reachable, passes it.
#
# blessed's validate-surfaces.sh lives in the PRIVATE blessed-cicd `release`
# category. blessed-cicd scripts/INSTALL.md forbids vendoring private category
# tarballs into a public repository, and the public script export
# (public-consumer-core) does not include it. So:
#   - this test always asserts the declared values itself (offline, in CI);
#   - with BLESSED_CICD_DIR=<a blessed-cicd checkout> it also runs blessed's own
#     validator, read from that checkout's origin/master, against this file.
#     That needs mikefarah yq at the exact version the validator pins (set
#     YQ_BIN if your default yq differs).
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
F="$ROOT/release-surfaces.yaml"

fail=0
ok() { echo "  ✓ $1"; }
no() {
  echo "  ✗ $1"
  fail=1
}

echo "── release-surfaces.yaml declares the AC-14 surface ──"
[ -f "$F" ] || {
  echo "surfaces: not found: $F" >&2
  exit 1
}
q() { yq -r "$1" "$F"; }
[ "$(q '.schema')" = "blessed/release-surfaces/v1" ] && ok "schema blessed/release-surfaces/v1" || no "schema is $(q '.schema')"
[ "$(q '.surfaces | length')" = "1" ] && ok "exactly one surface" || no "want exactly one surface"
check() { # path want
  local got
  got="$(q ".surfaces[0].$1")"
  [ "$got" = "$2" ] && ok "$1: $2" || no "$1 is [$got], want [$2]"
}
check kind public-github-mirror
check owner_repo JonathanPorta/kioskit-publish
check 'producer_repos | join(",")' JonathanPorta/kioskd
check publisher_model surface-pull
check promotion_transport workflow_dispatch
check access_model public-anonymous

echo "── blessed validate-surfaces.sh ──"
if [ -n "${BLESSED_CICD_DIR:-}" ]; then
  B="$(mktemp -d)"
  trap 'rm -rf "$B"' EXIT
  mkdir -p "$B/lib" "$B/references"
  for p in validate-surfaces.sh lib/lib-json-schema.sh references/release-surfaces.schema.json; do
    git -C "$BLESSED_CICD_DIR" show "origin/master:scripts/release/$p" >"$B/$p" || no "cannot read scripts/release/$p from $BLESSED_CICD_DIR"
  done
  out="$(bash "$B/validate-surfaces.sh" --file "$F" 2>&1)"
  rc=$?
  [ "$rc" = 0 ] && ok "blessed validate-surfaces.sh ($(git -C "$BLESSED_CICD_DIR" rev-parse --short origin/master)): $out" ||
    no "blessed validate-surfaces.sh exit $rc: $out"
else
  echo "  - SKIPPED: blessed's validator is private (set BLESSED_CICD_DIR to a blessed-cicd checkout to run it)"
fi

if [ "$fail" -ne 0 ]; then
  echo "surfaces: FAILED"
  exit 1
fi
echo "surfaces: OK"
