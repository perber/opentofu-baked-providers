# OpenTofu with its providers baked in, for environments that must not download provider
# packages at run time. `tofu init` installs every provider from a filesystem mirror inside the
# image; the CLI configuration in `tofurc` allows no other installation source, so a provider that
# is not baked in fails `tofu init` instead of being fetched from a registry.
#
# The providers are the ones `providers/versions.tf` names, at the checksums
# `providers/.terraform.lock.hcl` pins. They are downloaded HERE, at build time, where the pipeline
# has internet access, checked against those checksums and against the registry's signature, and
# scanned with the rest of the image afterwards.

# The official image is not used as a base: since OpenTofu 1.10 it carries an `ONBUILD RUN exit 1`
# that fails every `FROM` on it, and upstream asks for the binary to be copied out of the
# `-minimal` variant instead - https://opentofu.org/docs/intro/install/docker/.
FROM ghcr.io/opentofu/opentofu:1.13.1-minimal@sha256:dfbc3f0a8bed0adfa2cf49ff418f158afe24080eea6d6e748db8799fc4553db6 AS tofu

FROM docker.io/library/alpine:3.24.2@sha256:294b683cb724975bec92580e1e685676bd4b50bda910ddb8c51d4cabeaec77e6 AS base

# What the official image ships next to the binary: `git` and `openssh-client` for module sources
# in git repositories, `bash` for scripts in the pipelines that run this image. On top of that `jq`,
# for pipelines that process `tofu output -json` or `tofu show -json`. Not pinned to
# package versions on purpose - alpine removes superseded package versions from its mirrors, so a
# pin breaks the build on the next security fix, while the base image digest above already fixes
# the release the packages come from.
# hadolint ignore=DL3018
RUN apk add --no-cache bash git jq openssh-client

COPY --from=tofu /usr/local/bin/tofu /usr/local/bin/tofu

# ── Providers ──────────────────────────────────────────────────────────────────────────────────────
FROM base AS providers

# Set by BuildKit to the platform of the image being built. Only that platform's provider package
# is mirrored; the lock file carries the checksums of every platform the image is built for.
ARG TARGETOS
ARG TARGETARCH

# `tofu providers mirror` takes the versions and checksums from the lock file next to
# `versions.tf` and refuses a package that matches neither them nor the registry's signature.
#
# It writes the packed layout - the provider zip exactly as the registry serves it. Not unpacked on
# purpose: a lock file written on another platform carries the `h1:` hash of the unpacked provider
# for THAT platform only, plus the `zh:` hashes of the release zips of every platform. Against an
# unpacked mirror such a lock file has no hash to match and `tofu init` refuses the provider; the
# original zip matches its `zh:` hash wherever the lock file was written.
WORKDIR /src
COPY providers/versions.tf providers/.terraform.lock.hcl ./
RUN tofu providers mirror -platform="${TARGETOS}_${TARGETARCH}" /usr/share/opentofu/providers

# ── Image ──────────────────────────────────────────────────────────────────────────────────────────
FROM base AS image

COPY --from=providers /usr/share/opentofu/providers /usr/share/opentofu/providers
COPY tofurc /etc/opentofu/tofurc
ENV TF_CLI_CONFIG_FILE=/etc/opentofu/tofurc

# The build fails here rather than publishing an image that cannot do what it is for. The smoke
# test runs without any network, so `tofu init` can only succeed from the baked-in mirror, and it
# also checks that a provider which is NOT baked in is refused. The test files are bind-mounted and
# the script cleans up after itself, so none of it ends up in the image.
RUN --network=none --mount=type=bind,source=test,target=/test sh /test/smoke.sh /test

WORKDIR /workspace

# The same entrypoint as the official image, so it is a drop-in replacement for `docker run`.
# A CI job that runs a script in the image has to reset it - see the README.
ENTRYPOINT ["/usr/local/bin/tofu"]
