#!/usr/bin/env bash
# verify-publisher.test.sh — AC-5: verify before run.
#
# Runs a test copy of each consumer workflow (kioskit-publish.yml and
# kioskit-validate.yml): the real `run:` scripts of every step from the verify
# step to the end, extracted from the YAML and executed in order the way
# Actions does (bash -eo pipefail, stop at the first failure). The download is
# replaced by a throwaway-key fixture release, and the pins by that fixture's
# values. Then one value at a time is made wrong. Each case must fail AT the
# verify step, name the check that caught it, and leave the publisher binary
# never executed and never installed.
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
mkdir -p "$TMP/keys"
fx_keygen "$TMP/keys" good || exit 2
fx_keygen "$TMP/keys" attacker || exit 2
GOOD_PUB="$(cat "$TMP/keys/good.pub")"
ATTACKER_PUB="$(cat "$TMP/keys/attacker.pub")"
fx_release "$TMP/release" "$TMP/keys/good.pem"
V="$FIXTURE_VERSION"
BIN="kioskit-publish_${V}_linux_amd64"
GOOD_SHA="$(fx_sha256 "$TMP/release/$BIN")"

# new_ws NAME -> echoes a fresh workspace laid out like the runner's:
#   <ws>/.kioskit-publish  this repository at the workflow's commit (fixture trust store)
#   <ws>/state             the caller's checkout
#   <ws>/tmp               RUNNER_TEMP, with the "downloaded" files in kioskit-publisher/
new_ws() {
  local ws="$TMP/ws-$1"
  mkdir -p "$ws/.kioskit-publish" "$ws/state" "$ws/tmp/kioskit-publisher"
  cp -R "$FX_ROOT/scripts" "$ws/.kioskit-publish/scripts"
  fx_trust_store "$GOOD_PUB" "$ws/.kioskit-publish/release-trusted-keys.json"
  cp "$TMP/release/$BIN" "$TMP/release/$BIN.sig" "$TMP/release/release-candidate.json" "$TMP/release/release-candidate.json.sig" \
    "$ws/tmp/kioskit-publisher/"
  echo "$ws"
}

# run_workflow WF WS -> runs steps verify..end; sets FAILED_STEP ("" on success) and leaves stderr in WS/stderr
run_workflow() {
  local wf="$1" ws="$2" job count i vi id run envs rc
  job="$(yq -r '.jobs | keys | .[0]' "$wf")"
  count="$(yq -r ".jobs.\"$job\".steps | length" "$wf")"
  vi=-1
  for ((i = 0; i < count; i++)); do
    [ "$(yq -r ".jobs.\"$job\".steps[$i].id // \"\"" "$wf")" = verify ] && vi=$i && break
  done
  FAILED_STEP="no-verify-step"
  [ "$vi" -ge 0 ] || return 0
  FAILED_STEP=""
  : >"$ws/stderr"
  for ((i = vi; i < count; i++)); do
    id="$(yq -r ".jobs.\"$job\".steps[$i].id // \"step$i\"" "$wf")"
    run="$(yq -r ".jobs.\"$job\".steps[$i].run // \"\"" "$wf")"
    [ -n "$run" ] || continue
    # Step env: literal values pass through; the only expression is the input.
    envs=()
    while IFS=$'\t' read -r k val; do
      [ -z "$k" ] && continue
      case "$val" in *'inputs.parallelism'*) val=4 ;; esac
      envs+=("$k=$val")
    done < <(yq -r ".jobs.\"$job\".steps[$i].env // {} | to_entries | .[] | .key + \"\t\" + (.value | tostring)" "$wf")
    (cd "$ws" && env -i PATH="$PATH" HOME="$HOME" ${OPENSSL_BIN:+OPENSSL_BIN="$OPENSSL_BIN"} \
      RUNNER_TEMP="$ws/tmp" PUBLISHER_RAN_MARKER="$ws/ran" \
      PUBLISHER_VERSION="$PIN_VERSION" PUBLISHER_SHA256="$PIN_SHA256" \
      PUBLISHER_KEY_ID="$PIN_KEY_ID" PUBLISHER_PUBKEY_B64="$PIN_PUBKEY" \
      ${envs[@]+"${envs[@]}"} bash --noprofile --norc -eo pipefail -c "$run") >>"$ws/stdout" 2>>"$ws/stderr"
    rc=$?
    if [ "$rc" -ne 0 ]; then
      FAILED_STEP="$id"
      return 0
    fi
  done
}

