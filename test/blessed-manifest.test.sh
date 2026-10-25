#!/usr/bin/env bash
# blessed-manifest.test.sh — the root blessed.yml is a valid, truthful
# blessed/repo/v1 manifest (kioskit#137 review F1). Offline.
#
#   1. Structure: schema/blessed-repo.schema.json (catalog vocabularies at
#      blessed-cicd 81694f5), validated by the signed public validator
#      scripts/release/lib/lib-json-schema.sh.
#   2. Adoption (blessed policy/adoption.yml at 81694f5): every standard and
#      capability required for all make-capable repos and for repo_type
#      `library` is declared or carries an active waiver; a waiver's review_by is
#      today or later and at most 180 days away (policy max_age_days).
#   3. Truthfulness: each declared standard/capability has its evidence here
#      (Makefile core targets, release-surfaces.yaml, the verifier and trust
#      store, the SHA-pinning contract, the ai-rules subtree at the declared tag).
# Mutated copies must fail. With BLESSED_CICD_DIR=<blessed-cicd checkout> it
# also runs blessed's own catalog validator (lib-catalog.jq valid_manifest).
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
SCHEMA="$ROOT/schema/blessed-repo.schema.json"
# shellcheck source=scripts/release/lib/lib-json-schema.sh
. "$ROOT/scripts/release/lib/lib-json-schema.sh"

fail=0
ok() { echo "  ✓ $1"; }
no() {
  echo "  ✗ $1"
  fail=1
}
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# Adoption defaults (policy/adoption.yml): all make-capable repos + library.
REQUIRED_STANDARDS="makefile.core@1 makefile.profiles@1 spec-pack.core@1 spec-pack.profiles@1"
REQUIRED_CAPABILITIES="repo-protection sha-pinning"
today="$(date -u +%Y-%m-%d)"

