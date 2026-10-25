#!/usr/bin/env bash
# workflow-contract.test.sh — source-contract checks on this repository's
# workflows, pins and provenance (kioskit#137 AC-6, AC-15, AC-16).
#
# Ported from kioskd's test/publish-workflow-contract.test.sh and extended. A
# wiring defect in a workflow (a broadened token, a mutable action reference, a
# step that runs the downloaded binary before it is verified, a mirror that
# gains a push trigger) would widen what a caller's job or the mirror can do
# while every behavioural test stayed green, so these rules are asserted
# against the YAML itself.
#
# ROOT_OVERRIDE points the test at a copy of the repository; the mutation
# harness (test/contract-mutations.test.sh) uses it to prove each rule fails.
# No pipefail: checks pipe into `grep -q`, which exits early and would turn an
# upstream SIGPIPE into a false failure.
# The literal "$RUNNER_TEMP" / "${{" strings below are matched, not expanded.
# shellcheck disable=SC2016
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="${ROOT_OVERRIDE:-$(cd "$HERE/.." && pwd)}"
WFD="$ROOT/.github/workflows"
PUB="$WFD/kioskit-publish.yml"
VAL="$WFD/kioskit-validate.yml"
MIR="$WFD/mirror.yml"
CI="$WFD/ci.yml"
STORE="$ROOT/release-trusted-keys.json"

fail=0
ok() { echo "  ✓ $1"; }
no() {
  echo "  ✗ $1"
  fail=1
}

command -v yq >/dev/null 2>&1 || {
  echo "workflow-contract: yq (mikefarah v4) required" >&2
  exit 2
}
command -v jq >/dev/null 2>&1 || {
  echo "workflow-contract: jq required" >&2
  exit 2
}
for f in "$PUB" "$VAL" "$MIR" "$CI" "$STORE"; do
  [ -f "$f" ] || {
    echo "workflow-contract: not found: $f" >&2
    exit 1
  }
done

runs() { yq -r '.. | select(tag == "!!map") | select(has("run")) | .run' "$1"; }
# body FILE — the YAML without comments, so prose explaining a rule never trips it.
body() { yq '... comments = ""' "$1"; }
step_count() { yq -r ".jobs.\"$2\".steps | length" "$1"; }

