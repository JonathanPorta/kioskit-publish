#!/usr/bin/env bash
# export-verify.test.sh — kioskit#137 review F2: `make verify-scripts`
# (scripts/verify-export.sh) binds the vendored blessed files to the SIGNED
# export. The real tree passes; each tampering below, alone, must fail.
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
fail=0
ok() { echo "  ✓ $1"; }
no() {
  echo "  ✗ $1"
  fail=1
}
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
copy() {
  local d="$TMP/$1"
  mkdir -p "$d"
  cp -R "$ROOT/scripts" "$ROOT/.blessed" "$d/"
  echo "$d"
}
sha() { if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | cut -d' ' -f1; else shasum -a 256 "$1" | cut -d' ' -f1; fi; }

d="$(copy control)"
bash "$d/scripts/verify-export.sh" >"$TMP/c.out" 2>&1 && ok "the real tree verifies: $(tail -n 2 "$TMP/c.out" | head -n 1 | sed 's/^verify-export: //')" ||
  no "the real tree fails: $(tail -n 1 "$TMP/c.out")"

# name | expected (grep -F) | mutation run inside the copy
CASES=(
  "verify-sh-plus-local-manifest|scripts/signing/verify.sh differs from its signed entry|printf '\n# patched\n' >>scripts/signing/verify.sh && (cd scripts/signing && { command -v sha256sum >/dev/null && sha256sum \$(cut -c67- MANIFEST.sha256) || shasum -a 256 \$(cut -c67- MANIFEST.sha256); } >M && mv M MANIFEST.sha256 && shasum -a 256 -c MANIFEST.sha256 >/dev/null)"
  "outer-manifest-rewritten|MANIFEST.sha256.sig does not verify|printf '\n# patched\n' >>scripts/signing/verify.sh && awk -v n=\"\$(shasum -a 256 scripts/signing/verify.sh | cut -c1-64)\" '\$2==\"signing/verify.sh\"{\$0=n\"  signing/verify.sh\"}1' .blessed/export/MANIFEST.sha256 >M && mv M .blessed/export/MANIFEST.sha256"
  "schema-validator-changed|scripts/release/lib/lib-json-schema.sh differs|printf '\n# patched\n' >>scripts/release/lib/lib-json-schema.sh"
  "surface-validator-changed|scripts/release/validate-surfaces.sh differs from its signed entry|printf '\n# patched\n' >>scripts/release/validate-surfaces.sh"
  "surface-schema-changed|release-surfaces.schema.json differs from its signed entry|jq '.title = \"x\"' scripts/release/references/release-surfaces.schema.json >x && mv x scripts/release/references/release-surfaces.schema.json"
  "extra-file|is not a file of the signed export|echo x >scripts/signing/extra.sh"
  "trust-store-key-swapped|does not hold the pinned|jq '.keys[].public_key_base64 = \"PTd5F+ilIM5ZBp9mDjQ83num4nDnhDwv9G6Vf7kzA/Q=\"' .blessed/export-trust-store.json >S && mv S .blessed/export-trust-store.json"
  "source-identity|differs from the pins|sed -i.bak 's/EXPORT_TAG=.*/EXPORT_TAG=public-consumer-core-v9.9.9/' scripts/.blessed-export-version"
)
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
  if bash "$d/scripts/verify-export.sh" >"$TMP/$name.out" 2>&1; then
    no "$name: verify-export PASSED on a tampered tree"
  elif grep -Fq -- "$want" "$TMP/$name.out"; then
    ok "$name → $(grep -F -- "$want" "$TMP/$name.out" | head -n 1 | sed 's/^verify-export: //')"
  else
    no "$name: failed, but not with [$want]: $(tail -n 1 "$TMP/$name.out")"
  fi
done

if [ "$fail" -ne 0 ]; then
  echo "export-verify: FAILED"
  exit 1
fi
echo "export-verify: OK"