# validate FILE ROOTDIR -> findings, one per line; empty means valid.
validate() {
  local f="$1" r="$2" json
  yq 'true' "$f" >/dev/null 2>&1 || {
    echo "not parseable as YAML"
    return
  }
  [ "$(yq '[... | select(anchor != "" or kind == "alias")] | length' "$f")" = 0 ] || echo "YAML anchors and aliases are not allowed"
  json="$(yq -o=json '.' "$f")"
  [ "$(yq -o=json '[... | select(kind == "map") | keys | length]' "$f" | jq 'add // 0')" = "$(jq '[.. | objects | keys | length] | add // 0' <<<"$json")" ] ||
    echo "duplicate mapping keys"
  printf '%s' "$json" >"$TMP/m.json"
  json_schema_validate_file "$TMP/m.json" "$SCHEMA" | sed 's/^/schema: /'
  # shellcheck disable=SC2016 # jq program
  jq -r --arg req_s "$REQUIRED_STANDARDS" --arg req_c "$REQUIRED_CAPABILITIES" --arg today "$today" '
    def days($d): ($d + "T00:00:00Z" | fromdateiso8601) / 86400 | floor;
    . as $m | (.waivers // []) as $w
    | ([$w[] | select(.standard) | .standard]) as $ws | ([$w[] | select(.capability) | .capability]) as $wc
    | ($req_s | split(" ")[] | select(. as $s | (($m.standards // []) | index($s)) == null and ($ws | index($s)) == null)
        | "required standard \(.) is neither declared nor waived"),
      ($req_c | split(" ")[] | select(. as $c | (($m.capabilities // []) | index($c)) == null and ($wc | index($c)) == null)
        | "required capability \(.) is neither declared nor waived"),
      ($w[] | select(.review_by? | type == "string" and test("^[0-9]{4}-[0-9]{2}-[0-9]{2}$"))
        | (days(.review_by) - days($today)) as $left
        | if $left < 0 then "waiver \(.standard // .capability) expired on \(.review_by)"
          elif $left > (.max_age_days // 180) then "waiver \(.standard // .capability) review_by \(.review_by) is more than \(.max_age_days // 180) days away"
          else empty end),
      ([$w[] | (.standard // .capability)] as $all | $all[] | select(. as $x | ($all | map(select(. == $x)) | length) > 1)
        | "waiver for \(.) is declared twice") ,
      (($m.standards // [])[] | select(. as $s | $ws | index($s) != null) | "standard \(.) is both declared and waived"),
      (($m.capabilities // [])[] | select(. as $c | $wc | index($c) != null) | "capability \(.) is both declared and waived")
  ' "$TMP/m.json" 2>&1 | sort -u
  # Truthfulness: evidence for each declaration.
  local std cap
  for std in $(jq -r '.standards[]?' "$TMP/m.json"); do
    case "$std" in
      makefile.core@1)
        for t in help deps install dev format check test build docs clean; do
          grep -Eq "^$t:.*## " "$r/Makefile" 2>/dev/null || echo "makefile.core@1 declared but the Makefile has no documented '$t' target"
        done ;;
      releases.surfaces@1) [ -f "$r/release-surfaces.yaml" ] || echo "releases.surfaces@1 declared but release-surfaces.yaml is missing" ;;
      signing.ed25519-detached@1)
        { [ -f "$r/scripts/signing/verify.sh" ] && [ -f "$r/release-trusted-keys.json" ]; } ||
          echo "signing.ed25519-detached@1 declared but the verifier or trust store is missing" ;;
      *) echo "standard $std is declared but this test knows no evidence for it; add a truthfulness check" ;;
    esac
  done
  for cap in $(jq -r '.capabilities[]?' "$TMP/m.json"); do
    case "$cap" in
      sha-pinning) grep -q 'not pinned to a 40-hex commit SHA' "$r/test/workflow-contract.test.sh" 2>/dev/null ||
        echo "sha-pinning declared but no contract enforces it" ;;
      ai-rules-subtree)
        [ -f "$r/.ai-rules/AGENTS.md" ] || echo "ai-rules-subtree declared but .ai-rules/AGENTS.md is missing"
        [ "tag=$(jq -r '.tracked_dependencies.ai_rules.tag // ""' "$TMP/m.json")" = "$(grep '^tag=' "$r/.ai-rules/.version" 2>/dev/null)" ] ||
          echo "tracked_dependencies.ai_rules.tag does not match .ai-rules/.version" ;;
      *) echo "capability $cap is declared but this test knows no evidence for it; add a truthfulness check" ;;
    esac
  done
}

echo "── blessed.yml ──"
out="$(validate "$ROOT/blessed.yml" "$ROOT")"
[ -z "$out" ] && ok "valid blessed/repo/v1: schema (signed public validator), adoption defaults with active waivers, evidence for every declaration" ||
  no "invalid: $(echo "$out" | tr '\n' ' ')"
yq -r '"repo_type=" + .repo_type + " stage=" + .stage + " standards=[" + (.standards | join(",")) + "] capabilities=[" + (.capabilities | join(",")) + "] waivers=[" + ([.waivers[] | (.standard // .capability)] | join(",")) + "]"' "$ROOT/blessed.yml" | sed 's/^/  · /'

echo "── the gate rejects invalid or untruthful manifests ──"
CASES=(
  "no-repo-type|repo_type|del(.repo_type)"
  "unknown-repo-type|repo_type|.repo_type = \"github-action\""
  "unknown-capability|capabilities|.capabilities += [\"teleport\"]"
  "unknown-standard|standards|.standards += [\"releases.made-up@1\"]"
  "missing-required-capability|required capability sha-pinning|.capabilities -= [\"sha-pinning\"]"
  "missing-required-standard|required standard makefile.core@1|.standards -= [\"makefile.core@1\"]"
  "waiver-without-owner|owner|del(.waivers[0].owner)"
  "expired-waiver|expired|.waivers[0].review_by = \"2026-01-01\""
  "waiver-too-long|days away|.waivers[0].review_by = \"2030-01-01\""
  "untruthful-standard|knows no evidence|.standards += [\"releases.pipeline@1\"]"
  "untruthful-capability|knows no evidence|.capabilities += [\"bwsm\"]"
  "wrong-ai-rules-tag|does not match .ai-rules/.version|.tracked_dependencies.ai_rules.tag = \"v0.1.0\""
  "extra-key|additional property|.owner = \"me\""
)
for c in "${CASES[@]}"; do
  name="${c%%|*}"
  rest="${c#*|}"
  want="${rest%%|*}"
  expr="${rest#*|}"
  yq "$expr" "$ROOT/blessed.yml" >"$TMP/$name.yml"
  out="$(validate "$TMP/$name.yml" "$ROOT")"
  if [ -n "$out" ] && grep -Fq -- "$want" <<<"$out"; then
    ok "$name → $(grep -F -- "$want" <<<"$out" | head -n 1)"
  else
    no "$name: want a finding mentioning [$want], got [$(echo "$out" | tr '\n' ' ')]"
  fi
done
mkdir -p "$TMP/nomake"
cp "$ROOT/release-surfaces.yaml" "$ROOT/release-trusted-keys.json" "$TMP/nomake/"
grep -v '^docs:' "$ROOT/Makefile" >"$TMP/nomake/Makefile"
mkdir -p "$TMP/nomake/scripts/signing" "$TMP/nomake/test" "$TMP/nomake/.ai-rules"
cp "$ROOT/scripts/signing/verify.sh" "$TMP/nomake/scripts/signing/"
cp "$ROOT/test/workflow-contract.test.sh" "$TMP/nomake/test/"
cp "$ROOT/.ai-rules/AGENTS.md" "$ROOT/.ai-rules/.version" "$TMP/nomake/.ai-rules/"
out="$(validate "$ROOT/blessed.yml" "$TMP/nomake")"
grep -q "no documented 'docs' target" <<<"$out" && ok "makefile-core-target-missing → $(grep "docs" <<<"$out" | head -n 1)" ||
  no "a missing core target was not caught: $out"

echo "── blessed catalog validator (optional, private) ──"
if [ -n "${BLESSED_CICD_DIR:-}" ]; then
  B="$TMP/blessed"
  mkdir -p "$B"
  g() { git -C "$BLESSED_CICD_DIR" show "origin/master:$1"; }
  g scripts/lib-catalog.jq >"$B/lib-catalog.jq"
  types="$(g catalog/repo-types.yml | yq -o=json '.repo_types | keys')"
  stages="$(g catalog/stages.yml | yq -o=json '.stages | keys')"
  caps="$(g catalog/capabilities.yml | yq -o=json '.capabilities | keys')"
  if yq -o=json '.' "$ROOT/blessed.yml" | jq -e -L "$B" --argjson types "$types" --argjson stages "$stages" --argjson caps "$caps" \
    'include "lib-catalog"; valid_manifest($types; $stages; $caps)' >/dev/null; then
    ok "blessed lib-catalog.jq valid_manifest ($(git -C "$BLESSED_CICD_DIR" rev-parse --short origin/master)): valid"
  else
    no "blessed lib-catalog.jq valid_manifest rejects blessed.yml"
  fi
else
  echo "  - not run: set BLESSED_CICD_DIR to a blessed-cicd checkout to also run blessed's private catalog validator"
fi

if [ "$fail" -ne 0 ]; then
  echo "blessed-manifest: FAILED"
  exit 1
fi
echo "blessed-manifest: OK"
