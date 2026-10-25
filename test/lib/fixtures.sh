#!/usr/bin/env bash
# fixtures.sh — build a throwaway, correctly signed kioskd-shaped release for the
# offline tests. SOURCED. Nothing here is committed: every run makes a fresh
# ed25519 key, so no private key ever lives in the repository.
#
# The fixture "publisher" is a shell script that records each execution in
# $PUBLISHER_RAN_MARKER. A test that finds the marker knows the binary ran.

FIXTURE_VERSION="${FIXTURE_VERSION:-9.8.7}"
FIXTURE_KEY_ID="fixture-2026-01"
FIXTURE_SOURCE_SHA="0123456789abcdef0123456789abcdef01234567"

fx_sha256() {
  if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | cut -d' ' -f1; else shasum -a 256 "$1" | cut -d' ' -f1; fi
}
fx_size() { wc -c <"$1" | tr -d ' '; }

# fx_keygen DIR NAME -> DIR/NAME.pem, DIR/NAME.pub (raw base64, no newline)
fx_keygen() {
  bash "$FX_ROOT/scripts/signing/keygen.sh" --out-private "$1/$2.pem" --out-public-base64 "$1/$2.pub" --key-id "$2" >/dev/null 2>&1 ||
    {
      echo "fixtures: keygen failed (need OpenSSL 3; set OPENSSL_BIN)" >&2
      return 1
    }
}

# fx_sign KEY.pem FILE -> FILE.sig
fx_sign() {
  bash "$FX_ROOT/scripts/signing/sign.sh" --profile ed25519-detached-v1 --input "$2" --private-key-file "$1" --output "$2.sig" --force >/dev/null 2>&1
}

# fx_trust_store PUB_B64 OUT
fx_trust_store() {
  jq -n --arg k "$FIXTURE_KEY_ID" --arg p "$1" \
    '{schema: "blessed/signing-trust-store/v1", keys: {($k): {profile: "ed25519-detached-v1", public_key_base64: $p, status: "active"}}}' >"$2"
}

# fx_write_binary FILE [VARIANT]
fx_write_binary() {
  # shellcheck disable=SC2016 # the fixture script expands $* when IT runs
  printf '#!/usr/bin/env bash\n# fixture kioskit-publish %s\necho "ran: $*" >>"${PUBLISHER_RAN_MARKER:?}"\n' "${2:-genuine}" >"$1"
}

# fx_manifest DIR VERSION BIN_SHA BIN_SIZE -> DIR/release-candidate.json (unsigned)
fx_manifest() {
  local dir="$1" v="$2" sha="$3" size="$4" bin="kioskit-publish_${2}_linux_amd64" sums_sha sums_size
  sums_sha="$(fx_sha256 "$dir/SHA256SUMS")"
  sums_size="$(fx_size "$dir/SHA256SUMS")"
  jq -n --arg v "$v" --arg bin "$bin" --arg sha "$sha" --argjson size "$size" \
    --arg sums_sha "$sums_sha" --argjson sums_size "$sums_size" --arg k "$FIXTURE_KEY_ID" --arg src "$FIXTURE_SOURCE_SHA" '{
      schema: "blessed/release-candidate/v1",
      project: "kioskit",
      component: "kioskitd",
      producer_repo: "JonathanPorta/kioskd",
      version: $v,
      tag: ("v" + $v),
      source_sha: $src,
      build_sha: $src,
      created_at: "2026-10-25T15:30:01Z",
      signing: {artifacts: "required", key_id: $k, manifest_signature: "release-candidate.json.sig", profile: "ed25519-detached-v1"},
      artifacts: [
        {filename: ("kioskitd_" + $v + "_linux_amd64"), id: "linux-amd64-binary", install_kind: "binary", platform: "linux/amd64",
         sha256: "f4d3a025b78563e0f8635f1a589de12bb8529519b56d253360e1cf0b8506c80e", signature: ("kioskitd_" + $v + "_linux_amd64.sig"), size: 1},
        {filename: $bin, id: "linux-amd64-kioskit-publish", install_kind: "other", platform: "linux/amd64",
         sha256: $sha, signature: ($bin + ".sig"), size: $size}
      ],
      files: [
        {name: "SHA256SUMS", role: "checksums", sha256: $sums_sha, size: $sums_size},
        {name: $bin, role: "artifact", sha256: $sha, size: $size}
      ]
    }' >"$dir/release-candidate.json"
}

# fx_release DIR KEY.pem [VERSION] — a complete, valid signed fixture release:
#   kioskit-publish_<v>_linux_amd64(.sig), SHA256SUMS, release-candidate.json(.sig)
fx_release() {
  local dir="$1" key="$2" v="${3:-$FIXTURE_VERSION}" bin sha size
  bin="kioskit-publish_${v}_linux_amd64"
  mkdir -p "$dir"
  fx_write_binary "$dir/$bin"
  fx_sign "$key" "$dir/$bin"
  sha="$(fx_sha256 "$dir/$bin")"
  size="$(fx_size "$dir/$bin")"
  printf '%s  %s\n%s  %s\n' "$sha" "$bin" "$(fx_sha256 "$dir/$bin.sig")" "$bin.sig" >"$dir/SHA256SUMS"
  fx_manifest "$dir" "$v" "$sha" "$size"
  fx_sign "$key" "$dir/release-candidate.json"
}
