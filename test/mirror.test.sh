#!/usr/bin/env bash
# mirror.test.sh — offline tests for mirror.yml's scripts (kioskit#137 AC-15,
# AC-16, AC-17). `gh` is replaced by a stub that keeps tags and releases in a
# temp directory, so the real scripts run unchanged.
#
#   AC-17  running the tag/release step twice for one version: the second run
#          fails and the tag still points where the first run put it.
#   AC-17  the guard fails closed on API errors and sees draft releases.
#   AC-15  mirror-mode verification refuses an unsigned or inconsistent candidate.
#   AC-16  the rendered promotion passes the contract's provenance check, and
#          rendering twice changes nothing.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FX_ROOT="$(cd "$HERE/.." && pwd)"
# shellcheck source=test/lib/fixtures.sh
. "$HERE/lib/fixtures.sh"

fail=0
ok() { echo "  ✓ $1"; }
no() {
  echo "  ✗ $1"
  fail=1
}
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# ── gh stub ──
mkdir -p "$TMP/bin" "$TMP/gh/tags" "$TMP/gh/releases"
cat >"$TMP/bin/gh" <<'EOF'
#!/usr/bin/env bash
S="${GH_STUB_STATE:?}"
echo "gh $*" >>"$S/calls"
if [ "${GH_STUB_FAIL:-}" = 1 ]; then echo "gh: Server Error (HTTP 502)" >&2; exit 1; fi
case "$1 $2" in
  "api --paginate")
    for f in "$S"/releases/*; do [ -e "$f" ] && basename "$f"; done
    exit 0 ;;
  api\ *)
    path="$2"
    case "$path" in
      */git/ref/tags/*) t="${path##*/}"; [ -f "$S/tags/$t" ] && { echo "{\"object\":{\"sha\":\"$(cat "$S/tags/$t")\"}}"; exit 0; } ;;
      */releases/tags/*) t="${path##*/}"; [ -f "$S/releases/$t" ] && [ -f "$S/tags/$t" ] && { echo '{}'; exit 0; } ;;
    esac
    echo "gh: Not Found (HTTP 404)" >&2; exit 1 ;;
  "release create")
    t="$3"; target=""
    while [ $# -gt 0 ]; do [ "$1" = --target ] && target="$2"; shift; done
    echo "create $t $target" >>"$S/creates"
    echo "$target" >"$S/tags/$t"; : >"$S/releases/$t"; exit 0 ;;
esac
echo "gh stub: unhandled: $*" >&2; exit 3
EOF
chmod +x "$TMP/bin/gh"
export GH_STUB_STATE="$TMP/gh"
GH="$TMP/bin:$PATH"

mkdir -p "$TMP/keys"
fx_keygen "$TMP/keys" good || exit 2
GOOD_PUB="$(cat "$TMP/keys/good.pub")"
fx_release "$TMP/cand" "$TMP/keys/good.pem"
V="$FIXTURE_VERSION"
fx_trust_store "$GOOD_PUB" "$TMP/store.json"
SHA1=1111111111111111111111111111111111111111
SHA2=2222222222222222222222222222222222222222

echo "── AC-17: the tag/release step, twice for one version ──"
if PATH="$GH" bash "$FX_ROOT/scripts/mirror-release.sh" --repo JonathanPorta/kioskit-publish --version "$V" --dir "$TMP/cand" --target "$SHA1" >"$TMP/r1" 2>&1; then
  ok "first run creates v$V at $SHA1"
else
  no "first run failed: $(tail -n 2 "$TMP/r1")"
fi
if PATH="$GH" bash "$FX_ROOT/scripts/mirror-release.sh" --repo JonathanPorta/kioskit-publish --version "$V" --dir "$TMP/cand" --target "$SHA2" >"$TMP/r2" 2>&1; then
  no "second run SUCCEEDED for an existing version"
else
  grep -q "refused: tag v$V already exists" "$TMP/r2" && ok "second run refused: $(grep -o 'refused: tag.*' "$TMP/r2")" || no "second run failed for another reason: $(tail -n 2 "$TMP/r2")"
fi
[ "$(cat "$TMP/gh/tags/v$V")" = "$SHA1" ] && ok "tag v$V still points at $SHA1 (unchanged)" || no "tag v$V moved to $(cat "$TMP/gh/tags/v$V")"
[ "$(wc -l <"$TMP/gh/creates" | tr -d ' ')" = 1 ] && ok "exactly one release create call across both runs" || no "release create was called $(wc -l <"$TMP/gh/creates") times"

echo "── AC-17: the guard fails closed ──"
if GH_STUB_FAIL=1 PATH="$GH" bash "$FX_ROOT/scripts/mirror-guard.sh" --repo JonathanPorta/kioskit-publish --version 1.2.3 >"$TMP/g1" 2>&1; then
  no "guard passed on an API error"
else
  grep -q 'cannot tell whether' "$TMP/g1" && ok "API error (HTTP 502) is a refusal, not 'absent'" || no "unexpected guard output: $(cat "$TMP/g1")"
fi
: >"$TMP/gh/releases/v1.2.4"
if PATH="$GH" bash "$FX_ROOT/scripts/mirror-guard.sh" --repo JonathanPorta/kioskit-publish --version 1.2.4 >"$TMP/g2" 2>&1; then
  no "guard passed with a draft release v1.2.4"
else
  grep -q 'draft' "$TMP/g2" && ok "a draft release with the tag name is refused" || no "unexpected guard output: $(cat "$TMP/g2")"
fi
if PATH="$GH" bash "$FX_ROOT/scripts/mirror-guard.sh" --repo JonathanPorta/kioskit-publish --version 1.2.5 >"$TMP/g3" 2>&1; then
  ok "a fresh version passes the guard"
else
  no "guard refused a fresh version: $(cat "$TMP/g3")"
fi

echo "── AC-15: mirror-mode verification refuses a bad candidate ──"
mverify() {
  bash "$FX_ROOT/scripts/verify-publisher.sh" --dir "$1" --version "$V" --sha256-from-signed-manifest --require-sha256sums \
    --key-id "$FIXTURE_KEY_ID" --pubkey-b64 "$GOOD_PUB" --trust-store "$TMP/store.json"
}
mverify "$TMP/cand" >"$TMP/v0" 2>&1 && ok "a genuine candidate verifies in mirror mode" || no "genuine candidate refused: $(tail -n 1 "$TMP/v0")"
for c in unsigned:manifest-signature sums:sha256sums missing:download; do
  name="${c%%:*}"
  check="${c#*:}"
  d="$TMP/bad-$name"
  cp -R "$TMP/cand" "$d"
  case "$name" in
    unsigned) printf 'x' >>"$d/release-candidate.json" ;;
    sums) printf '0000  extra\n' >>"$d/SHA256SUMS" ;;
    missing) rm "$d/SHA256SUMS" ;;
  esac
  if mverify "$d" >"$TMP/v-$name" 2>&1; then no "$name: verified"; else
    grep -q "FAILED \[$check\]" "$TMP/v-$name" && ok "$name → $(grep -o "FAILED \[$check\].*" "$TMP/v-$name")" || no "$name: wrong failure: $(tail -n 1 "$TMP/v-$name")"
  fi
