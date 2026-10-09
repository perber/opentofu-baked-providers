---
name: bake-in-provider
description: 'Add, update, or remove a provider baked into the OpenTofu image, with every file that has to move with it: versions.tf, the lock file, the smoke test, the scan exceptions, and the README. Use when asked to add a provider to the image, to bump or downgrade one by hand, to remove one, or when a tofu init with the image fails because a provider is not available.'
---

# Bake In Provider

The image installs providers only from its own mirror (`images/opentofu/tofurc` has no `direct`
block). A provider is available at run time if and only if it is in
`images/opentofu/providers/versions.tf` and its checksums are in the lock file next to it. Nothing
else - not `tofurc`, not the Dockerfile - has to change for a provider.

## When to Use This Skill

- "Add provider X to the image" / "we need X in the pipeline".
- Changing a provider version by hand (Dependabot PRs: use `dependabot-update-review`).
- Removing a provider.
- A consumer reports `tofu init` failing with "provider ... is not available" or a version
  constraint that the image cannot satisfy.

## Workflow

### 1. Check the provider and pick the version

```shell
curl -sf https://registry.opentofu.org/v1/providers/<namespace>/<name>/versions \
  | jq -r '.versions[].version' | sort -V | tail -5
```

- It has to exist on `registry.opentofu.org`. If it only exists on registry.terraform.io, stop and
  report that; do not add another installation source.
- Check its license before anything else - the image redistributes the provider:
  ```shell
  gh api repos/<owner>/terraform-provider-<name>/license --jq .license.spdx_id   # repository from the registry's provider page
  ```
  It has to be on `.licenses-allowed.txt`. Not on the list → stop and ask; BUSL, SSPL, Elastic,
  "NOASSERTION" or no license → the provider does not go in (AGENTS.md, invariant 7). The package
  has to ship a `LICENSE` file, or `task licenses` fails later anyway.
- Use an exact version, normally the latest release. For an update, read the provider's changelog
  between the old and the new version and list breaking changes for the report.

### 2. Edit `images/opentofu/providers/versions.tf`

```hcl
    <local-name> = {
      source  = "registry.opentofu.org/<namespace>/<name>"
      version = "<exact version>"
    }
```

- `source` names the host explicitly, so no tool that reads the file can resolve it elsewhere.
- `version` is exact, never a range: the mirror would take whatever is newest at build time.
- Add a one-line comment when the reason for the provider is not obvious from its name.

To **remove** a provider, delete its block here; the next step drops it from the lock file.

### 3. Regenerate the lock file

```shell
task providers:lock
```

Regenerates the lock file from scratch with the `tofu` of the image itself, for `linux_amd64` and
`linux_arm64`. Check the diff: only the provider you changed moves, its block is keyed
`registry.opentofu.org/<namespace>/<name>`, and the output says the package is signed. An unsigned
provider is a finding to report, not something to continue past.

### 4. Cover it in the smoke test

Use the provider in `images/opentofu/test/baked/main.tf`, so `tofu validate` starts the binary and
loads its schema:

- add it to `required_providers` (bare `<namespace>/<name>`, no version - the way consumers write it)
- add one `provider` block with dummy, non-routable settings (e.g. `.invalid` hosts) if it requires
  configuration
- add one simple resource or data source of it

`tofu validate` never configures providers or calls APIs, so no credentials are needed. When
removing a provider, remove it here too. Do not use the provider in `test/not-baked/main.tf`;
that test must keep naming a provider that is NOT baked in.

### 5. Build, test, scan

```shell
task          # lint, build (offline smoke test), test, scan, licenses
```

A new or updated provider binary often brings its own Trivy findings. Handle them with the
`trivy-exception-review` skill - entries for a provider use the path
`registry.opentofu.org/<namespace>/<name>/terraform-provider-<name>` (check the exact binary name
in the scan report). When removing a provider, delete its paths from `.trivyignore.yaml`.

If the scan stays red - findings that are neither fixable nor acceptable - the provider does not go
in yet: commit the change to a branch, not to `main`, and report the blocking findings (see "When
nothing can be fixed or accepted" in `trivy-exception-review`). Providers built with an outdated Go
toolchain are the usual case.

### 6. Documentation and expected release

- `README.md`: the "What's inside" table, a row in the "Third-party software" table (license and
  source repository), and every other place that names the
  baked-in providers - the smoke test description in the pipeline section, the usage example,
  the Trivy section if exceptions changed.
- Commit, then show the release this change will trigger once merged (`task version` compares the
  last tag with HEAD, so uncommitted changes do not count; `git fetch --tags` first if the clone
  has a remote):
  ```shell
  task version
  ```
  Expected: provider added → **minor**, minor/patch update → **minor**/**patch**,
  major update or removal → **major**. A major release needs a note for consumers in the PR
  description: what breaks and what they have to change.

## Report

- provider, old → new version, signed yes/no, license
- breaking changes from the changelog (for updates)
- Trivy result and any new exceptions
- expected image release (`task version`)
