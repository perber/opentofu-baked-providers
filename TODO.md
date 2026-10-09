# TODO

## Signed attestations for the image

**Status:** open - waiting for the decision whether the repository stays public.

**Today:** every image on `main` carries BuildKit provenance (unsigned) in the registry, and each
release has a complete SBOM (providers included) as release assets. Neither is signed: a consumer
cannot verify that an image really comes from this repository's workflow, unmodified.

**Goal:** a signed build provenance and a signed SBOM bound to the image digest, verifiable before
use - e.g. `gh attestation verify oci://ghcr.io/<owner>/<repository>/opentofu:<version> -R
<owner>/<repository>`, or `cosign verify-attestation`, or a cluster policy (Kyverno, ...).

**Options - the right one depends on the repository's visibility:**

| | Public repository | Private repository |
|---|---|---|
| [GitHub artifact attestations](https://docs.github.com/en/actions/security-for-github-actions/using-artifact-attestations) (`actions/attest-build-provenance`, `actions/attest-sbom`) | available, free, keyless (Sigstore via the workflow's OIDC identity) | requires GitHub Enterprise Cloud |
| cosign keyless, public Sigstore | possible | possible, but repository name, workflow and commit go into the **public** Rekor transparency log |
| cosign with a key pair | possible | possible; the key is a secret to manage and rotate |

**Recommendation:**

- Stays public → GitHub artifact attestations. In the `build` job on `main`, after the push:
  `actions/attest-build-provenance` and `actions/attest-sbom` (with `out/sbom/sbom.spdx.json`) for
  `subject-name: <image>`, `subject-digest: <digest>`, `push-to-registry: true`; job permissions
  `id-token: write` and `attestations: write`. The release job promotes by digest, so the
  attestations cover every version tag.
- Goes private (without Enterprise Cloud) → cosign with a key pair stored as a repository secret,
  or no signature: pulling a private image needs registry credentials, which covers who can get the
  image, not whether it was tampered with.

Either way: add a "Verifying the image" section to the README with the command consumers run.
