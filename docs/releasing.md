# Releasing

Releases are cut by [release-please](https://github.com/googleapis/release-please)
from Conventional Commits on `main`. There is nothing to run by hand.

## The normal path

1. Land commits on `main`. `feat:` bumps the minor, `fix:` the patch,
   a `!` or `BREAKING CHANGE:` the major.
2. release-please keeps a `chore(main): release X.Y.Z` pull request
   open, with the version bump and the changelog.
3. Merging that pull request is the release. The `main` workflow then:
   - creates the tag and a **draft** release;
   - builds the payload with `ci/build_release_payload.sh`;
   - attaches it with `ci/publish_release_assets.sh`;
   - signs it with packslip, in a job that cannot write to the release;
   - attaches the signed bundle and **publishes** the release;
   - verifies the published release as a stranger would;
   - opens a pull request against `rubyists/homebrew-tap`.

The release stays a draft until everything is attached, on purpose.
GitHub's Immutable Releases locks a release's assets the moment it is
published, so a release that is published first and filled afterwards can
end up locked half empty, permanently.

## What a release contains

| Asset | What it is |
| --- | --- |
| `sv-helper-linux.tar.gz` | the whole suite, for Linux |
| `sv-helper-darwin.tar.gz` | the same contents, for macOS |
| `rsvlog` | just the log `run` script |
| `sv-helper.sh` | just the helper |
| `runsvdir.sh` | just the supervisor starter |
| `SHA256SUMS` | every asset above |
| `packslip.sigstore.json` | the signed release statement |

The archives carry no version in their names. packslip needs an exact
path rather than a glob, and that is what lets `release.toml` be a static
checked-in file instead of something generated per release. The version
is still in the tag, the download URL, the directory inside the archive,
and the signed statement.

Both archives have identical contents. They exist separately so each one
records the platform it is supported on, rather than one artifact
claiming to run anywhere unchecked.

Archives are built reproducibly — sorted entries, fixed timestamps, no
owner names, gzip without its own timestamp — so rebuilding the same
commit produces the same bytes. The recovery path below depends on that.

Everything comes from the explicit list at the top of
`ci/build_release_payload.sh`, never from "whatever is in the working
tree", so an untracked checkout sitting in the repository can never be
shipped by accident. **Add new files to that list when they become part
of what we ship.**

## Verifying a release

What CI does, and what anyone else can do:

    ci/verify_release.sh v3.6.0

That downloads every asset, checks them against the release's own
`SHA256SUMS`, confirms nothing expected is missing, unpacks the archive
and checks the commands and their permissions survived, and — if
packslip is installed — verifies the bundle against this repository's
signing identity.

By hand, against the signature alone:

    packslip verify packslip.sigstore.json \
      --identity-prefix 'https://github.com/rubyists/sv-helper/.github/workflows/main.yaml@' \
      --issuer https://token.actions.githubusercontent.com \
      --artifact sv-helper-linux.tar.gz

Every release is signed from that one workflow file. A consumer treats a
release signed from a different one as a new signer and refuses it until
a person approves, so any backfill has to run from `main.yaml` too.

## When a release run fails partway

An interrupted run leaves a **draft** release with some assets attached.
Re-run the `main` workflow by hand:

> Actions → main → Run workflow → tag: `v3.6.0`

It rebuilds the payload from that release's commit and uploads only what
is missing. An asset already present with identical bytes is skipped; one
whose bytes differ stops the run rather than being replaced, because that
means the release and the rebuild disagree about what this version is.
Delete that asset deliberately if you really do mean to change it.

GitHub on its own only tags a draft release when it is published, so
release-please is configured with `force-tag-creation` to tag the draft as
it creates it. Without that, release-please cannot find the release it
just made, and its next release pull request re-lists the entire history
as unreleased. If the tag still cannot be resolved, pass the commit in
the `commit` input.

Once a release is **published** it is immutable and nothing can be added
to it. That is the reason for the draft-first ordering, and it is why the
recovery path is useful only before publication.

## Credentials

| Secret | Why |
| --- | --- |
| `RELEASE_PLEASE_TOKEN` | An org secret. The built-in `GITHUB_TOKEN` is scoped to this repository, so it cannot open a pull request against `rubyists/homebrew-tap`; and a release created with it starts no further workflows. |
| `GITHUB_TOKEN` | Everything else, with permissions granted per job. |

Job permissions are deliberately uneven. The signing job has
`id-token: write` and `attestations: write` but only `contents: read`: it
signs whatever bytes it is handed and must not be able to change the
release it is describing.

## Versions in the source

Each script reports its version with `--version` from its own
`sv_version` line, because an installed script has no `version.txt`
beside it. release-please rewrites every line marked
`x-release-please-version` in the files listed under `extra-files` in
`.release-please-config.json`. That covers the three scripts, `PKGBUILD`,
and the example in the README, which is marked as a block.
`test/version.bats` fails if a marked file is missing from that list or
holds a version other than `version.txt`'s, so a new file with a version
in it cannot be forgotten.

## Other packaging

`PKGBUILD`'s `pkgver` is bumped by release-please along with everything
else. Its `sha256sums` is not — refresh it with `updpkgsums`, or from the
release's own `SHA256SUMS`, when publishing to the AUR.

The Homebrew formula is updated automatically; see
`ci/bump_homebrew_formula.sh`, which can be run locally against a
release's `SHA256SUMS` to see exactly what the workflow would write.
