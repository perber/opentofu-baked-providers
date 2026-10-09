#!/usr/bin/env bash
# Software bill of materials of the image, including the baked-in providers.
#
#   scripts/sbom.sh <image reference>
#
# Writes `out/sbom/sbom.cdx.json` (CycloneDX) and `out/sbom/sbom.spdx.json` (SPDX).
#
# Not generated from the image as it is: the providers sit in it as the zips the registry serves,
# and SBOM generators do not look inside zips - an SBOM of the image alone lists the Alpine packages
# and OpenTofu, but no provider and none of its dependencies. So the image's file system is exported,
# the provider packages are unpacked in place, and the SBOM is generated from that tree. It lists
# exactly what the image ships, with the providers as the binaries the zips contain.
#
# Environment:
#   TRIVY   the trivy command (default `trivy`), e.g. a `docker run ... aquasec/trivy`
set -euo pipefail

image="${1:?usage: sbom.sh <image reference>}"
read -ra trivy <<<"${TRIVY:-trivy}"
out="out/sbom"
rootfs="$out/rootfs"

rm -rf "$out"
mkdir -p "$rootfs"

container="$(docker create "$image")"
trap 'docker rm --force "$container" >/dev/null' EXIT
# `dev/` holds device nodes an unprivileged `tar` cannot create; there is nothing to catalogue in it.
docker export "$container" | tar -x -C "$rootfs" --exclude='dev/*'
find "$rootfs/usr/share/opentofu/providers" -name '*.zip' -execdir unzip -qo {} \; -delete

digest="$(docker image inspect --format '{{ index .RepoDigests 0 }}' "$image" 2>/dev/null || true)"

"${trivy[@]}" rootfs --quiet --format cyclonedx --output "$out/sbom.cdx.json" "$rootfs"
"${trivy[@]}" rootfs --quiet --format spdx-json --output "$out/sbom.spdx.json" "$rootfs"

# Trivy names the document after the scanned directory; name it after the image instead, with the
# digest when the image came from a registry.
subject="${digest:-$image}"
jq --arg name "$subject" '.metadata.component.name = $name | .metadata.component.type = "container"' \
  "$out/sbom.cdx.json" >"$out/sbom.cdx.json.tmp" && mv "$out/sbom.cdx.json.tmp" "$out/sbom.cdx.json"
jq --arg name "$subject" '.name = $name' \
  "$out/sbom.spdx.json" >"$out/sbom.spdx.json.tmp" && mv "$out/sbom.spdx.json.tmp" "$out/sbom.spdx.json"

rm -rf "$rootfs"

summary="$(jq -r '
  "\(.metadata.component.name)",
  "components: \(.components | length)",
  (.components[] | select(.type == "application") | "  binary: \(.name)")
' "$out/sbom.cdx.json")"
echo "$summary"
if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
  # shellcheck disable=SC2016 # the backticks are a markdown code fence, not a command
  printf '### SBOM\n\n```\n%s\n```\n' "$summary" >>"$GITHUB_STEP_SUMMARY"
fi
