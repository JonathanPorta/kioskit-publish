# kioskit-publish

Public reusable GitHub Actions workflows that validate and publish a Kioskit
**state repository**, using kioskd's prebuilt, signed `kioskit-publish`
binary.

- `.github/workflows/kioskit-publish.yml` publishes every device bundle to
  the Kioskit Worker on push to `main`.
- `.github/workflows/kioskit-validate.yml` validates every device folder on
  pull requests.

Callers pass no secret and need no access to anything private. Each workflow
downloads one pinned publisher version from this repository's immutable
Releases and verifies it. Only then does it run the binary. See
[Trust model](#trust-model).

Tracking: JonathanPorta/kioskit#137 (this repository), #135 (PR validation).

## Callers

Pin both workflows to the same **full commit SHA** of this repository's `main`
(`<S>` below). The Worker allows uploads only from an allowlisted
`job_workflow_ref`. That ref is
`JonathanPorta/kioskit-publish/.github/workflows/kioskit-publish.yml@<S>`, so
`<S>` must be the exact SHA the Worker lists. Never use a branch or tag.

`.github/workflows/kioskit-publish.yml` in the state repository:

```yaml
name: Kioskit publish
on:
  push:
    branches: [main]
permissions: {}
jobs:
  publish:
    permissions:
      contents: read
      id-token: write
    uses: JonathanPorta/kioskit-publish/.github/workflows/kioskit-publish.yml@<S>
    # with:
    #   parallelism: 4   # 1-16, the only input
```

`.github/workflows/kioskit-validate.yml` in the state repository:

```yaml
name: Kioskit validate
on:
  pull_request:
permissions: {}
jobs:
  validate:
    permissions:
      contents: read
    uses: JonathanPorta/kioskit-publish/.github/workflows/kioskit-validate.yml@<S>
```

Neither caller has a `secrets:` block. The validate job has no `id-token`, so a
pull request (from a fork, too) can never mint a publish token. Use
`pull_request`, never `pull_request_target`. Make the `kioskit-validate`
check required on `main` if you want broken device folders blocked before
merge.

`validate` lists every problem it finds and names each file, for example:

```text
validation failed with 1 problem(s):
  src/devices/d8:3a:dd:76:4b:86/: apply.files[0].source traverses outside the bundle: "../../../../etc/passwd"
```

## Backfill (an existing state repository)

A repository that still calls `JonathanPorta/kioskd/.github/workflows/kioskit-publish.yml`:

1. Check that the Worker's `PUBLISH_ALLOWED_WORKFLOW_REFS` already holds
   `JonathanPorta/kioskit-publish/.github/workflows/kioskit-publish.yml@<S>`,
   next to the old kioskd ref (kioskit `variables.tf`, then apply and deploy).
2. In one PR, point the publish caller at `<S>`, delete its `secrets:` block,
   and add the validate caller above.
3. Merge it. The push publishes through the new ref. Every device should
   report `published` or `idempotent`, and never `integrity_conflict`.
4. Delete the repository's `KIOSKD_READ_TOKEN` secret.

## Upgrading the publisher

Each new publisher version is a new workflow SHA, and so a new Worker
identity. The steps:

1. kioskd cuts a release that includes `kioskit-publish_<v>_linux_amd64`.
2. **The owner** runs [`mirror.yml`](.github/workflows/mirror.yml) with
   `version: <v>` (Actions → "Mirror a kioskd publisher release" → Run
   workflow, on `main`), then approves the `mirror` Environment. The workflow:
   - refuses if tag `v<v>` or a release named `v<v>` already exists;
   - fetches kioskd's release with the read-only token;
   - verifies the signed manifest, the binary's digest and signature, and
     `SHA256SUMS` against [`release-trusted-keys.json`](release-trusted-keys.json);
   - creates the immutable release `v<v>`;
   - opens the promotion PR `promote/v<v>`.
3. **Review and merge the promotion PR.** It bumps `PUBLISHER_VERSION` and
   `PUBLISHER_SHA256` in both workflows and adds `provenance/v<v>.json`. The
   workflow token's PRs don't start CI, so close and reopen the PR (or run
   `make check` locally) before merging. The merge commit is the new `<S'>`.
   **If a run fails after creating the release** (for example the PR API
   errors), dispatch `mirror.yml` again with the same `version` and
   **`resume: true`**. A resume creates no tag or release. It requires the
   release to exist, checks that its five assets are exactly the files of the
   signed kioskd candidate (verified against the trust store), re-renders the
   provenance, and then finds or opens the single promotion PR. It reuses
   `promote/v<v>` if that branch was already pushed with the same content, and
   refuses a branch with different content. Without `resume`, a run for an
   existing version is still refused.
4. **The two-step allowlist** in kioskit: add `<S'>` to
   `publish_allowed_workflow_refs` and deploy. Then move every caller to
   `<S'>`. Then remove `<S>` and deploy again. A caller still on a removed
   ref fails loudly as `workflow_not_allowed`, and the Worker audits it.

A version must never change bytes. Bump the version whenever the publisher's
archive output changes, or a re-publish of old commits reports
`integrity_conflict`.

## Trust model

What a caller's job runs is fixed by the commit `<S>` it pins:

- **Pins.** `PUBLISHER_VERSION`, `PUBLISHER_SHA256`, `PUBLISHER_KEY_ID` and
  `PUBLISHER_PUBKEY_B64` are written into both workflow files at `<S>`.
  `make check` fails if they differ between the two files, if a value is
  malformed, or if the key is not the active key of that id in
  `release-trusted-keys.json`.
- **Verify before run** (`scripts/verify-publisher.sh`). The binary, its
  `.sig` and kioskd's signed `release-candidate.json` (+ `.sig`) are
  downloaded anonymously over https. Then:
  1. the pinned key must equal the committed trust store's key;
  2. the binary's SHA-256 must equal `PUBLISHER_SHA256`;
  3. the binary's ed25519 signature must verify;
  4. the manifest's signature must verify;
  5. the manifest must list exactly this binary (artifact
     `linux-amd64-kioskit-publish`) with this digest, version and key.

  Any failure stops the job, names the check, and the binary never runs. Only
  the copy that passed is installed and executed. Signatures are checked by
  blessed's `ed25519-detached-v1` verifier (`scripts/signing/`, installed
  from blessed-cicd's signed public script export).
- **The digest pin is the integrity check; the signature is the origin
  check.** A wrong digest in a promotion PR still fails the signature check
  unless kioskd's key signed that binary. Release assets are immutable, and
  anything that changed would fail both checks anyway.
- **The key.** `kioskitd-2026-01` is kioskd's release key, which is also the
  fleet's self-update anchor. `release-trusted-keys.json` is a byte-for-byte
  copy of kioskd's. kioskd's self-updater refuses any artifact that isn't
  `kioskitd_*`, so a signed publisher can't be passed off as a daemon update.
- **The mirror's credential.** `KIOSKD_RELEASE_READ_TOKEN` (Contents: read on
  kioskd only) lives in the `mirror` Environment. That Environment needs a
  reviewer and allows protected branches only. Only the fetch step of
  `mirror.yml` sees the token. The job that writes the release and the PR has
  no secret. kioskd holds no credential for this repository, so `mirror.yml`
  runs only on `workflow_dispatch`. A leaked token would expose kioskd's
  source, not publish rights.