reset_pins() {
  PIN_VERSION="$V"
  PIN_SHA256="$GOOD_SHA"
  PIN_KEY_ID="$FIXTURE_KEY_ID"
  PIN_PUBKEY="$GOOD_PUB"
}

# ── mutations (each changes exactly one value) ──
m_digest_pin() { PIN_SHA256="$(printf 'other' | { sha256sum 2>/dev/null || shasum -a 256; } | cut -d' ' -f1)"; }
m_tampered_binary() { printf '\n# tampered\n' >>"$1/tmp/kioskit-publisher/$BIN"; }
m_binary_signature() {
  printf 'not the binary' >"$TMP/other"
  fx_sign "$TMP/keys/good.pem" "$TMP/other"
  cp "$TMP/other.sig" "$1/tmp/kioskit-publisher/$BIN.sig"
}
m_foreign_binary() {
  # A wrong pin PR: the pin names an attacker's binary, signed by the attacker.
  local d="$1/tmp/kioskit-publisher"
  fx_write_binary "$d/$BIN" attacker
  fx_sign "$TMP/keys/attacker.pem" "$d/$BIN"
  PIN_SHA256="$(fx_sha256 "$d/$BIN")"
}
m_manifest_signature() {
  local f="$1/tmp/kioskit-publisher/release-candidate.json"
  jq '.created_at = "2026-10-26T00:00:00Z"' "$f" >"$f.new" && mv "$f.new" "$f"
}
m_manifest_entry() {
  # Validly signed, but the manifest lists a different digest for the publisher.
  local f="$1/tmp/kioskit-publisher/release-candidate.json"
  jq '(.artifacts[] | select(.id == "linux-amd64-kioskit-publish") | .sha256) = "1111111111111111111111111111111111111111111111111111111111111111"' "$f" >"$f.new" && mv "$f.new" "$f"
  fx_sign "$TMP/keys/good.pem" "$f"
}
m_manifest_version() {
  local f="$1/tmp/kioskit-publisher/release-candidate.json"
  jq '.version = "9.9.9" | .tag = "v9.9.9"' "$f" >"$f.new" && mv "$f.new" "$f"
  fx_sign "$TMP/keys/good.pem" "$f"
}
m_pinned_key() { PIN_PUBKEY="$ATTACKER_PUB"; }
m_missing_sig() { rm -f "$1/tmp/kioskit-publisher/$BIN.sig"; }

CASES="digest_pin:digest tampered_binary:digest binary_signature:binary-signature foreign_binary:binary-signature
manifest_signature:manifest-signature manifest_entry:manifest-entry manifest_version:manifest-entry pinned_key:pinned-key missing_sig:download"

for mode in publish validate; do
  WF="$FX_ROOT/.github/workflows/kioskit-$mode.yml"
  echo "── kioskit-$mode.yml ──"
  [ -f "$WF" ] || {
    no "missing $WF"
    continue
  }
  if [ "$mode" = publish ]; then want_ran="ran: publish --repo-root state --parallelism 4"; else want_ran="ran: validate --repo-root state"; fi

  reset_pins
  ws="$(new_ws "$mode-control")"
  run_workflow "$WF" "$ws"
  if [ -z "$FAILED_STEP" ] && [ "$(cat "$ws/ran" 2>/dev/null)" = "$want_ran" ]; then
    ok "control: genuine release verifies and the binary runs once ($want_ran)"
  else
    no "control: expected success and '$want_ran'; failed step [$FAILED_STEP], marker [$(cat "$ws/ran" 2>/dev/null)]: $(tail -n 3 "$ws/stderr")"
  fi

  for c in $CASES; do
    name="${c%%:*}"
    check="${c#*:}"
    reset_pins
    ws="$(new_ws "$mode-$name")"
    "m_$name" "$ws"
    run_workflow "$WF" "$ws"
    if [ "$FAILED_STEP" = verify ] && grep -q "FAILED \[$check\]" "$ws/stderr" && [ ! -e "$ws/ran" ] &&
      [ ! -e "$ws/tmp/kioskit-publisher/bin/kioskit-publish" ]; then
      ok "$name: fails at verify naming [$check]; binary never ran or installed — $(grep -o "FAILED \[$check\].*" "$ws/stderr" | head -n 1)"
    else
      no "$name: want failure at verify naming [$check] with no execution; got step [$FAILED_STEP], ran [$([ -e "$ws/ran" ] && echo yes || echo no)], stderr: $(tail -n 2 "$ws/stderr" | tr '\n' ' ')"
    fi
  done
done

if [ "$fail" -ne 0 ]; then
  echo "verify-publisher: FAILED"
  exit 1
fi
echo "verify-publisher: OK"
