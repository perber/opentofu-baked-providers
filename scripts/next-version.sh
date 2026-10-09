#!/usr/bin/env bash
# Computes the next version of the image from what changed in it since the last release.
#
#   scripts/next-version.sh [auto|major|minor|patch]
#
# The image carries its own SemVer version. With `auto` (the default) the bump follows the versions
# of what the image ships, compared between the last `v*` tag and HEAD:
#
#   major  OpenTofu major version changed, a provider's major version changed, a provider removed,
#          an Alpine package removed from `apk add`
#   minor  OpenTofu minor version changed, a provider's minor version changed, a provider added,
#          an Alpine package added to `apk add`
#   patch  any other change below `images/` - patch versions, the base image, the Dockerfile, ...
#   none   nothing below `images/` changed: no release
#
# A provider major version usually breaks configurations written against the old one, and a removed
# provider or tool breaks every pipeline using it, so a consumer pinned to `:1` never gets either.
# An added tool is a new capability, like an added provider. The Alpine packages count by presence
# only: their versions are not pinned (see the Dockerfile) and move with the base image.
#
# `major`, `minor` and `patch` force that bump even without changes - e.g. to republish the image
# with the latest Alpine package fixes, which a rebuild picks up without any file changing.
#
# Prints `key=value` lines (version, previous, bump, release) and appends them to `$GITHUB_OUTPUT`
# when set. The component versions of HEAD go to `$GITHUB_STEP_SUMMARY` and to
# `out/release-notes.md`.
set -euo pipefail

mode="${1:-auto}"
image_dir="images/opentofu"
first_version="1.0.0"

case "$mode" in
  auto | major | minor | patch) ;;
  *)
    echo "usage: $0 [auto|major|minor|patch]" >&2
    exit 2
    ;;
esac

# Component versions at a git ref, one `<name> <version>` line each: OpenTofu from the `FROM` line
# of the Dockerfile, every provider from `versions.tf` by its source address without the host, every
# package of the Dockerfile's `apk add` as `alpine/<package>` with the placeholder version `-`.
components_at() {
  local ref="$1"
  git show "${ref}:${image_dir}/Dockerfile" |
    sed -nE 's#^FROM ghcr\.io/opentofu/opentofu:([0-9]+\.[0-9]+\.[0-9]+)-minimal.*#opentofu \1#p'
  git show "${ref}:${image_dir}/Dockerfile" |
    sed -nE 's#^RUN apk add --no-cache (.*)#\1#p' | tr ' ' '\n' | grep -v '^$' | sort | sed 's#^#alpine/#; s#$# -#'
  git show "${ref}:${image_dir}/providers/versions.tf" |
    awk -F'"' '
      /^[[:space:]]*source[[:space:]]*=/  { n = split($2, p, "/"); source = p[n-1] "/" p[n] }
      /^[[:space:]]*version[[:space:]]*=/ { if (source != "") { print source, $2; source = "" } }
    '
}

# The bump one component's change needs, from its old and new version (either may be empty).
component_bump() {
  local old="$1" new="$2"
  if [ -z "$new" ]; then echo major; return; fi
  if [ -z "$old" ]; then echo minor; return; fi
  IFS=. read -r old_major old_minor _ <<<"$old"
  IFS=. read -r new_major new_minor _ <<<"$new"
  if [ "$old_major" != "$new_major" ]; then echo major
  elif [ "$old_minor" != "$new_minor" ]; then echo minor
  elif [ "$old" != "$new" ]; then echo patch
  else echo none
  fi
}

rank() { case "$1" in major) echo 3 ;; minor) echo 2 ;; patch) echo 1 ;; *) echo 0 ;; esac; }

head_components="$(components_at HEAD)"
if [ -z "$head_components" ]; then
  echo "cannot read the component versions of HEAD" >&2
  exit 1
fi

previous_tag="$(git describe --tags --abbrev=0 --match 'v[0-9]*.[0-9]*.[0-9]*' 2>/dev/null || true)"

if [ -z "$previous_tag" ]; then
  previous=""
  bump="initial"
  version="$first_version"
else
  previous="${previous_tag#v}"
  bump="none"

  if [ "$mode" != "auto" ]; then
    bump="$mode"
  elif ! git diff --quiet "$previous_tag" HEAD -- "$image_dir"; then
    bump="patch"
    previous_components="$(components_at "$previous_tag")"
    names="$(printf '%s\n%s\n' "$previous_components" "$head_components" | awk '{ print $1 }' | sort -u)"
    for name in $names; do
      old="$(awk -v n="$name" '$1 == n { print $2 }' <<<"$previous_components")"
      new="$(awk -v n="$name" '$1 == n { print $2 }' <<<"$head_components")"
      this="$(component_bump "$old" "$new")"
      if [ "$this" != "none" ]; then
        echo "${name}: ${old:-(new)} -> ${new:-(removed)} => ${this}" >&2
      fi
      if [ "$(rank "$this")" -gt "$(rank "$bump")" ]; then bump="$this"; fi
    done
  fi

  IFS=. read -r major minor patch <<<"$previous"
  case "$bump" in
    major) version="$((major + 1)).0.0" ;;
    minor) version="${major}.$((minor + 1)).0" ;;
    patch) version="${major}.${minor}.$((patch + 1))" ;;
    none) version="" ;;
  esac
fi

release="false"
if [ -n "$version" ]; then release="true"; fi

output="$(printf 'version=%s\nprevious=%s\nbump=%s\nrelease=%s\n' "$version" "$previous" "$bump" "$release")"
echo "$output"
if [ -n "${GITHUB_OUTPUT:-}" ]; then echo "$output" >>"$GITHUB_OUTPUT"; fi

mkdir -p out
{
  echo "| Component | Version |"
  echo "|-----------|---------|"
  awk '$1 !~ /^alpine\// { printf "| %s | %s |\n", $1, $2 }' <<<"$head_components"
  awk '$1 ~ /^alpine\// { sub(/^alpine\//, "", $1); p = p (p ? ", " : "") $1 }
       END { if (p) printf "| Alpine packages | %s |\n", p }' <<<"$head_components"
} >out/release-notes.md

if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
  {
    echo "### Image version"
    echo
    if [ "$release" = "true" ]; then
      echo "Next release: **${version}** (${bump}, previous: ${previous:-none})"
    else
      echo "No release: nothing below \`${image_dir}\` changed since ${previous_tag}."
    fi
    echo
    cat out/release-notes.md
  } >>"$GITHUB_STEP_SUMMARY"
fi
