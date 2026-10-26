#!/usr/bin/env bash
# contract-mutations.test.sh — prove test/workflow-contract.test.sh is not
# vacuous (kioskit#137 AC-6, AC-15, AC-16). The unmodified repository must pass;
# each mutation below, applied alone to a fresh copy, must FAIL with the named
# finding.
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
CONTRACT="$HERE/workflow-contract.test.sh"

fail=0
ok() { echo "  ✓ $1"; }
no() {
  echo "  ✗ $1"
  fail=1
}
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

copy() { # -> echoes a fresh copy of the files the contract reads
  local d="$TMP/$1"
  mkdir -p "$d"
  cp -R "$ROOT/.github" "$ROOT/scripts" "$ROOT/provenance" "$ROOT/release-trusted-keys.json" "$d/"
  echo "$d"
}
P=.github/workflows/kioskit-publish.yml
V=.github/workflows/kioskit-validate.yml
M=.github/workflows/mirror.yml

# name | expected finding (grep -F) | mutation (run inside the copy)
CASES=(
  "unpinned-action|not pinned to a 40-hex commit SHA|yq -i '.jobs.publish.steps[1].uses = \"actions/checkout@v6\"' $P"
  "destination-input|only 'parallelism' is allowed|yq -i '.on.workflow_call.inputs.api_url = {\"type\": \"string\"}' $P"
  "pull-request-target|pull_request_target must never appear|yq -i '.on.pull_request_target = {}' $V"
  "id-token-in-validate|id-token must not appear in the validate workflow|yq -i '.jobs.validate.permissions.\"id-token\" = \"write\"' $V"
  "pins-differ|PUBLISHER_SHA256 differs|yq -i '.env.PUBLISHER_SHA256 = \"1111111111111111111111111111111111111111111111111111111111111111\"' $V"
  "version-pins-differ|PUBLISHER_VERSION differs|yq -i '.env.PUBLISHER_VERSION = \"0.4.0\"' $P"
  "non-hex-digest|PUBLISHER_SHA256 is not 64 lowercase hex|for f in $P $V; do yq -i '.env.PUBLISHER_SHA256 = \"ZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZ\"' \$f; done"
  "run-before-verify|runs before verification|yq -i '.jobs.publish.steps |= .[0:4] + [{\"name\": \"early\", \"run\": \"chmod +x \\\"\$RUNNER_TEMP\\\"/kioskit-publisher/kioskit-publish_* && \\\"\$RUNNER_TEMP\\\"/kioskit-publisher/kioskit-publish_*_linux_amd64 version\"}] + .[4:]' $P"
  "fetch-step-changed|runs before verification|yq -i '.jobs.validate.steps[3].run += \" && bash \\\"\$RUNNER_TEMP/kioskit-publisher/x\\\"\"' $V"
  "verify-skippable|has an if: condition|yq -i '.jobs.publish.steps[5].if = \"always()\"' $P"
  "continue-on-error|continue-on-error must not be used|yq -i '.jobs.validate.steps[4].\"continue-on-error\" = true' $V"
  "wrong-subcommand|the last step must be exactly|yq -i '.jobs.validate.steps[5].run = \"\\\"\$RUNNER_TEMP/kioskit-publisher/bin/kioskit-publish\\\" publish --repo-root state\"' $V"
  "persisted-credentials|checkout(s) set persist-credentials: false|yq -i '.jobs.publish.steps[2].with.\"persist-credentials\" = true' $P"
  "expression-in-run|expands \${{ }} directly|yq -i '.jobs.publish.steps[3].run = \"echo \${{ github.event.pull_request.title }}\"' $P"
  "broadened-permissions|permissions are [contents=read,id-token=write,packages=write]|yq -i '.jobs.publish.permissions.packages = \"write\"' $P"
  "secret-in-caller|declares secrets|yq -i '.on.workflow_call.secrets.TOKEN = {\"required\": false}' $P"
  "key-not-in-store|is not the active kioskitd-2026-01 key|for f in $P $V $M; do yq -i '.env.PUBLISHER_PUBKEY_B64 = \"mDE53Qh1ncne7aiTT9ewSH8e/9Q9z5D8GCjNZV99W40=\"' \$f; done"
  "mirror-repository-dispatch|must not trigger on repository_dispatch|yq -i '.on.repository_dispatch = {\"types\": [\"kioskd-release\"]}' $M"
  "mirror-push|must not trigger on push|yq -i '.on.push = {\"branches\": [\"main\"]}' $M"
  "mirror-schedule|must not trigger on schedule|yq -i '.on.schedule = [{\"cron\": \"0 0 * * *\"}]' $M"
  "mirror-token-wider|want exactly one secrets.KIOSKD_RELEASE_READ|yq -i '.jobs.fetch.steps[3].env.GH_TOKEN = \"\${{ secrets.KIOSKD_RELEASE_READ }}\"' $M"
  "mirror-token-job-env|secret references are [secrets.KIOSKD_RELEASE_READ secrets.OTHER ]|yq -i '.jobs.release.env.T = \"\${{ secrets.OTHER }}\"' $M"
  "mirror-no-environment|must run in Environment mirror|yq -i 'del(.jobs.fetch.environment)' $M"
  "mirror-release-without-fetch|must need fetch|yq -i 'del(.jobs.release.needs)' $M"
  "mirror-any-branch|must be guarded by github.ref|yq -i 'del(.jobs.release.if)' $M"
  "mirror-moves-tag|never move or overwrite a tag|yq -i '.jobs.release.steps[3].run += \"\ngit tag -f v1 && git push --force origin v1\"' $M"
  "mirror-resume-default-on|resume must be type boolean, default false|yq -i '.on.workflow_dispatch.inputs.resume.default = true' $M"
  "mirror-guard-always-resume|guard and release must pass --mode|yq -i '.jobs.fetch.steps[1].env.MODE = \"resume\"' $M"
  "ci-skips-tests|ci.yml must run make test|yq -i 'del(.jobs.check.steps[-1])' .github/workflows/ci.yml"
  "ci-unpinned-yq|ci.yml must install yq v4.53.2|yq -i '(.jobs.check.steps[] | select(.env.YQ_SHA256 != null) | .env.YQ_SHA256) = \"0000000000000000000000000000000000000000000000000000000000000000\"' .github/workflows/ci.yml"
  "provenance-source-sha|source_sha (must equal the signed manifest source_sha)|jq '.source_sha = \"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\"' provenance/v0.5.1.json >x && mv x provenance/v0.5.1.json"
  "provenance-missing|must exist for the pinned version|rm provenance/v0.5.1.json"
  "provenance-unsigned|does not verify with kioskitd-2026-01|jq '.created_at = \"2026-10-26T00:00:00Z\"' provenance/v0.5.1.release-candidate.json >x && mv x provenance/v0.5.1.release-candidate.json"
)

