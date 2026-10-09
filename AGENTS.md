# AGENTS.md

## Purpose

This repository builds a container image with OpenTofu and its providers baked in, for environments
that must not download provider packages at run time. `tofu init` in the image installs providers
only from a mirror inside the image; there is no other installation source.

Everything here serves that guarantee. A change that would let the image download a provider at run
time - however convenient - is out of scope.

## Repository Structure

- `images/opentofu/Dockerfile` - three stages: `base` (Alpine + `tofu` copied out of the official
  `-minimal` image), `providers` (`tofu providers mirror` from the lock file), `image` (mirror +
  CLI config + offline smoke test as the last build step).
- `images/opentofu/tofurc` - CLI configuration: `filesystem_mirror` only, deliberately no `direct`.
- `images/opentofu/providers/versions.tf` + `.terraform.lock.hcl` - which providers are baked in,
  at which exact versions and checksums.
- `images/opentofu/test/` - `smoke.sh` and two configurations: `baked/` must install offline,
  `not-baked/` must be refused.
- `scripts/next-version.sh` - next image version, derived from what changed (see Versioning).
- `scripts/scan.sh` - Trivy over the image AND the unpacked providers; the gate.
- `.trivyignore.yaml` - accepted findings, each scoped, justified and expiring.
- `scripts/license-check.sh` + `.licenses-allowed.txt` - every license the image redistributes must
  be on the allowlist.
- `scripts/sbom.sh` - SBOM of the image with the providers unpacked; attached to every release.
- `TODO.md` - open decisions (signed attestations).
- `.github/workflows/image.yml` - lint, version, build + test + scan, release. `scan.yml` - weekly
  scan of `latest`. `.github/dependabot.yml` - update PRs.
- `Taskfile.yaml` - the same steps locally. `README.md` - user documentation.

## Invariants

Do not break these. If a task seems to require it, stop and say so.

1. **No download at run time.** `tofurc` has no `direct {}` block, and nothing else may add an
   installation source (`network_mirror`, a second `filesystem_mirror` outside the image, a
   `TF_CLI_CONFIG_FILE` that drops the block). The smoke test checks that `hashicorp/null` is
   refused - keep `test/not-baked/` naming a provider that is NOT baked in.
2. **Providers come from the registry, unmodified.** The mirror keeps the packed layout (the
   original zips): consumer lock files match through their `zh:` hashes on any platform. Never
   unpack providers in the image, and never rebuild OpenTofu or a provider from source - that
   breaks the registry checksums and signatures every consumer's lock file relies on. Because they
   are zips, every tool that inspects the image - vulnerability scan, license check, SBOM - has to
   unpack them first; a new tool of that kind has to as well, or it silently misses the providers.
3. **Exact, verified versions.** Providers: exact `version`, `source` with the explicit host
   `registry.opentofu.org/...`, lock file with hashes for `linux_amd64` and `linux_arm64`, regenerated
   only with `task providers:lock`. Images: tag AND digest in every `FROM`. Actions: full commit SHA
   with the version in a trailing comment.
4. **OpenTofu from `-minimal`.** The official full image fails as a base (`ONBUILD RUN exit 1`
   since 1.10). The binary is copied out of `ghcr.io/opentofu/opentofu:<version>-minimal`.
5. **The scan gate stays.** `scripts/scan.sh` fails on fixable HIGH and CRITICAL in the image and in
   the providers. Never lower `GATE_SEVERITY`, drop `--ignore-unfixed` semantics, skip the provider
   scan, or add unscoped/non-expiring entries to `.trivyignore.yaml` to get a pipeline green.
6. **Nothing is pushed untested.** The smoke test is the last Dockerfile step and runs with
   `--network=none`; releases promote the tested and scanned image by digest, never a rebuild.
7. **Only redistributable licenses.** Everything in the image must be under a license on
   `.licenses-allowed.txt`, and `scripts/license-check.sh` enforces it. Never add BUSL, SSPL,
   Elastic, Commons Clause, a license that forbids redistribution or commercial use, or "no
   license" to the list - stop and ask instead. A new license on the list is a decision of its own:
   a separate pull request that names the component and why its license allows redistribution.
   Every component the image ships is listed under "Third-party software" in the README.

## Versioning

The image has its own SemVer version, computed by `scripts/next-version.sh` from the component
versions at the last `v*` tag vs. HEAD: OpenTofu or provider **major** change or a provider removed
→ major; **minor** change or a provider added → minor; any other change below `images/` → patch;
nothing below `images/` → no release. Every merge to `main` that changes `images/` is released
automatically and reaches consumers on floating tags (`:1`, `:latest`) within minutes.

Therefore: work on a branch and open a pull request; never commit or push to `main` directly. Do not
create `v*` tags by hand - the release job does, and the next version is computed from them.

## Commands

Requirements: Docker, [Task](https://taskfile.dev), and `curl`, `jq`, `unzip` on the host. hadolint,
shellcheck, Trivy and OpenTofu run in containers.

```sh
task                  # lint, build (offline smoke test), test, scan, licenses - what a PR runs
task build            # build into the local daemon as local/opentofu:test
task test             # smoke test in the built image
task scan             # Trivy: image + providers, same gate as CI
task licenses         # license check of everything the image redistributes
task sbom             # SBOM (CycloneDX + SPDX) of the built image into out/sbom/
task version          # release the committed HEAD would get, against the last v* tag
task providers:lock   # regenerate the lock file after editing versions.tf
```

- `task version` ignores uncommitted changes. Run `git fetch --tags` first in a clone with a remote.
- `build` and `providers:lock` use the current docker buildx builder; if it cannot reach the
  registries, prefix them with `BUILDX_BUILDER=default`.
- Several checkouts side by side need their own image names:
  `task build LOCAL_IMAGE=local/opentofu:<name> BASE_IMAGE=local/opentofu:<name>-base`.

## Skills

Use these for the recurring tasks - they hold the decision rules:

- `.claude/skills/bake-in-provider/SKILL.md` - add, update or remove a provider (license included).
- `.claude/skills/dependabot-update-review/SKILL.md` - review a Dependabot PR before merging, including
  a license change between the versions.
- `.claude/skills/trivy-exception-review/SKILL.md` - a red scan, an expiring exception, "does CVE X
  affect us".

Claude Code loads them as skills; other agents read the file at the path given.

## Conventions

- The project language is English: code, comments, documentation, commit messages, skills.
- Commit messages follow Conventional Commits, matching Dependabot's prefixes (`deps(image):`,
  `deps(providers):`, `ci:`): e.g. `feat(providers): bake in hashicorp/random`,
  `chore(trivy): renew exceptions until <date>`. They do not drive the version.
- The repository is public. No names of customers, organisations, people, internal hosts or
  paths in any file, commit message or example - use placeholders like `<owner>`.
- Comments explain why, not what - match the density and tone of the existing files.
- `CLAUDE.md` only imports this file (`@AGENTS.md`). Keep instructions here, for every agent alike.
- When a change alters what the image contains or how it behaves, update the README in the same
  change: the "What's inside" table, the "Third-party software" table, the Trivy section's count
  of accepted findings, the pipeline and versioning descriptions.
- Verify before reporting: `task` for image changes, actionlint for workflow changes
  (`docker run --rm -v "$PWD:/repo" -w /repo rhysd/actionlint:latest .github/workflows/*.yml`),
  shellcheck for scripts (part of `task lint`).
