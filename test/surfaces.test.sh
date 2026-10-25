#!/usr/bin/env bash
# surfaces.test.sh — release-surfaces.yaml is a valid surface declaration and
# declares exactly the AC-14 surface (kioskit#137; review F3). Offline; no
# private checkout.
#
#   1. YAML preflight: one document, no anchors/aliases/explicit tags, no
#      duplicate keys (all erased by conversion, so checked before it).
#   2. Structure: schema/release-surfaces.schema.json, validated by blessed's
#      signed public JSON-Schema validator (scripts/release/lib/lib-json-schema.sh,
#      bound to the signed export by make verify-scripts).
#   3. Semantics a schema cannot express (releases.surfaces@1 "Authority
#      compatibility"): a cross-repo surface declares both publisher_model and
#      promotion_transport, only legal pairs for its kind; no case-variant
#      duplicate producer.
#   4. The exact AC-14 values.
# Then the same gate is run against mutated copies, each of which must fail.
#
# blessed's own validate-surfaces.sh and schema are in a private category that a
# public repository may not republish (blessed-cicd scripts/INSTALL.md and the
# export licence, which covers only the export's listed files). With
# BLESSED_CICD_DIR=<a blessed-cicd checkout> this test ALSO runs that validator.
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
F="$ROOT/release-surfaces.yaml"
SCHEMA="$ROOT/schema/release-surfaces.schema.json"
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

