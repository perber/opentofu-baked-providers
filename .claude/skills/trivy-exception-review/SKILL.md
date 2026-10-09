---
name: trivy-exception-review
description: 'Decide what to do about Trivy findings in the OpenTofu image: fix by update, accept with a scoped and expiring entry in .trivyignore.yaml, renew, or remove an entry. Use when the image or weekly scan workflow fails, when an entry in .trivyignore.yaml expires or is about to, when asked whether a CVE affects the image, or when an update may have made accepted findings obsolete.'
---

# Trivy Exception Review

The scan in `scripts/scan.sh` fails on every fixable HIGH or CRITICAL finding in the image AND in the
unpacked providers. `.trivyignore.yaml` is the only way past that gate, so every entry is a security
decision. This skill makes that decision reproducible.

**Order of preference: update > rebuild > accept.** An exception is the last option, never the first.

## When to Use This Skill

- The `image` workflow fails in the `trivy scan` step, or the weekly `scan` workflow fails.
- An entry in `.trivyignore.yaml` has expired or expires within the next week.
- Someone asks whether a CVE affects the image.
- After an update of OpenTofu or a provider: some accepted findings may be fixed now.

## Workflow

### 1. Get the findings

Locally (Docker and Task only; see Commands in `AGENTS.md` for `BUILDX_BUILDER`):

```shell
task build && task scan
```

In CI, the job summary of the failed run has the same report. The most common cause of a red scan
without any change is an **expired entry**: the findings in the report are then exactly the ones
`.trivyignore.yaml` lists. Note for every finding:

- **target**: the image (`usr/local/bin/tofu`, an Alpine package) or a provider
  (`registry.opentofu.org/<namespace>/<name>/terraform-provider-<name>`)
- **package** and **installed version** (`stdlib` means the Go toolchain the binary was built with)
- **CVE** and **fixed version**
- whether it is **new** or an **expired** entry from `.trivyignore.yaml`

### 2. Look for a fix you can ship

Check these before considering an exception:

1. **Alpine package** (Type `alpine`): never accept. A rebuild installs the fixed package. If the
   base image tag is current, trigger a release with Actions → image → Run workflow → `patch`. If a
   newer Alpine base exists, update the `FROM` line (tag AND digest).
2. **OpenTofu binary**: is there a newer OpenTofu release than the one in the `FROM` line of
   `images/opentofu/Dockerfile`?
   ```shell
   gh api repos/opentofu/opentofu/releases --jq '.[0:5][] | "\(.tag_name) \(.published_at)"'
   # Go version and the affected module at a tag:
   curl -sf https://raw.githubusercontent.com/opentofu/opentofu/<tag>/go.mod | grep -E '^go |<module>'
   ```
   If a release contains the fix (its `go` line / module version is at or above the fixed version),
   update to it. An open Dependabot PR may already do that.
3. **Provider binary**: same check against the provider's repository and `go.mod`, and the
   registry: `curl -sf https://registry.opentofu.org/v1/providers/<ns>/<name>/versions`. Update with
   the `bake-in-provider` skill.

Rebuilding OpenTofu or a provider from source is NOT an option: a self-built provider no longer
matches the registry checksums and signature, and every consumer's lock file breaks.

### 3. Assess reachability (only if nothing can be shipped)

Read the advisory, not only the title. The full text of every finding is in the SARIF reports
`task scan` writes: `jq -r '.runs[].tool.driver.rules[] | "\(.id): \(.fullDescription.text)"'
out/scan/image.sarif` (and `out/scan/providers.sarif`); the advisory links are in `helpUri`.

Then check how the binary uses the affected package. The strongest argument is that the vulnerable
package is not compiled in at all - Trivy flags a whole Go module by version, even if only one
harmless package of it is imported:

```shell
mkdir -p /tmp/src && curl -sfL https://github.com/<owner>/<repo>/archive/refs/tags/<tag>.tar.gz | tar -xzC /tmp/src
grep -rhoE '"<module path>/[^"]*"' --include='*.go' /tmp/src | sort | uniq -c
```