echo "── every workflow: hygiene ──"
for wf in "$WFD"/*.yml; do
  n="$(basename "$wf")"
  if body "$wf" | grep -q 'pull_request_target'; then no "$n: pull_request_target must never appear"; else ok "$n: no pull_request_target"; fi
  if [ "$(yq -r '.permissions | tag' "$wf")" = "!!map" ] && [ "$(yq -r '.permissions | length' "$wf")" = "0" ]; then
    ok "$n: top-level permissions are {}"
  else
    no "$n: top-level permissions must be exactly {}"
  fi
  uses="$(yq -r '.. | select(tag == "!!map") | select(has("uses")) | .uses' "$wf")"
  while IFS= read -r u; do
    [ -z "$u" ] && continue
    case "$u" in
      ./*) ok "$n: local action $u" ;;
      *) if printf '%s' "$u" | grep -Eq '^[^@]+@[0-9a-f]{40}$'; then ok "$n: pinned $u"; else no "$n: not pinned to a 40-hex commit SHA: $u"; fi ;;
    esac
  done <<<"$uses"
  n_co="$(yq -r '[.. | select(tag == "!!map") | select(has("uses")) | select(.uses | test("^actions/checkout@"))] | length' "$wf")"
  n_np="$(yq -r '[.. | select(tag == "!!map") | select(has("uses")) | select(.uses | test("^actions/checkout@")) | select(.with."persist-credentials" == false)] | length' "$wf")"
  if [ "$n_co" = "$n_np" ]; then ok "$n: all $n_co checkout(s) set persist-credentials: false"; else no "$n: $n_np of $n_co checkout(s) set persist-credentials: false"; fi
  if runs "$wf" | grep -q '\${{'; then no "$n: a run: script expands \${{ }} directly; route values through env:"; else ok "$n: run: scripts take every value through env:"; fi
  if [ "$(yq -r '[.. | select(tag == "!!map") | select(has("continue-on-error"))] | length' "$wf")" = "0" ]; then
    ok "$n: no continue-on-error"
  else
    no "$n: continue-on-error must not be used"
  fi
done

echo "── pins: identical, well-formed, anchored in the trust store ──"
PIN_KEYS="PUBLISHER_KEY_ID,PUBLISHER_PUBKEY_B64,PUBLISHER_SHA256,PUBLISHER_VERSION"
for wf in "$PUB" "$VAL"; do
  n="$(basename "$wf")"
  keys="$(yq -r '.env // {} | keys | sort | join(",")' "$wf")"
  [ "$keys" = "$PIN_KEYS" ] && ok "$n: workflow env is exactly the four pins" || no "$n: workflow env keys are [$keys], want [$PIN_KEYS]"
done
for k in PUBLISHER_VERSION PUBLISHER_SHA256 PUBLISHER_KEY_ID PUBLISHER_PUBKEY_B64; do
  a="$(yq -r ".env.$k // \"\"" "$PUB")"
  b="$(yq -r ".env.$k // \"\"" "$VAL")"
  [ "$a" = "$b" ] && ok "$k is identical in kioskit-publish.yml and kioskit-validate.yml" ||
    no "$k differs: kioskit-publish.yml=[$a] kioskit-validate.yml=[$b]"
done
for k in PUBLISHER_KEY_ID PUBLISHER_PUBKEY_B64; do
  a="$(yq -r ".env.$k // \"\"" "$PUB")"
  m="$(yq -r ".env.$k // \"\"" "$MIR")"
  [ "$a" = "$m" ] && ok "$k is identical in mirror.yml" || no "$k differs: kioskit-publish.yml=[$a] mirror.yml=[$m]"
done
V="$(yq -r '.env.PUBLISHER_VERSION // ""' "$PUB")"
H="$(yq -r '.env.PUBLISHER_SHA256 // ""' "$PUB")"
K="$(yq -r '.env.PUBLISHER_KEY_ID // ""' "$PUB")"
P="$(yq -r '.env.PUBLISHER_PUBKEY_B64 // ""' "$PUB")"
printf '%s' "$V" | grep -Eqx '[0-9]+\.[0-9]+\.[0-9]+' && ok "PUBLISHER_VERSION is X.Y.Z ($V)" || no "PUBLISHER_VERSION is not X.Y.Z: [$V]"
printf '%s' "$H" | grep -Eqx '[0-9a-f]{64}' && ok "PUBLISHER_SHA256 is 64 lowercase hex" || no "PUBLISHER_SHA256 is not 64 lowercase hex: [$H]"
printf '%s' "$K" | grep -Eqx '[a-z0-9][a-z0-9-]*' && ok "PUBLISHER_KEY_ID is a key id ($K)" || no "PUBLISHER_KEY_ID is malformed: [$K]"
printf '%s' "$P" | grep -Eqx '[A-Za-z0-9+/]{43}=' && ok "PUBLISHER_PUBKEY_B64 is a raw ed25519 key in base64" || no "PUBLISHER_PUBKEY_B64 is malformed: [$P]"
store_pub="$(jq -r --arg k "$K" '.keys[$k] | select(.status == "active" and .profile == "ed25519-detached-v1") | .public_key_base64' "$STORE" 2>/dev/null)"
[ -n "$P" ] && [ "$store_pub" = "$P" ] && ok "PUBLISHER_PUBKEY_B64 equals the active $K key in release-trusted-keys.json" ||
  no "PUBLISHER_PUBKEY_B64 is not the active $K key in release-trusted-keys.json"

# check_consumer FILE MODE  — MODE is publish or validate.
check_consumer() {
  local wf="$1" mode="$2" n job perms want_perms inputs secrets envs i count verify_i self_ok id uses run
  n="$(basename "$wf")"
  echo "── $n ($mode) ──"
  [ "$(yq -r '.on | keys | join(",")' "$wf")" = "workflow_call" ] && ok "reusable only (on: workflow_call)" || no "must trigger only on workflow_call"
  inputs="$(yq -r '.on.workflow_call.inputs // {} | keys | join(",")' "$wf")"
  if [ "$mode" = publish ]; then
    [ "$inputs" = "parallelism" ] && ok "the only input is parallelism (no destination input)" ||
      no "inputs are [$inputs]; only 'parallelism' is allowed — a new input needs a contract review"
    want_perms="contents=read,id-token=write"
  else
    [ -z "$inputs" ] && ok "no inputs" || no "inputs are [$inputs]; validate takes none"
    want_perms="contents=read"
    body "$wf" | grep -q 'id-token' && no "id-token must not appear in the validate workflow" || ok "no id-token anywhere"
  fi
  secrets="$(yq -r '.on.workflow_call.secrets // {} | keys | join(",")' "$wf")"
  [ -z "$secrets" ] && ok "declares no secrets" || no "declares secrets [$secrets]; callers pass none"
  body "$wf" | grep -q 'secrets\.' && no "references secrets.*" || ok "references no secrets.*"
  [ "$(yq -r '.jobs | length' "$wf")" = "1" ] && ok "exactly one job" || no "must have exactly one job"
  job="$(yq -r '.jobs | keys | .[0]' "$wf")"
  perms="$(yq -r ".jobs.\"$job\".permissions // {} | to_entries | map(.key + \"=\" + .value) | sort | join(\",\")" "$wf")"
  [ "$perms" = "$want_perms" ] && ok "job $job permissions are exactly $want_perms" || no "job $job permissions are [$perms], want exactly $want_perms"
  [ "$(yq -r '[.. | select(tag == "!!map") | select(has("cancel-in-progress"))] | length' "$wf")" = "0" ] &&
    ok "no cancel-in-progress" || no "cancel-in-progress must not be used"
  envs="$(yq -r '.jobs[].steps[] | select(has("env")) | .env | keys | .[]' "$wf" |
    grep -Ev '^(WORKFLOW_REPOSITORY|WORKFLOW_REF|WORKFLOW_SHA|PUBLISH_PARALLELISM)$' || true)"
  [ -z "$envs" ] && ok "step env carries only the allowlisted variables" ||
    no "unexpected step env variable(s): $(echo "$envs" | tr '\n' ' ')— nothing may configure the destination"
  if runs "$wf" | grep -Eiq -- '--api|base-url|https?://|KIOSKIT_API'; then
    no "a run: script names a URL or destination flag"
  else
    ok "run: scripts pass no URL or destination flag"
  fi
  if [ "$(yq -r "[.jobs.\"$job\".steps[] | select(has(\"if\"))] | length" "$wf")" = "0" ]; then
    ok "no step-level if: (nothing runs after a failed verification)"
  else
    no "a step has an if: condition; a failed verification must stop the job"
  fi

  # Verify-before-run. The only things allowed before the verify step are
  # checkouts, the 'self' step (resolves this workflow's own commit) and the
  # 'fetch' step, whose command is pinned exactly. The downloaded binary is
  # executed only through the path the verify step installs.
  count="$(step_count "$wf" "$job")"
  verify_i=-1
  for ((i = 0; i < count; i++)); do
    [ "$(yq -r ".jobs.\"$job\".steps[$i].id // \"\"" "$wf")" = "verify" ] && verify_i=$i && break
  done
  if [ "$verify_i" -lt 0 ]; then
    no "no step with id: verify"
  else
    run="$(yq -r ".jobs.\"$job\".steps[$verify_i].run // \"\"" "$wf")"
    printf '%s' "$run" | grep -q 'scripts/verify-publisher.sh' && printf '%s' "$run" | grep -q -- '--install "\$RUNNER_TEMP/kioskit-publisher/bin/kioskit-publish"' &&
      ok "step $verify_i (verify) runs scripts/verify-publisher.sh and installs the verified binary" ||
      no "the verify step must run scripts/verify-publisher.sh --install \"\$RUNNER_TEMP/kioskit-publisher/bin/kioskit-publish\""
    self_ok=1
    for ((i = 0; i < verify_i; i++)); do
      id="$(yq -r ".jobs.\"$job\".steps[$i].id // \"\"" "$wf")"
      uses="$(yq -r ".jobs.\"$job\".steps[$i].uses // \"\"" "$wf")"
      run="$(yq -r ".jobs.\"$job\".steps[$i].run // \"\"" "$wf")"
      case "$uses" in actions/checkout@*) continue ;; esac
      if [ "$id" = "self" ] && [ -z "$uses" ] && ! printf '%s' "$run" | grep -q 'kioskit-publisher'; then continue; fi
      if [ "$id" = "fetch" ] && [ -z "$uses" ] &&
        [ "$run" = 'bash .kioskit-publish/scripts/fetch-publisher.sh --version "$PUBLISHER_VERSION" --out "$RUNNER_TEMP/kioskit-publisher"' ]; then
        continue
      fi
      no "step $i ($(yq -r ".jobs.\"$job\".steps[$i].name // \"unnamed\"" "$wf")) runs before verification and is not an allowed checkout/self/fetch step"
      self_ok=0
    done
    [ "$self_ok" = 1 ] && ok "nothing before the verify step can execute the binary"
    for ((i = verify_i + 1; i < count; i++)); do
      [ -n "$(yq -r ".jobs.\"$job\".steps[$i].uses // \"\"" "$wf")" ] && no "step $i uses an action after verification" && continue
    done
    run="$(yq -r ".jobs.\"$job\".steps[$((count - 1))].run // \"\"" "$wf")"
    if [ "$mode" = publish ]; then
      want='"$RUNNER_TEMP/kioskit-publisher/bin/kioskit-publish" publish --repo-root state --parallelism "$PUBLISH_PARALLELISM"'
    else
      want='"$RUNNER_TEMP/kioskit-publisher/bin/kioskit-publish" validate --repo-root state'
    fi
    [ "$run" = "$want" ] && ok "the last step runs the verified binary: ${want#*bin/}" || no "the last step must be exactly: $want"
    [ "$verify_i" = "$((count - 2))" ] && ok "the verify step immediately precedes the run step" || no "the verify step must immediately precede the run step"
  fi
}
check_consumer "$PUB" publish
check_consumer "$VAL" validate

echo "── fetch-publisher.sh downloads only from this repository's releases ──"
FETCH="$ROOT/scripts/fetch-publisher.sh"
if [ -f "$FETCH" ] && grep -qx 'BASE_URL="https://github.com/JonathanPorta/kioskit-publish/releases/download"' "$FETCH" &&
  [ "$(grep -Ec 'https?://' "$FETCH")" = "1" ]; then
  ok "the only URL is https://github.com/JonathanPorta/kioskit-publish/releases/download"
else
  no "scripts/fetch-publisher.sh must name exactly one URL, this repository's releases/download"
fi

echo "── mirror.yml: workflow_dispatch only, one scoped credential ──"
trig="$(yq -r '.on | keys | join(",")' "$MIR")"
for t in repository_dispatch push schedule; do
  [ "$(yq -r ".on | has(\"$t\")" "$MIR")" = "true" ] && no "mirror.yml must not trigger on $t (AC-15: kioskd holds no credential; the owner dispatches)" ||
    ok "mirror.yml has no $t trigger"
done
[ "$trig" = "workflow_dispatch" ] && ok "mirror.yml triggers only on workflow_dispatch" || no "mirror.yml triggers are [$trig], want exactly workflow_dispatch"
minputs="$(yq -r '.on.workflow_dispatch.inputs // {} | keys | sort | join(",")' "$MIR")"
[ "$minputs" = "resume,version" ] && ok "inputs are exactly version and resume" || no "mirror.yml inputs are [$minputs], want exactly resume,version"
[ "$(yq -r '.on.workflow_dispatch.inputs.resume.type + "/" + (.on.workflow_dispatch.inputs.resume.default | tostring)' "$MIR")" = "boolean/false" ] &&
  ok "resume is a boolean that defaults to false (a normal run is fresh)" || no "resume must be type boolean, default false"
mkeys="$(yq -r '.env // {} | keys | sort | join(",")' "$MIR")"
[ "$mkeys" = "PUBLISHER_KEY_ID,PUBLISHER_PUBKEY_B64" ] && ok "mirror.yml env is exactly the key pins" || no "mirror.yml env keys are [$mkeys]"
nsec="$(body "$MIR" | grep -o 'secrets\.[A-Za-z0-9_]*' | sort -u | tr '\n' ' ')"
[ "$nsec" = "secrets.KIOSKD_RELEASE_READ_TOKEN " ] && [ "$(body "$MIR" | grep -c 'secrets\.')" = "1" ] &&
  ok "exactly one secret reference: secrets.KIOSKD_RELEASE_READ_TOKEN" || no "secret references are [$nsec]; want exactly one secrets.KIOSKD_RELEASE_READ_TOKEN"
tjob="$(yq -r '.jobs | to_entries | map(select(.value.steps[]? | (.env // {}) | to_entries[] | .value | test("secrets\\."))) | .[].key' "$MIR" | sort -u)"
tstep="$(yq -r '.jobs[].steps[] | select((.env // {}) | to_entries[] | .value | test("secrets\\.")) | .id // ""' "$MIR")"
if [ "$(printf '%s\n' "$tjob" | grep -c .)" = "1" ] && [ "$tstep" = "fetch" ]; then
  ok "only step 'fetch' of job $tjob sees the token (step-level env)"
  [ "$(yq -r ".jobs.\"$tjob\".environment" "$MIR")" = "mirror" ] && ok "job $tjob runs in Environment mirror" || no "job $tjob must run in Environment mirror"
  tperms="$(yq -r ".jobs.\"$tjob\".permissions // {} | to_entries | map(.key + \"=\" + .value) | sort | join(\",\")" "$MIR")"
  [ "$tperms" = "contents=read" ] && ok "job $tjob has only contents:read" || no "job $tjob permissions are [$tperms], want contents=read"
  [ "$(yq -r ".jobs.\"$tjob\" | has(\"env\")" "$MIR")" = "false" ] || no "job $tjob must not set job-level env"
  for j in $(yq -r '.jobs | keys | .[]' "$MIR"); do
    [ "$j" = "$tjob" ] && continue
    yq -r ".jobs.\"$j\".needs // [] | .. | select(tag == \"!!str\")" "$MIR" | grep -qx "$tjob" &&
      ok "job $j needs $tjob (nothing is written unless verification passed)" || no "job $j must need $tjob"
  done
else
  no "the token must be in the env of exactly one step, id fetch (found jobs [$tjob], steps [$tstep])"
fi
for j in $(yq -r '.jobs | keys | .[]' "$MIR"); do
  yq -r ".jobs.\"$j\".if // \"\"" "$MIR" | grep -q "github.ref == 'refs/heads/main'" &&
    ok "job $j runs only from refs/heads/main" || no "job $j must be guarded by github.ref == 'refs/heads/main'"
  [ "$(yq -r ".jobs.\"$j\".permissions | tag" "$MIR")" = "!!map" ] || no "job $j must declare permissions"
done
if runs "$MIR" | grep -Eq 'git tag (-f|--force)|push (-f|--force)|--force-with-lease|\+refs/|git push[^|]*--tags|--clobber'; then
  no "mirror.yml must never move or overwrite a tag or asset (AC-17)"
else
  ok "mirror.yml never force-moves a tag or clobbers an asset"
fi
runs "$MIR" | grep -q 'scripts/mirror-release.sh' && ok "the release is created through scripts/mirror-release.sh (guarded)" || no "mirror.yml must create the release through scripts/mirror-release.sh"
runs "$MIR" | grep -q 'scripts/mirror-guard.sh .*--mode "\$MODE"' && runs "$MIR" | grep -q -- '--target "\$TARGET" --mode "\$MODE"' &&
  [ "$(yq -r '[.jobs[].steps[] | select(.env.MODE != null) | .env.MODE] | unique | join("|")' "$MIR")" = "\${{ inputs.resume && 'resume' || 'fresh' }}" ] && ok "guard and release take --mode from the resume input only" || no "guard and release must pass --mode \"\$MODE\" with MODE from inputs.resume"
runs "$MIR" | grep -q 'scripts/mirror-guard.sh' && ok "mirror.yml refuses an existing tag/release before fetching" || no "mirror.yml must run scripts/mirror-guard.sh before fetching"

echo "── ci.yml runs make check on pull requests ──"
[ "$(yq -r '.on | has("pull_request")' "$CI")" = "true" ] && ok "ci.yml triggers on pull_request" || no "ci.yml must trigger on pull_request"
runs "$CI" | grep -qx 'make check' && ok "ci.yml runs make check" || no "ci.yml must run make check"
runs "$CI" | grep -qx 'make test' && ok "ci.yml runs make test" || no "ci.yml must run make test"

echo "── provenance for the pinned version (AC-16) ──"
PROV="$ROOT/provenance/v$V.json"
RC="$ROOT/provenance/v$V.release-candidate.json"
if [ ! -f "$PROV" ] || [ ! -f "$RC" ] || [ ! -f "$RC.sig" ]; then
  no "provenance/v$V.json, provenance/v$V.release-candidate.json and its .sig must exist for the pinned version"
else
  if bash "$ROOT/scripts/signing/verify.sh" --profile ed25519-detached-v1 --input "$RC" --signature "$RC.sig" \
    --trust-store "$STORE" --key-id "$K" 2>/dev/null; then
    ok "provenance/v$V.release-candidate.json is signed by $K"
    bad="$(jq -r --slurpfile m "$RC" --arg v "$V" --arg h "$H" '
      ($m[0]) as $c |
      [ (if .schema == "blessed/public-github-mirror-provenance/v1" then empty else "schema" end),
        (if .source_repo == "JonathanPorta/kioskd" then empty else "source_repo" end),
        (if .source_ref == ("v" + $v) then empty else "source_ref" end),
        (if (.source_sha | type) == "string" and (.source_sha | test("^[0-9a-f]{40}$")) and .source_sha == $c.source_sha then empty else "source_sha (must equal the signed manifest source_sha)" end),
        (if .mirror_repo == "JonathanPorta/kioskit-publish" then empty else "mirror_repo" end),
        (if .mirror_ref == ("v" + $v) then empty else "mirror_ref" end),
        (if (.built_at | type) == "string" and (.built_at | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:]{8}Z$")) then empty else "built_at" end),
        (if (.public_files | type) == "array" and (.public_files | index("kioskit-publish_" + $v + "_linux_amd64")) != null then empty else "public_files" end),
        (if $c.version == $v and $c.tag == ("v" + $v) then empty else "signed manifest version/tag" end),
        (if ([$c.artifacts[] | select(.id == "linux-amd64-kioskit-publish" and .filename == ("kioskit-publish_" + $v + "_linux_amd64") and .sha256 == $h)] | length) == 1 then empty else "signed manifest does not list the pinned PUBLISHER_SHA256" end)
      ] | join(", ")' "$PROV" 2>&1)"
    [ -z "$bad" ] && ok "provenance/v$V.json matches the signed manifest (source_sha, refs, pinned digest)" || no "provenance/v$V.json: $bad"
  else
    no "provenance/v$V.release-candidate.json.sig does not verify with $K from release-trusted-keys.json"
  fi
fi

if [ "$fail" -ne 0 ]; then
  echo "workflow-contract: FAILED"
  exit 1
fi
echo "workflow-contract: OK"
