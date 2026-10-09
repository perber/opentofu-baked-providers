#!/usr/bin/env bash
# Trivy scan of the image AND of the providers baked into it.
#
#   scripts/scan.sh <image reference>
#
# The providers have to be scanned on their own: the image ships them as the zips the registry
# serves (see the Dockerfile for why), and Trivy does not look inside zips. A scan of the image alone
# reports the OpenTofu binary and the Alpine packages, but never a vulnerability in a provider.
#
# Reports HIGH and CRITICAL into `out/scan/*.txt` (and the GitHub job summary), writes SARIF with
# every finding into `out/scan/*.sarif`, then fails if a HIGH or CRITICAL vulnerability with a fix
# exists. Unfixed findings are left out - there is nothing to update to.
#
# A finding that cannot be fixed yet and does not affect the image is accepted in
# `.trivyignore.yaml`, with a reason and an expiry date. Accepted findings still show up in the
# report, marked as suppressed, so they never disappear from view.
#
# Environment:
#   TRIVY            the trivy command (default `trivy`), e.g. a `docker run ... aquasec/trivy`
#   REPORT_SEVERITY  reported severities (default HIGH,CRITICAL)
#   GATE_SEVERITY    severities that fail the scan (default HIGH,CRITICAL)
set -euo pipefail

image="${1:?usage: scan.sh <image reference>}"
read -ra trivy <<<"${TRIVY:-trivy}"
report_severity="${REPORT_SEVERITY:-HIGH,CRITICAL}"
gate_severity="${GATE_SEVERITY:-HIGH,CRITICAL}"
out="out/scan"

rm -rf "$out"
mkdir -p "$out/providers"

# The providers, unpacked, out of the image under test - not out of the source tree, so the scan
# covers exactly what ships.
container="$(docker create "$image")"
trap 'docker rm --force "$container" >/dev/null' EXIT
docker cp --quiet "${container}:/usr/share/opentofu/providers/." "$out/providers/"
find "$out/providers" -name '*.zip' -execdir unzip -qo {} \; -delete

common=(--ignorefile .trivyignore.yaml --quiet)

# The first run fetches the vulnerability database, the others reuse it.
"${trivy[@]}" image "${common[@]}" --ignore-unfixed --severity "$report_severity" \
  --show-suppressed --format table --output "$out/image.txt" "$image"
common+=(--skip-db-update)
"${trivy[@]}" rootfs "${common[@]}" --ignore-unfixed --severity "$report_severity" \
  --show-suppressed --format table --output "$out/providers.txt" "$out/providers"

"${trivy[@]}" image "${common[@]}" --format sarif --output "$out/image.sarif" "$image"
"${trivy[@]}" rootfs "${common[@]}" --format sarif --output "$out/providers.sarif" "$out/providers"

for target in image providers; do
  echo "=== ${target} (${report_severity}, fixable only)"
  cat "$out/${target}.txt"
done
if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
  for target in image providers; do
    # shellcheck disable=SC2016 # the backticks are a markdown code fence, not a command
    printf '### Trivy: %s\n\nReported: %s, fixable only. Fails on: %s.\n\n```\n%s\n```\n\n' \
      "$target" "$report_severity" "$gate_severity" "$(cat "$out/${target}.txt")"
  done >>"$GITHUB_STEP_SUMMARY"
fi

status=0
"${trivy[@]}" image "${common[@]}" --ignore-unfixed --severity "$gate_severity" \
  --exit-code 1 --format table --output /dev/null "$image" || status=1
"${trivy[@]}" rootfs "${common[@]}" --ignore-unfixed --severity "$gate_severity" \
  --exit-code 1 --format table --output /dev/null "$out/providers" || status=1

if [ "$status" -ne 0 ]; then
  echo "FAIL: fixable ${gate_severity} vulnerabilities - see the reports above" >&2
else
  echo "scan passed: no fixable ${gate_severity} vulnerabilities"
fi
exit "$status"
