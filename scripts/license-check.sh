#!/usr/bin/env bash
# License check of everything the image redistributes.
#
#   scripts/license-check.sh <image reference>
#
# Fails when
# - an Alpine package or a license file carries a license that is not in `.licenses-allowed.txt`,
# - a baked-in provider ships no license file Trivy can identify,
# - the license of the OpenTofu release in the image cannot be identified.
#
# OpenTofu needs its own step: the binary comes without a license file, and Trivy cannot tell a Go
# binary's license from the binary. The script fetches `LICENSE` from the OpenTofu repository at
# exactly the version the image reports, so a relicensing upstream shows up here and does not go
# unnoticed. The providers carry their `LICENSE` inside their package; it is scanned unpacked.
#
# Writes `out/licenses/report.txt` (and the GitHub job summary).
#
# Environment:
#   TRIVY   the trivy command (default `trivy`), e.g. a `docker run ... aquasec/trivy`
set -euo pipefail

image="${1:?usage: license-check.sh <image reference>}"
read -ra trivy <<<"${TRIVY:-trivy}"
out="out/licenses"
allowed_file=".licenses-allowed.txt"

rm -rf "$out"
mkdir -p "$out/files/providers" "$out/files/opentofu"

# ── Collect ─────────────────────────────────────────────────────────────────────────────────────────
container="$(docker create "$image")"
trap 'docker rm --force "$container" >/dev/null' EXIT
docker cp --quiet "${container}:/usr/share/opentofu/providers/." "$out/files/providers/"
find "$out/files/providers" -name '*.zip' -execdir unzip -qo {} \; -delete

tofu_version="$(docker run --rm --entrypoint tofu "$image" version -json | jq -r '.terraform_version')"
curl -sfL --retry 3 -o "$out/files/opentofu/LICENSE" \
  "https://raw.githubusercontent.com/opentofu/opentofu/v${tofu_version}/LICENSE"

# ── Scan ────────────────────────────────────────────────────────────────────────────────────────────
# `--license-full` makes Trivy classify license files, not only package metadata.
"${trivy[@]}" image --quiet --scanners license --format json --output "$out/image.json" "$image"
"${trivy[@]}" rootfs --quiet --scanners license --license-full --format json \
  --output "$out/files.json" "$out/files"

# One line per finding: `<what> <TAB> <license>`.
jq -r '.Results[]? | .Licenses[]? | "\(.PkgName)\t\(.Name)"' "$out/image.json" >"$out/found.tsv"
jq -r '.Results[]? | .Licenses[]? | "\(.FilePath)\t\(.Name)"' "$out/files.json" >>"$out/found.tsv"

# ── Check ───────────────────────────────────────────────────────────────────────────────────────────
mapfile -t allowed < <(grep -vE '^[[:space:]]*(#|$)' "$allowed_file" | sed 's/[[:space:]]//g')
is_allowed() {
  local license="$1" entry
  for entry in "${allowed[@]}"; do [ "$entry" = "$license" ] && return 0; done
  return 1
}

problems=()
while IFS=$'\t' read -r what license; do
  is_allowed "$license" || problems+=("${what}: ${license} is not in ${allowed_file}")
done <"$out/found.tsv"

# Every provider directory (registry.opentofu.org/<namespace>/<name>) needs an identified license.
while IFS= read -r dir; do
  rel="${dir#"$out/files/"}"
  grep -qF "${rel}/" "$out/found.tsv" || problems+=("${rel}: no license file identified")
done < <(find "$out/files/providers" -mindepth 3 -maxdepth 3 -type d | sort)

grep -q "^opentofu/LICENSE" "$out/found.tsv" ||
  problems+=("opentofu ${tofu_version}: license not identified")

# ── Report ──────────────────────────────────────────────────────────────────────────────────────────
{
  echo "OpenTofu ${tofu_version}, providers and Alpine packages of ${image}"
  echo
  printf '%-70s %s\n' "COMPONENT" "LICENSE"
  sort -u "$out/found.tsv" | while IFS=$'\t' read -r what license; do
    printf '%-70s %s\n' "$what" "$license"
  done
} >"$out/report.txt"
cat "$out/report.txt"

if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
  {
    echo "### Licenses"
    echo
    if [ "${#problems[@]}" -eq 0 ]; then echo "All licenses allowed."; else printf -- '- **%s**\n' "${problems[@]}"; fi
    echo
    echo '<details><summary>All components</summary>'
    echo
    echo '```'
    cat "$out/report.txt"
    echo '```'
    echo '</details>'
  } >>"$GITHUB_STEP_SUMMARY"
fi

if [ "${#problems[@]}" -gt 0 ]; then
  printf 'FAIL: %s\n' "${problems[@]}" >&2
  exit 1
fi
echo "license check passed"
