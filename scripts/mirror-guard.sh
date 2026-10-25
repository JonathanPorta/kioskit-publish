#!/usr/bin/env bash
# mirror-guard.sh — refuse to mirror a version whose tag or release already
# exists in this repository (kioskit#137 AC-17). An exact version tag is created
# once and never moved, so a second run for the same version must stop here.
#
# FAIL CLOSED: only GitHub's explicit HTTP 404 counts as "absent". Any other
# error (auth, rate limit, network) refuses, because it proves nothing.
# Needs gh with GH_TOKEN able to read this repository.
set -euo pipefail

repo="" version=""
while [ $# -gt 0 ]; do
  case "$1" in
    --repo) repo="${2:-}" && shift 2 ;;
    --version) version="${2:-}" && shift 2 ;;
    *)
      echo "mirror-guard: usage: mirror-guard.sh --repo OWNER/NAME --version X.Y.Z" >&2
      exit 2
      ;;
  esac
done
printf '%s' "$repo" | grep -Eqx '[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+' || {
  echo "mirror-guard: --repo is not owner/name: $repo" >&2
  exit 2
}
printf '%s' "$version" | grep -Eqx '[0-9]+\.[0-9]+\.[0-9]+' || {
  echo "mirror-guard: version is not X.Y.Z: $version" >&2
  exit 2
}
tag="v$version"
err="$(mktemp)"
trap 'rm -f "$err"' EXIT

# absent PATH -> 0 if GitHub answers 404, 1 if the object exists; exits 1 on any other error.
absent() {
  if gh api "$1" >/dev/null 2>"$err"; then return 1; fi
  if grep -q 'HTTP 404' "$err"; then return 0; fi
  echo "mirror-guard: refused: cannot tell whether $1 exists: $(tr '\n' ' ' <"$err")" >&2
  exit 1
}

# git/ref (singular) matches exactly; git/refs would prefix-match v1.2 to v1.2.3.
if ! absent "repos/$repo/git/ref/tags/$tag"; then
  echo "mirror-guard: refused: tag $tag already exists in $repo; exact version tags are never moved or re-created" >&2
  exit 1
fi
if ! absent "repos/$repo/releases/tags/$tag"; then
  echo "mirror-guard: refused: release $tag already exists in $repo" >&2
  exit 1
fi
# Drafts have no tag yet and are invisible to releases/tags; list them.
if ! drafts="$(gh api --paginate "repos/$repo/releases?per_page=100" --jq '.[].tag_name' 2>"$err")"; then
  echo "mirror-guard: refused: cannot list releases of $repo: $(tr '\n' ' ' <"$err")" >&2
  exit 1
fi
if printf '%s\n' "$drafts" | grep -Fqx "$tag"; then
  echo "mirror-guard: refused: a (draft) release named $tag already exists in $repo" >&2
  exit 1
fi
echo "mirror-guard: ok — no tag or release $tag in $repo"