done

echo "── AC-16: the rendered promotion satisfies the contract ──"
R="$TMP/repo"
mkdir -p "$R"
cp -R "$FX_ROOT/.github" "$FX_ROOT/scripts" "$FX_ROOT/provenance" "$R/"
fx_trust_store "$GOOD_PUB" "$R/release-trusted-keys.json"
for f in kioskit-publish.yml kioskit-validate.yml mirror.yml; do
  sed -E -e "s|^  PUBLISHER_KEY_ID: \"[^\"]*\"$|  PUBLISHER_KEY_ID: \"$FIXTURE_KEY_ID\"|" \
    -e "s|^  PUBLISHER_PUBKEY_B64: \"[^\"]*\"$|  PUBLISHER_PUBKEY_B64: \"$GOOD_PUB\"|" "$R/.github/workflows/$f" >"$R/x" && mv "$R/x" "$R/.github/workflows/$f"
done
if bash "$FX_ROOT/scripts/render-promotion.sh" --root "$R" --dir "$TMP/cand" --version "$V" >"$TMP/p1" 2>&1; then
  ok "render-promotion: $(tail -n 1 "$TMP/p1")"
else
  no "render-promotion failed: $(tail -n 2 "$TMP/p1")"
fi
if ROOT_OVERRIDE="$R" bash "$HERE/workflow-contract.test.sh" >"$TMP/c1" 2>&1; then
  ok "contract passes on the promoted tree: $(grep 'provenance/v' "$TMP/c1" | grep '✓' | tail -n 1 | sed 's/^ *✓ //')"
else
  no "contract fails on the promoted tree: $(grep '✗' "$TMP/c1" | head -n 3 | tr '\n' ' ')"
fi
[ "$(jq -r .source_sha "$R/provenance/v$V.json")" = "$FIXTURE_SOURCE_SHA" ] && ok "provenance source_sha is the signed manifest's ($FIXTURE_SOURCE_SHA)" || no "provenance source_sha is wrong"
(cd "$R" && find .github provenance -type f -exec shasum {} + | sort) >"$TMP/h1"
bash "$FX_ROOT/scripts/render-promotion.sh" --root "$R" --dir "$TMP/cand" --version "$V" >/dev/null 2>&1
(cd "$R" && find .github provenance -type f -exec shasum {} + | sort) >"$TMP/h2"
cmp -s "$TMP/h1" "$TMP/h2" && ok "rendering the same candidate twice changes no byte (deterministic)" || no "a second render changed files"

if [ "$fail" -ne 0 ]; then
  echo "mirror: FAILED"
  exit 1
fi
echo "mirror: OK"