- **Tags.** An exact tag `vX.Y.Z` is created once with its release and never
  moved, and `mirror.yml` refuses a version that already exists. There is no
  major alias such as `v1`: callers pin commit SHAs.
- **Provenance.** `provenance/v<v>.json`
  (`blessed/public-github-mirror-provenance/v1`) records the kioskd tag and
  commit, the mirror tag, and the public files. The signed manifest it was
  read from is committed beside it. `make check` re-verifies that signature
  and checks that `source_sha` and the pinned digest match.

This is blessed's `public-github-mirror` surface with the `surface-pull`
model ([`release-surfaces.yaml`](release-surfaces.yaml)).

## Current pins

The pins in this repository start at kioskd **v0.5.1**, the first
byte-reproducible publisher. `provenance/v0.5.1.json` is what `mirror.yml`
renders for that candidate, and it's byte-identical to what a real run
produces. Until the owner runs `mirror.yml` for 0.5.1, release `v0.5.1` does
not exist here, so callers have no `<S>` yet. Mirroring 0.5.1 renders no
change, so that run opens no promotion PR, and `main`'s head at that point is
`<S>`.

## Blessed adoption

[`blessed.yml`](blessed.yml) declares this repository to blessed-cicd: repo
type `library` (callers consume the workflows by direct reference), the
adopted standards (`makefile.core@1`, `releases.surfaces@1`,
`signing.ed25519-detached@1`), its capabilities, and owned, expiring waivers
for the defaults it does not meet yet (`makefile.profiles@1`, the spec pack,
and `repo-protection`, whose baseline needs owner settings changes).

The blessed files vendored here come only from blessed-cicd's signed **public**
script export: `scripts/signing/` and `scripts/release/lib/lib-json-schema.sh`.
A public repository may not republish blessed's private categories.
`make verify-scripts` (the first step of `make check`) checks the export's
signed `MANIFEST.sha256` against the pinned key, and checks every vendored file
against its signed entry, offline.

`release-surfaces.yaml` and `blessed.yml` are validated against
repository-authored schemas in [`schema/`](schema/), using the signed public
JSON-Schema validator. blessed's own validators are private. Set
`BLESSED_CICD_DIR=<blessed-cicd checkout>` to run them too (for
`validate-surfaces.sh`, also point `YQ_BIN` at the yq version it pins).

## Development

```text
make help      list targets
make check     static: signed blessed files, lint, workflow contract, surface, blessed.yml
make test      verify-before-run, contract and export mutations, mirror and resume
```

CI runs `make check` and `make test`. Both are offline, and both need bash,
git, jq, mikefarah yq v4, OpenSSL 3 or newer (on macOS, set `OPENSSL_BIN` to
Homebrew's), shellcheck and actionlint (`make deps` checks).

## License

[Apache-2.0](LICENSE), Copyright 2026 Jonathan Porta. The files in
`scripts/signing/` and `scripts/release/lib/` come from blessed-cicd's public
script export and are Apache-2.0 under their own terms, recorded in
`.blessed/export/`.