# validate FILE -> prints findings (one per line); empty means valid.
validate() {
  local f="$1" json
  yq 'true' "$f" >/dev/null 2>&1 || {
    echo "not parseable as YAML"
    return
  }
  [ "$(yq 'documentIndex' "$f" | awk 'END{print NR+0}')" = 1 ] || echo "exactly one YAML document is allowed"
  [ "$(yq '[... | select(anchor != "" or kind == "alias")] | length' "$f")" = 0 ] || echo "YAML anchors and aliases are not allowed"
  [ "$(yq -o=json '[... | select(style == "tagged")] | length' "$f")" = 0 ] || echo "explicit YAML tags are not allowed"
  json="$(yq -o=json '.' "$f")"
  [ "$(yq -o=json '[... | select(kind == "map") | keys | length]' "$f" | jq 'add // 0')" = "$(jq '[.. | objects | keys | length] | add // 0' <<<"$json")" ] ||
    echo "duplicate mapping keys"
  printf '%s' "$json" >"$TMP/doc.json"
  json_schema_validate_file "$TMP/doc.json" "$SCHEMA" | sed 's/^/schema: /'
  # shellcheck disable=SC2016 # jq program
  jq -r '
    (.surfaces // [])[] | . as $s
    | ([$s.producer_repos[]? | ascii_downcase]) as $p
    | (if ($p | length) != ($p | unique | length) then "surface \($s.id): case-variant duplicate producer_repos entry" else empty end),
      ( ([$p[] | select(. != ($s.owner_repo | ascii_downcase))] | length > 0) as $cross
        | ($s | has("publisher_model")) as $hp | ($s | has("promotion_transport")) as $ht
        | if $cross then
            (if ($hp and $ht) then empty else "surface \($s.id): a cross-repo surface must declare publisher_model and promotion_transport" end),
            (if ($s.kind | IN("public-download-surface", "public-github-mirror", "package-repository-surface")) then empty
             else "surface \($s.id): cross-repo \($s.kind) has no supported publisher/transport model in v1" end)
          else
            (if $hp or $ht then "surface \($s.id): a same-repo surface declares no publisher_model/promotion_transport in v1" else empty end)
          end )' "$TMP/doc.json" 2>&1
}

echo "── release-surfaces.yaml is a valid declaration ──"
out="$(validate "$F")"
[ -z "$out" ] && ok "preflight, schema (signed public validator) and authority-compatibility checks pass" || no "invalid: $(echo "$out" | tr '\n' ' ')"

echo "── it declares exactly the AC-14 surface ──"
q() { yq -r "$1" "$F"; }
[ "$(q '.surfaces | length')" = "1" ] && ok "exactly one surface" || no "want exactly one surface"
check() {
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

echo "── the gate rejects invalid declarations ──"
# name | expected finding (grep -F) | yq expression applied to a copy
CASES=(
  "no-consumer-contract|consumer_contract|del(.surfaces[0].consumer_contract)"
  "no-access-model|access_model|del(.surfaces[0].access_model)"
  "bad-transport|promotion_transport|.surfaces[0].promotion_transport = \"push\""
  "bad-publisher-model|publisher_model|.surfaces[0].publisher_model = \"producer-push-pr\""
  "unknown-field|source_repo|.surfaces[0].source_repo = \"JonathanPorta/kioskd\""
  "mirror-with-base-url|not|.surfaces[0].public_base_url = \"https://example.com/\""
  "bad-repo|owner_repo|.surfaces[0].owner_repo = \"not a repo\""
  "cross-repo-missing-transport|must declare publisher_model and promotion_transport|del(.surfaces[0].promotion_transport)"
  "illegal-kind-pair|no supported publisher/transport model|.surfaces[0].kind = \"runtime-deploy\""
  "case-duplicate-producer|case-variant duplicate|.surfaces[0].producer_repos += [\"jonathanporta/KIOSKD\"]"
  "wrong-schema|schema|.schema = \"blessed/release-surfaces/v2\""
)
for c in "${CASES[@]}"; do
  name="${c%%|*}"
  rest="${c#*|}"
  want="${rest%%|*}"
  expr="${rest#*|}"
  yq "$expr" "$F" >"$TMP/$name.yaml"
  out="$(validate "$TMP/$name.yaml")"
  if [ -n "$out" ] && grep -Fq -- "$want" <<<"$out"; then
    ok "$name → $(grep -F -- "$want" <<<"$out" | head -n 1)"
  else
    no "$name: want a finding mentioning [$want], got [$(echo "$out" | tr '\n' ' ')]"
  fi
done
printf 'schema: blessed/release-surfaces/v1\nproduct: kioskit\nproduct: other\nsurfaces: []\n' >"$TMP/dup.yaml"
out="$(validate "$TMP/dup.yaml")"
grep -q "duplicate mapping keys" <<<"$out" && ok "duplicate-key → duplicate mapping keys" || no "duplicate keys not caught: $out"

echo "── blessed validate-surfaces.sh (optional, private) ──"
if [ -n "${BLESSED_CICD_DIR:-}" ]; then
  B="$TMP/blessed"
  mkdir -p "$B/lib" "$B/references"
  for p in validate-surfaces.sh lib/lib-json-schema.sh references/release-surfaces.schema.json; do
    git -C "$BLESSED_CICD_DIR" show "origin/master:scripts/release/$p" >"$B/$p" || no "cannot read scripts/release/$p from $BLESSED_CICD_DIR"
  done
  out="$(bash "$B/validate-surfaces.sh" --file "$F" 2>&1)"
  rc=$?
  [ "$rc" = 0 ] && ok "blessed validate-surfaces.sh ($(git -C "$BLESSED_CICD_DIR" rev-parse --short origin/master)): $out" ||
    no "blessed validate-surfaces.sh exit $rc: $out"
  yq 'del(.surfaces[0].consumer_contract)' "$F" >"$TMP/b-no-cc.yaml"
  bash "$B/validate-surfaces.sh" --file "$TMP/b-no-cc.yaml" >/dev/null 2>&1 && no "blessed accepted a declaration without consumer_contract" ||
    ok "blessed rejects the missing-consumer_contract control too"
else
  echo "  - not run: set BLESSED_CICD_DIR to a blessed-cicd checkout to also run blessed's private validator"
fi

if [ "$fail" -ne 0 ]; then
  echo "surfaces: FAILED"
  exit 1
fi
echo "surfaces: OK"
