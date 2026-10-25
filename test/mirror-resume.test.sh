#!/usr/bin/env bash
# mirror-resume.test.sh — kioskit#137 review F4: a mirror run that fails after
# creating the release can be finished safely, and AC-17 still holds.
#
# Each "run" replays mirror.yml's write path against a fresh clone of a local
# bare `origin`, with `gh` replaced by a stub that keeps tags, release assets
# and PRs in a temp directory:
#   guard (fetch job)  scripts/mirror-guard.sh --mode MODE
#   release job        scripts/mirror-release.sh --mode MODE ...
#                      scripts/render-promotion.sh
#                      scripts/open-promotion-pr.sh
# Scenario A: the run dies right after the release is created.
# Scenario B: the run dies after pushing the promotion branch (PR API failure).
# Each recovery must yield exactly one promotion PR, with the tag and every
# release asset unchanged and no second release create.
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
REPO=JonathanPorta/kioskit-publish

# ── gh stub ──
mkdir -p "$TMP/bin"
cat >"$TMP/bin/gh" <<'EOF'
#!/usr/bin/env bash
S="${GH_STUB_STATE:?}"
mkdir -p "$S/tags" "$S/assets" "$S/prs"
echo "gh $*" >>"$S/calls"
nf() { echo "gh: Not Found (HTTP 404)" >&2; exit 1; }
case "$1" in
  auth) exit 0 ;;
  api)
    if [ "$2" = --paginate ]; then for d in "$S"/assets/*; do [ -d "$d" ] && basename "$d"; done; exit 0; fi
    case "$2" in
      */git/ref/tags/*) t="${2##*/}"; [ -f "$S/tags/$t" ] || nf; echo "{\"object\":{\"sha\":\"$(cat "$S/tags/$t")\"}}" ;;
      */releases/tags/*) t="${2##*/}"; [ -d "$S/assets/$t" ] && [ -f "$S/tags/$t" ] || nf
        if [ "${3:-}" = --jq ]; then ls "$S/assets/$t"; else echo '{}'; fi ;;
      *) nf ;;
    esac ;;
  release)
    case "$2" in
      create)
        t="$3"; shift 3; files=(); target=""
        while [ $# -gt 0 ]; do
          case "$1" in --target) target="$2"; shift 2 ;; --repo|--title|--notes-file) shift 2 ;; *) files+=("$1"); shift ;; esac
        done
        [ -f "$S/tags/$t" ] && { echo "tag exists" >&2; exit 1; }
        echo "create $t $target" >>"$S/creates"; echo "$target" >"$S/tags/$t"
        mkdir -p "$S/assets/$t"; cp "${files[@]}" "$S/assets/$t/" ;;
      download)
        t="$3"; dir=""; while [ $# -gt 0 ]; do [ "$1" = --dir ] && dir="$2"; shift; done
        [ -d "$S/assets/$t" ] || nf; mkdir -p "$dir"; cp "$S/assets/$t"/* "$dir/" ;;
    esac ;;
  pr)
    case "$2" in
      list)
        head=""; while [ $# -gt 0 ]; do [ "$1" = --head ] && head="$2"; shift; done
        for p in "$S"/prs/*; do [ -f "$p" ] && [ "$(cat "$p")" = "$head" ] && echo "https://github.com/x/pull/$(basename "$p")"; done; exit 0 ;;
      create)
        [ "${GH_STUB_FAIL_PR_CREATE:-}" = 1 ] && { echo "gh: Server Error (HTTP 502)" >&2; exit 1; }
        head=""; while [ $# -gt 0 ]; do [ "$1" = --head ] && head="$2"; shift; done
        n=$(( $(ls "$S/prs" | wc -l) + 1 )); echo "$head" >"$S/prs/$n"; echo "https://github.com/x/pull/$n" ;;
    esac ;;
  *) echo "gh stub: unhandled: $*" >&2; exit 3 ;;
esac
EOF
chmod +x "$TMP/bin/gh"
export PATH="$TMP/bin:$PATH"

mkdir -p "$TMP/keys"
fx_keygen "$TMP/keys" good || exit 2
GOOD_PUB="$(cat "$TMP/keys/good.pub")"
fx_release "$TMP/cand" "$TMP/keys/good.pem"
V="$FIXTURE_VERSION"

# A repository whose pins and trust store use the fixture key, as `origin`.
seed_origin() { # $1 = scenario dir
  local d="$1" w="$1/seed"
  mkdir -p "$w"
  cp -R "$FX_ROOT/.github" "$FX_ROOT/scripts" "$FX_ROOT/provenance" "$w/"
  fx_trust_store "$GOOD_PUB" "$w/release-trusted-keys.json"
  for f in kioskit-publish.yml kioskit-validate.yml mirror.yml; do
    sed -E -e "s|^  PUBLISHER_KEY_ID: \"[^\"]*\"$|  PUBLISHER_KEY_ID: \"$FIXTURE_KEY_ID\"|" \
      -e "s|^  PUBLISHER_PUBKEY_B64: \"[^\"]*\"$|  PUBLISHER_PUBKEY_B64: \"$GOOD_PUB\"|" "$w/.github/workflows/$f" >"$w/x" && mv "$w/x" "$w/.github/workflows/$f"
  done
  git init -q --bare "$d/origin.git"
  (cd "$w" && git init -q -b main && git add -A && git -c user.name=t -c user.email=t@t commit -qm seed &&
    git remote add origin "$d/origin.git" && git push -q origin main)
}

# run_job SCENARIO MODE [FAIL_AT] — one dispatch of mirror.yml's write path.
run_job() {
  local d="$1" mode="$2" fail_at="${3:-}" n w
  n=$(($(cat "$d/.runs" 2>/dev/null || echo 0) + 1))
  echo "$n" >"$d/.runs"
  w="$d/run$n"
  git clone -q --depth 1 -b main "file://$d/origin.git" "$w"
  (
    cd "$w" || exit 9
    export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
    # Explicit `|| exit`: set -e is inert in a subshell whose status is tested.
    bash scripts/mirror-guard.sh --repo "$REPO" --version "$V" --mode "$mode" || exit 1
    bash scripts/mirror-release.sh --repo "$REPO" --version "$V" --dir "$TMP/cand" --target "$(git rev-parse HEAD)" \
      --mode "$mode" --key-id "$FIXTURE_KEY_ID" --pubkey-b64 "$GOOD_PUB" --trust-store release-trusted-keys.json || exit 1
    if [ "$fail_at" = after-release ]; then
      echo "injected failure after release creation" >&2
      exit 70
    fi
    bash scripts/render-promotion.sh --root . --dir "$TMP/cand" --version "$V" || exit 1
    bash scripts/open-promotion-pr.sh --repo "$REPO" --version "$V" || exit 1
  ) >"$w.log" 2>&1
}

snapshot() { # tag sha + asset digests
  local s="$GH_STUB_STATE"
  { cat "$s/tags/v$V" 2>/dev/null; (cd "$s/assets/v$V" 2>/dev/null && shasum ./*); } | shasum | cut -c1-16
}
prs() { find "$GH_STUB_STATE/prs" -type f 2>/dev/null | wc -l | tr -d ' '; }
creates() { wc -l <"$GH_STUB_STATE/creates" 2>/dev/null | tr -d ' ' || echo 0; }
branch_sha() { git --git-dir="$1/origin.git" rev-parse -q --verify "refs/heads/promote/v$V" || echo none; }

echo "── scenario A: failure right after the release is created ──"
A="$TMP/A"
mkdir -p "$A"
export GH_STUB_STATE="$A/gh"
seed_origin "$A" >/dev/null 2>&1
run_job "$A" fresh after-release
[ "$(creates)" = 1 ] && [ "$(prs)" = 0 ] && [ "$(branch_sha "$A")" = none ] && ok "run 1 (fresh) created the release, then died: no branch, no PR" ||
  no "run 1 state unexpected: creates=$(creates) prs=$(prs): $(tail -n 2 "$A/run1.log")"
SNAP="$(snapshot)"
if run_job "$A" fresh; then no "run 2 (fresh) SUCCEEDED for an existing version"; else
  grep -q "refused: tag v$V already exists" "$A/run2.log" && ok "run 2 (fresh, no resume) is still refused (AC-17): $(grep -o 'refused: tag.*' "$A/run2.log")" ||
    no "run 2 failed for another reason: $(tail -n 2 "$A/run2.log")"
fi
if run_job "$A" resume; then
  ok "run 3 (resume): $(grep -o 'resume — .*' "$A/run3.log")"
else
  no "run 3 (resume) failed: $(tail -n 3 "$A/run3.log")"
fi
[ "$(prs)" = 1 ] && ok "exactly one promotion PR (head promote/v$V)" || no "promotion PRs: $(prs)"
run_job "$A" resume && [ "$(prs)" = 1 ] && grep -q 'already exists' "$A/run4.log" &&
  ok "run 4 (resume again) finds the existing PR; still exactly one" || no "run 4: prs=$(prs): $(tail -n 2 "$A/run4.log")"
[ "$(snapshot)" = "$SNAP" ] && [ "$(creates)" = 1 ] && ok "tag and all release assets unchanged; one release create in total" ||
  no "tag/assets changed or extra create (creates=$(creates))"
git --git-dir="$A/origin.git" show "promote/v$V:provenance/v$V.json" 2>/dev/null | jq -e --arg s "$FIXTURE_SOURCE_SHA" '.source_sha == $s' >/dev/null &&
  ok "the PR branch carries the re-rendered provenance/v$V.json" || no "promotion branch lacks provenance/v$V.json"

echo "── scenario B: failure after the branch was pushed (PR API error) ──"
B="$TMP/B"
mkdir -p "$B"
export GH_STUB_STATE="$B/gh"
seed_origin "$B" >/dev/null 2>&1
if GH_STUB_FAIL_PR_CREATE=1 run_job "$B" fresh; then no "run 1 should have failed at PR creation"; fi
BR="$(branch_sha "$B")"
[ "$BR" != none ] && [ "$(prs)" = 0 ] && [ "$(creates)" = 1 ] && ok "run 1 (fresh) created the release and pushed promote/v$V, then the PR call failed" ||
  no "run 1 state unexpected: branch=$BR prs=$(prs): $(tail -n 2 "$B/run1.log")"
SNAP="$(snapshot)"
if run_job "$B" resume; then
  grep -q 'reusing it' "$B/run2.log" && ok "run 2 (resume) reused the pushed branch and opened the PR" || no "run 2 did not reuse the branch: $(tail -n 3 "$B/run2.log")"
else
  no "run 2 (resume) failed: $(tail -n 3 "$B/run2.log")"
fi
[ "$(prs)" = 1 ] && [ "$(branch_sha "$B")" = "$BR" ] && ok "exactly one promotion PR; branch tip unchanged ($(printf '%.12s' "$BR"))" ||
  no "prs=$(prs), branch moved to $(branch_sha "$B")"
[ "$(snapshot)" = "$SNAP" ] && [ "$(creates)" = 1 ] && ok "tag and all release assets unchanged; one release create in total" || no "tag/assets changed"

echo "── resume refuses what it must not finish ──"
C="$TMP/C"
mkdir -p "$C"
export GH_STUB_STATE="$C/gh"
seed_origin "$C" >/dev/null 2>&1
if run_job "$C" resume; then no "resume with no release succeeded"; else
  grep -q 'resume needs an existing tag' "$C/run1.log" && ok "resume with no tag/release is refused (it never creates one)" || no "unexpected: $(tail -n 2 "$C/run1.log")"
fi
run_job "$C" fresh after-release
printf 'x' >>"$C/gh/assets/v$V/SHA256SUMS"
if run_job "$C" resume; then no "resume accepted an altered asset"; else
  grep -Eq 'FAILED \[sha256sums\]|does not verify|differs' "$C/run3.log" && ok "resume refuses an existing asset that differs: $(grep -Eo 'refused: .*' "$C/run3.log" | head -n 1)" ||
    no "unexpected: $(tail -n 2 "$C/run3.log")"
fi
D="$TMP/D"
mkdir -p "$D"
export GH_STUB_STATE="$D/gh"
seed_origin "$D" >/dev/null 2>&1
run_job "$D" fresh after-release
(cd "$D/seed" && git switch -q -c "promote/v$V" && echo other >README-other && git add README-other &&
  git -c user.name=t -c user.email=t@t commit -qm other && git push -q origin "promote/v$V") >/dev/null 2>&1
if run_job "$D" resume; then no "resume reused a branch with different content"; else
  grep -q 'differs from the render' "$D/run2.log" && ok "a pushed branch with different content is refused, not overwritten" || no "unexpected: $(tail -n 2 "$D/run2.log")"
fi
[ "$(prs)" = 0 ] && ok "no PR was opened for the mismatching branch" || no "a PR was opened"

# A branch that carries the five rendered files byte for byte, plus one more
# change on top, must still be refused: reuse requires the branch's COMPLETE
# diff against main to be the rendered set.
tamper_branch() { # $1 = scenario dir, $2 = description, $3.. = commands run in a clone of the branch
  local d="$1" what="$2" c="$1/tamper"
  shift 2
  git clone -q -b "promote/v$V" "file://$d/origin.git" "$c" &&
    (cd "$c" && "$@" && git -c user.name=t -c user.email=t@t commit -qm "$what" && git push -q origin "promote/v$V")
}
for kind in extra deleted; do
  E="$TMP/E-$kind"
  mkdir -p "$E"
  export GH_STUB_STATE="$E/gh"
  seed_origin "$E" >/dev/null 2>&1
  GH_STUB_FAIL_PR_CREATE=1 run_job "$E" fresh || true
  if [ "$kind" = extra ]; then
    tamper_branch "$E" "add a step" sh -c 'printf "#!/bin/sh\necho pwned\n" >extra-release-step.sh && git add extra-release-step.sh' >/dev/null 2>&1
    label="the five rendered files plus extra-release-step.sh"
  else
    tamper_branch "$E" "drop a file" git rm -q scripts/fetch-publisher.sh >/dev/null 2>&1
    label="the five rendered files plus a deleted scripts/fetch-publisher.sh"
  fi
  for p in .github/workflows/kioskit-publish.yml .github/workflows/kioskit-validate.yml "provenance/v$V.json"; do
    git --git-dir="$E/origin.git" cat-file -e "promote/v$V:$p" || no "$kind: setup lost $p"
  done
  TIP="$(branch_sha "$E")"
  if run_job "$E" resume; then
    no "$kind: resume reused a branch with $label"
  else
    grep -q 'differs from the render' "$E/run2.log" &&
      ok "$kind: a branch with $label is refused — $(grep -o 'promote/v[^ ]* changes \[.*\] against main' "$E/run2.log" | head -n 1)" ||
      no "$kind: unexpected: $(tail -n 3 "$E/run2.log")"
  fi
  [ "$(prs)" = 0 ] && [ "$(branch_sha "$E")" = "$TIP" ] && ok "$kind: no PR opened; the branch was not rewritten" || no "$kind: prs=$(prs), branch moved"
done

if [ "$fail" -ne 0 ]; then
  echo "mirror-resume: FAILED"
  exit 1
fi
echo "mirror-resume: OK"