(Download into a fresh directory and only grep it - never build or run anything from it.) Accept a finding only if the vulnerable code path cannot be
reached in how the image is used. Facts about this image that usually decide it:

- `tofu` and the providers are **clients**: they make outgoing HTTPS/gRPC connections. They run no
  HTTP or TLS server reachable from outside.
- `tofu` talks gRPC only to provider processes it starts itself, over a local socket.
- `tofu` never fetches Go modules (GOPROXY/GOSUMDB), never compiles Go code.
- Providers receive input only from the configuration and from the API they manage (for the Vault
  provider: the Vault/OpenBao server, which is trusted).

Do NOT accept when:

- the vulnerable code runs in client code paths, TLS/HTTP client handling, parsing of
  configuration, state, or API responses;
- the severity is CRITICAL and you cannot show from the advisory or the code that it is unreachable;
- you are unsure. Then say so, and leave the scan red. A red pipeline is the correct state for an
  unassessed vulnerability.

### 4. Write or renew the entry

```yaml
- id: CVE-YYYY-NNNNN
  paths:
  - usr/local/bin/tofu                                              # image target
  - registry.opentofu.org/hashicorp/vault/terraform-provider-vault  # provider target
  statement: >-
    <What is vulnerable, in one sentence.> <Why that code path is not reached here.>
    Assessed YYYY-MM-DD.
  expired_at: YYYY-MM-DD
```

Rules:

- `paths` lists exactly the binaries the finding was assessed for, never left out. Without it the
  entry would silence the CVE everywhere, including in binaries no one assessed.
- `expired_at` is at most **today + 30 days**. Renewing means assessing again: check step 2
  first, then update the `Assessed` date and move the expiry.
- A change to `.trivyignore.yaml` alone touches nothing below `images/`, so merging it triggers no
  release - the pipeline and the weekly scan are green again, the published image stays the same.
  That is correct: the image did not change. Only when consumers need a rebuilt image (e.g. fresh
  Alpine packages), force one with Actions → image → Run workflow → `patch`.
- Group entries under a comment naming the cause (e.g. "Go stdlib 1.27.1 - fixed in 1.27.2"),
  like the existing ones.
- Never change `GATE_SEVERITY` or the `--ignore-unfixed` behaviour of `scripts/scan.sh` to get a
  pipeline green.

### 5. Remove entries that are no longer needed

Trivy does not warn about unused entries. After every OpenTofu or provider update, scan with an
empty ignore file and compare:

```shell
backup="$(mktemp)" && cp .trivyignore.yaml "$backup"
printf 'vulnerabilities: []\n' > .trivyignore.yaml
task scan || true          # lists everything that would fail without exceptions
cp "$backup" .trivyignore.yaml && rm "$backup"
```

Remove every entry whose CVE no longer appears for its paths. Remove a path from an entry when only
that binary is fixed.

### 6. Verify and report

```shell
task scan
```

must pass, with the accepted findings listed as `ignored` in the report. Then report:

| CVE | Target | Decision | Reason |
|-----|--------|----------|--------|
| CVE-… | tofu | updated to 1.13.2 / accepted until … / removed (fixed) / NOT accepted | … |

Update the "Currently N findings are accepted" paragraph in `README.md` (section Trivy) to match:
the number, the split per binary, the "valid until" date (the earliest `expired_at`), and the
summary of reasons.

## When nothing can be fixed or accepted

Then the scan stays red, and that is the result to report - not a problem to work around:

- **A change that introduces the finding** (a new provider, an update): do not merge it. Every
  merge to `main` that changes `images/` is released. Keep it on its branch, and report the
  blocking findings and the options: wait for a fixed upstream release, or drop the change. An
  older version is rarely the way out - it is usually built with an older Go.
- **The released image** (weekly scan, nothing changed): the image already in use is affected.
  Report it to the user right away with the advisory and what is exposed; they decide whether
  pipelines may keep using it until upstream ships a fix.