echo "── control: the unmodified repository passes ──"
d="$(copy control)"
if ROOT_OVERRIDE="$d" bash "$CONTRACT" >"$TMP/control.out" 2>&1; then ok "contract passes on the real files"; else no "contract fails on the real files: $(grep '✗' "$TMP/control.out" | head -n 3)"; fi

echo "── each mutation fails the contract ──"
for c in "${CASES[@]}"; do
  name="${c%%|*}"
  rest="${c#*|}"
  want="${rest%%|*}"
  cmd="${rest#*|}"
  d="$(copy "$name")"
  if ! (cd "$d" && eval "$cmd") >"$TMP/$name.mut" 2>&1; then
    no "$name: mutation did not apply: $(head -n 2 "$TMP/$name.mut")"
    continue
  fi
  if ROOT_OVERRIDE="$d" bash "$CONTRACT" >"$TMP/$name.out" 2>&1; then
    no "$name: contract PASSED on a mutated copy"
  elif grep -F -- "$want" "$TMP/$name.out" | grep -q '✗'; then
    ok "$name → $(grep -F -- "$want" "$TMP/$name.out" | grep '✗' | head -n 1 | sed 's/^ *✗ //')"
  else
    no "$name: failed, but not with [$want]: $(grep '✗' "$TMP/$name.out" | head -n 2 | tr '\n' ' ')"
  fi
done

if [ "$fail" -ne 0 ]; then
  echo "contract-mutations: FAILED"
  exit 1
fi
echo "contract-mutations: OK"
