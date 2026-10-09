#!/bin/sh
# Smoke test of the image: run inside it, with the directory holding this script as the argument.
#
#   sh smoke.sh /path/to/test
#
# Runs at the end of the image build without network (see the Dockerfile) and again in the
# pipeline against the image pushed to the registry. Leaves nothing behind.
set -eu

src="${1:?usage: smoke.sh <test directory>}"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

# Without a lock file, the way a project does its first `tofu init`. The test configurations name
# no version, so this resolves to whatever the image mirrors.
cp -R "$src/baked" "$src/not-baked" "$work/"

export TF_IN_AUTOMATION=1

tofu version

echo "--- the tools pipelines rely on are present"
for tool in bash git jq ssh; do
  command -v "$tool" >/dev/null || { echo "FAIL: $tool is missing from the image" >&2; exit 1; }
done
echo '{"ok":true}' | jq -e .ok >/dev/null

echo "--- a baked-in provider installs from the mirror"
cd "$work/baked"
tofu init -input=false -backend=false -no-color
tofu validate -no-color
tofu providers -no-color

echo "--- a provider that is not baked in is refused"
cd "$work/not-baked"
if tofu init -input=false -backend=false -no-color >init.log 2>&1; then
  cat init.log
  echo "FAIL: tofu init installed a provider that is not baked into the image" >&2
  exit 1
fi
if ! grep -q 'hashicorp/null' init.log; then
  cat init.log
  echo "FAIL: tofu init failed, but not because of the provider that is not baked in" >&2
  exit 1
fi
echo "refused as expected"

echo "--- smoke test passed"
