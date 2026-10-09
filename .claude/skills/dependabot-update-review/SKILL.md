---
name: dependabot-update-review
description: 'Review a Dependabot pull request in the OpenTofu image repository before merging: OpenTofu or Alpine base image bumps, provider bumps with their lock file, and GitHub Actions bumps. Checks the lock file, breaking changes, the release the merge will trigger, and Trivy exceptions the update makes obsolete. Use when asked to review, check, or merge a Dependabot PR, or a PR labelled dependencies.'
---

# Dependabot Update Review

Every merged change below `images/` becomes a release automatically (`scripts/next-version.sh`), and
consumers on a floating tag like `:1` get it without asking. The review decides whether that is
safe. A green pipeline is necessary - it builds, runs the offline smoke test and scans - but it does
not read changelogs or check what the release number will be.

## When to Use This Skill

- Reviewing or merging a PR from Dependabot (`deps(image)`, `deps(providers)`, `ci` prefixes;
  labels `dependencies`, `image`, `providers`, `ci`).
- Several Dependabot PRs are open and someone asks which to merge first.

## Workflow

### 1. Classify the PR

```shell
gh pr view <number> --json title,labels,files,statusCheckRollup
gh pr diff <number>
# without a GitHub remote, the PR is a local branch:
git diff main...<branch> --stat && git diff main...<branch>
```

| Files changed | Type | Go to |
|---------------|------|-------|
| `images/opentofu/Dockerfile`, `FROM ghcr.io/opentofu/opentofu` | OpenTofu | 2a |
| `images/opentofu/Dockerfile`, `FROM docker.io/library/alpine` | Alpine | 2b |
| `images/opentofu/providers/*` | provider | 2c |
| `.github/workflows/*` | GitHub Actions | 2d |

### 2a. OpenTofu

- Tag and digest changed together, and the tag still ends in `-minimal`. The full image cannot be
  used as a base (it has `ONBUILD RUN exit 1`).
- Read the OpenTofu release notes between the old and the new version
  (`gh release view v<version> -R opentofu/opentofu`): breaking changes, deprecations, changed
  state or lock file behaviour, a raised minimum provider protocol.
- Nothing else has to move: `task providers:lock` builds the `base` stage and uses this version.

### 2b. Alpine

- Tag and digest changed together. A new Alpine minor (3.24 → 3.25) can drop or rename packages:
  the build fails in `apk add` if so, check the job log.

### 2c. Provider

- `versions.tf`: still an exact version, `source` still `registry.opentofu.org/...`.
- Lock file: Dependabot writes it with its own tooling. Verify it against OpenTofu -
  `task providers:lock` regenerates it from scratch, and a correct file comes out byte for byte the
  same, so this must produce no diff:
  ```shell
  gh pr checkout <number>     # or: git checkout <branch>
  task providers:lock && git diff --exit-code images/opentofu/providers/.terraform.lock.hcl
  ```
  If it changes the file, commit the regenerated lock file to the PR branch and say so in the
  review. Typical Dependabot errors: a new block keyed `registry.terraform.io/...` next to the
  `registry.opentofu.org/...` block, which still pins the OLD version; hashes for one platform only.
- Signature: the `task providers:lock` output must say `signed` for the new version.

### License (OpenTofu and providers)

A new version can come under a new license - HashiCorp moved Terraform from MPL-2.0 to BUSL-1.1 in
a minor release (1.6), and Dependabot offers such an update like any other. Compare the license at
both versions:

```shell
for tag in <old tag> <new tag>; do
  curl -sfL "https://raw.githubusercontent.com/<owner>/<repo>/${tag}/LICENSE" | head -5
done
```

`task licenses` on the PR branch must pass. Any change of license is a **hold**, whatever the
pipeline says - report it.
- Read the provider's changelog between the versions. List anything that breaks existing
  configurations (removed or renamed resources and attributes, changed defaults, auth changes).

### 2d. GitHub Actions

- Each `uses:` stays pinned to a full commit SHA with the version in the trailing comment, and the
  comment matches the SHA.
- Read the release notes for changed or removed inputs and outputs used in the workflow; run
  `docker run --rm -v "$PWD:/repo" -w /repo rhysd/actionlint:latest .github/workflows/*.yml`.
- These PRs touch nothing below `images/`, so they never trigger a release.

### 3. Check the release the merge will trigger

```shell
task version      # on the checked-out PR branch; `git fetch --tags` first if there is a remote
``` Make sure the bump is right for consumers:

- **major** (OpenTofu or provider major, provider removed): consumers on `:1` will not get it; it
  needs a note in the PR description on what breaks and how to migrate.
- **minor/patch**: consumers on `:1` get it automatically. Behaviour changes that are not breaking
  (a changed default, an attribute that now updates in place) still go into the PR description, so
  the merge commit documents them. If the changelog shows a breaking change
  despite a minor or patch version, do NOT merge silently - report it; a `major` release has to be
  forced via the workflow input after the merge, or the update held back.

### 4. Check the scan and the exceptions

- If the `trivy scan` step fails, use the `trivy-exception-review` skill.
- If it passes, check whether the update made exceptions obsolete (OpenTofu and provider updates
  often ship a newer Go): follow step 5 of `trivy-exception-review` and remove those entries in the
  same PR.

### 5. Documentation

Update the "What's inside" table at the top of `README.md` for OpenTofu, Alpine and provider
updates - Dependabot does not.

## Report

| Check | Result |
|-------|--------|
| Type, old → new | |
| Pipeline | green / red (step) |
| Lock file (providers) | unchanged by `task providers:lock` / regenerated |
| Signature (providers) | signed (key ID) / NOT signed |
| License | unchanged (`<SPDX>`) / CHANGED: old → new |
| Breaking changes from changelog | none / list |
| Release on merge | `X.Y.Z` (bump) - appropriate yes/no |
| Trivy exceptions | unchanged / removed: CVE-… |
| README table | updated / not needed |

Verdict: **merge** / **merge after fixes** (list) / **hold** (reason).

When several Dependabot PRs are open, merge provider and OpenTofu PRs one at a time: each merge is
its own release, and each later PR's `task version` changes after the previous merge.
