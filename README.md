# OpenTofu with baked-in providers

A container image with [OpenTofu](https://opentofu.org) and the providers it needs already inside.
`tofu init` downloads **nothing** - no provider package, no registry lookup.

## Why

By default, `tofu init` downloads every provider as a zip archive from a registry, on every run, in
every pipeline. Some environments do not allow that: no outbound access to public registries, or a
policy that forbids fetching executable archives at run time.

This image moves the download to build time, where the packages are checked against pinned
checksums and the registry's signature, tested, and scanned for vulnerabilities. At run time,
OpenTofu installs providers only from a directory inside the image.

It currently serves one purpose: managing [OpenBao](https://openbao.org) with OpenTofu. OpenBao
speaks the Vault API, so the provider for it is `hashicorp/vault`.

## What's inside

The release notes of each image are authoritative for that image; this table shows the current state.

| Component | Version | Source |
|-----------|---------|--------|
| OpenTofu | 1.13.1 | `ghcr.io/opentofu/opentofu:1.13.1-minimal` (official image) |
| Provider `hashicorp/vault` | 5.12.0 | `registry.opentofu.org` - used for OpenBao |
| Base | Alpine 3.24.2 | with `bash`, `git` and `openssh-client`, like the official image |

## Usage

Image: `ghcr.io/<owner>/<repository>/opentofu:<version>`, or `:1` for the current major version.

### In a pipeline

The entrypoint is `tofu`, as in the official image. A job that runs a script in the image has to
reset it - for example in GitLab CI:

```yaml
tofu:plan:
  image:
    name: ghcr.io/<owner>/<repository>/opentofu:1
    entrypoint: [""]
  script:
  - tofu init -input=false
  - tofu plan -input=false
```

As a GitHub Actions job container (`container:`) nothing is needed; the entrypoint is replaced there anyway.

### docker run

```shell
docker run --rm -v "$PWD:/workspace" ghcr.io/<owner>/<repository>/opentofu:1 init
```

### Your configuration

The usual provider declaration is all it takes; the version constraint has to match the baked-in one:

```hcl
terraform {
  required_providers {
    vault = {
      source  = "hashicorp/vault"
      version = "~> 5.12"
    }
  }
}
```

An existing `.terraform.lock.hcl` keeps working, even one written on another platform (e.g. macOS):
the image ships the original zip from the registry, which matches the `zh:` hashes every lock file
contains.

## Behaviour and limits

- **Baked-in providers only.** The image's CLI configuration (`TF_CLI_CONFIG_FILE=/etc/opentofu/tofurc`)
  allows the mirror at `/usr/share/opentofu/providers` as the only installation source. Any other
  provider makes `tofu init` fail - it is never downloaded.
- **Your own CLI configuration.** Setting `TF_CLI_CONFIG_FILE` replaces the image's file; carry over
  the `provider_installation` block from [images/opentofu/tofurc](images/opentofu/tofurc), or
  `tofu init` falls back to downloading.
- **Modules** from registries or git repositories are not affected; the image only controls how
  providers are installed.
- **Architecture:** built for `linux/amd64`. The lock file already carries the `linux/arm64` hashes;
  an arm64 build only needs an additional build step.

## Layout

```
.github/
├── dependabot.yml                # update PRs: OpenTofu, Alpine, providers, actions
└── workflows/
    ├── image.yml                 # lint, build, test, scan, release
    └── scan.yml                  # weekly scan of the latest release
images/opentofu/
├── Dockerfile                    # mirror providers, copy OpenTofu, offline smoke test
├── tofurc                        # CLI configuration: the image's mirror only
├── providers/
│   ├── versions.tf               # which providers are baked in, at which version
│   └── .terraform.lock.hcl       # their checksums (amd64 + arm64)
└── test/
    ├── smoke.sh                  # smoke test, in the build and against the pushed image
    ├── baked/main.tf             # must work offline
    └── not-baked/main.tf         # must be refused
scripts/
├── next-version.sh               # next image version, derived from what changed
├── scan.sh                       # Trivy: image and providers
└── license-check.sh              # licenses of everything the image redistributes
Taskfile.yaml                     # the same steps locally
.trivyignore.yaml                 # accepted vulnerabilities, with reason and expiry date
.licenses-allowed.txt             # licenses the image may redistribute
```

The image build:

1. `tofu providers mirror` fetches the providers from `providers/versions.tf` at the versions and
   checksums in the lock file, and verifies the registry's signature. Any mismatch fails the build.
2. The `tofu` binary is copied out of the official `-minimal` image. The full official image cannot
   be used as a base since OpenTofu 1.10 (`ONBUILD RUN exit 1`); copying from `-minimal` is the
   [recommended way](https://opentofu.org/docs/intro/install/docker/).
3. The smoke test runs **without network** (`RUN --network=none`). If it fails, there is no image.

## Pipeline (GitHub Actions)

| Job | Pull request | `main` |
|-----|:---:|:---:|
| **lint** - hadolint (Dockerfile), shellcheck (scripts) | ✓ | ✓ |
| **version** - compute the next version, show it in the job summary | ✓ | ✓ |
| **build** - build including the offline smoke test | ✓ (local) | ✓ (pushed as `sha-<commit>`, with SBOM + provenance) |
| **build** - smoke test in the image (on `main`: freshly pulled from the registry) | ✓ | ✓ |
| **build** - Trivy scan of the image **and** the providers | ✓ | ✓ (+ SARIF to the Security tab) |
| **build** - license check of everything the image redistributes | ✓ | ✓ |
| **release** - tag the image with its version, create git tag + GitHub release | - | ✓ if `images/` changed |

A release promotes the tested and scanned image **by digest** - nothing is rebuilt.

The smoke test checks that:

- `tofu init` and `tofu validate` with the Vault provider work without any download (`validate`
  actually starts the provider);
- `tofu init` with a provider that is not baked in (`hashicorp/null`) **fails** - the image never
  quietly downloads after all.

### Trivy

[scripts/scan.sh](scripts/scan.sh) scans the image and, separately, the **unpacked providers**. The
providers sit in the image as zips, and Trivy does not look inside zips - a scan of the image alone
never sees a vulnerability in a provider.

- **Blocking:** every fixable vulnerability of severity `HIGH` or `CRITICAL`.
- **Exceptions** live in [.trivyignore.yaml](.trivyignore.yaml): per finding a reason, the binaries
  it was assessed for, and an **expiry date**. The same CVE in any other binary still blocks.
  Accepted findings stay visible in the report, marked `ignored`.
- **When an exception expires**, the scan fails again - the weekly one too. Then: if a fixed release
  exists (the Dependabot PR is usually already open), delete the entry and merge the update;
  otherwise assess again and move the date.

Currently 7 findings are accepted (5 in the `tofu` binary, 2 in the Vault provider), valid until
2026-11-08. All are fixed in Go 1.27.2 or newer libraries but not yet in any release of OpenTofu or
the provider. All affect code this image does not use: HTTP file serving and TLS servers with ECH
(both binaries are TLS clients only), the x/mod sumdb client (not even compiled into `tofu`), and
gRPC servers with xDS.

Rebuilding from source is possible, but deliberately not the way: a self-built provider no longer
matches the registry's checksums and signature, and existing lock files would break.

The Security tab (SARIF upload) needs GitHub Advanced Security on private repositories; without it
only the upload fails, not the job.

### Registry and tags

Images are pushed to the GitHub Container Registry: `ghcr.io/<owner>/<repository>/opentofu`.

| Tag | Meaning |
|-----|---------|
| `X.Y.Z` | one release, immutable |
| `X.Y`, `X` | the latest release of that minor or major version |
| `latest` | the latest release |
| `sha-<commit>` | every build on `main`, released or not |

## Versioning

The image has its own SemVer version. It is derived **automatically from the content**, not from
commit messages: [scripts/next-version.sh](scripts/next-version.sh) compares the versions of
OpenTofu and every provider between the last release tag and the current state.

| Change since the last release | Bump | Example |
|-------------------------------|------|---------|
| major version of OpenTofu or a provider, provider removed | **major** | Vault provider 5.12.0 → 6.0.0 |
| minor version of OpenTofu or a provider, provider added | **minor** | OpenTofu 1.13.1 → 1.14.0 |
| anything else below `images/` (patch versions, Alpine, Dockerfile, ...) | **patch** | Alpine 3.24.2 → 3.24.3 |
| nothing below `images/` (e.g. README only) | no release | |

For consumers this means: `:1` gets every update except those that can break existing
configurations - a new major provider version never lands in `:1` on its own.

The first release is `1.0.0`. Release notes list the versions each image contains.

**Manual release:** *Actions → image → Run workflow* with `patch`/`minor`/`major` forces a release,
even without file changes. Typical case: the weekly scan reports a vulnerability in an Alpine
package - a rebuild picks up the fixed package, and `patch` publishes it.

## Updates

**Dependabot** ([.github/dependabot.yml](.github/dependabot.yml)) opens weekly pull requests for

- OpenTofu (`-minimal` tag + digest) and Alpine in the Dockerfile,
- the providers in `versions.tf`, together with `.terraform.lock.hcl`,
- the GitHub Actions used by the workflows.

Every PR runs the full pipeline; once merged, a release follows automatically by the rules above.

For providers, Dependabot uses the community-maintained `opentofu` ecosystem: it looks up versions
on `registry.opentofu.org` - where the image gets its providers - and updates the lock file along
with them. Whether the lock file comes out complete for both platforms (amd64 + arm64) is to be
checked on the first provider PR: `task providers:lock` on the PR branch must produce no diff;
otherwise commit the regenerated file.

**Notifications:** an update shows up as a pull request with old → new version and the release
notes of the provider or OpenTofu. Watching the repository sends an email or GitHub notification
for it. Dependabot *alerts* (security advisories) do not exist for providers - the GitHub Advisory
Database does not cover Terraform/OpenTofu providers. The Trivy scan reports vulnerabilities in
providers instead.

In addition, [scan.yml](.github/workflows/scan.yml) scans the `latest` image every Monday. New CVEs
also appear in images that did not change; a failed run is the notification.

Dependabot does not update the "What's inside" table above; the release notes, generated from the
files, are always accurate.

## Local development

Requirements: Docker, [Task](https://taskfile.dev), and `curl`, `jq` and `unzip`. hadolint,
shellcheck, Trivy and OpenTofu run in containers.

```shell
task              # lint, build (with smoke test), test, scan, licenses - what a pull request runs
task build        # build only
task scan         # Trivy over image and providers
task licenses     # license check
task version      # the version a release would get now
task providers:lock
```

### Adding a provider

1. Check its license: it has to be on [.licenses-allowed.txt](.licenses-allowed.txt).
2. Add the provider with an exact version and a `registry.opentofu.org/...` source to
   [images/opentofu/providers/versions.tf](images/opentofu/providers/versions.tf).
3. Run `task providers:lock`.
4. Use the provider in [images/opentofu/test/baked/main.tf](images/opentofu/test/baked/main.tf), so
   the smoke test covers it.
5. Add it to the "What's inside" and "Third-party software" tables. The release will be a minor
   release automatically.

## License

The code in this repository - Dockerfile, scripts, workflows, documentation - is licensed under the
[Apache License 2.0](LICENSE).

### Third-party software

The image redistributes third-party software, unmodified and under its own license. The Apache
License of this repository does not apply to it.

Every build checks these licenses ([scripts/license-check.sh](scripts/license-check.sh)): each
license found - Alpine packages, the providers' license files, and the `LICENSE` of the exact
OpenTofu release in the image - has to be on [.licenses-allowed.txt](.licenses-allowed.txt).
Licenses that restrict redistribution or use (BUSL, SSPL, Elastic, ...) are not on it, and a
component whose license cannot be identified fails the build as well. If a provider or OpenTofu
changes its license in a new version, the update does not get through.

| Component | License | Source |
|-----------|---------|--------|
| OpenTofu | MPL-2.0 | [github.com/opentofu/opentofu](https://github.com/opentofu/opentofu) (the tag of the version in "What's inside") |
| Provider `hashicorp/vault` | MPL-2.0 | [github.com/hashicorp/terraform-provider-vault](https://github.com/hashicorp/terraform-provider-vault); the license text ships inside the provider package in the image |
| Alpine Linux and its packages | various, e.g. GPL-2.0 (busybox, git), GPL-3.0-or-later (bash), MIT (musl) | [Alpine aports](https://gitlab.alpinelinux.org/alpine/aports) for the release in "What's inside"; `apk info -a <package>` in the image lists each package's license |
