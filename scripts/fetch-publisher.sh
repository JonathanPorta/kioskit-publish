#!/usr/bin/env bash
# fetch-publisher.sh — download one pinned kioskit-publish release from THIS
# repository's public GitHub Releases, anonymously (no token, kioskit#137 AC-4).
#
# Downloads only; never verifies and never executes. The caller runs
# scripts/verify-publisher.sh next, and only its --install output is ever run.
# Files are written with the default (non-executable) mode.
set -euo pipefail
BASE_URL="https://github.com/JonathanPorta/kioskit-publish/releases/download"

version="" out=""
while [ $# -gt 0 ]; do
  case "$1" in
    --version) version="${2:-}" && shift 2 ;;
    --out) out="${2:-}" && shift 2 ;;
    *)
      echo "fetch-publisher: usage: fetch-publisher.sh --version X.Y.Z --out DIR" >&2
      exit 2
      ;;
  esac
done
printf '%s' "$version" | grep -Eqx '[0-9]+\.[0-9]+\.[0-9]+' || {
  echo "fetch-publisher: version is not X.Y.Z: $version" >&2
  exit 2
}
[ -n "$out" ] || {
  echo "fetch-publisher: --out is required" >&2
  exit 2
}
mkdir -p "$out"
bin="kioskit-publish_${version}_linux_amd64"
for f in "$bin" "$bin.sig" release-candidate.json release-candidate.json.sig; do
  # https only, including every redirect hop; bounded size; retried.
  curl --fail --silent --show-error --location --proto '=https' --proto-redir '=https' --tlsv1.2 \
    --retry 3 --retry-delay 2 --max-filesize 104857600 \
    --output "$out/$f" "$BASE_URL/v$version/$f"
  echo "fetch-publisher: downloaded $f ($(wc -c <"$out/$f" | tr -d ' ') bytes)"
done
