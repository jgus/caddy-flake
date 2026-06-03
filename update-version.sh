#!/usr/bin/env -S nix shell nixpkgs#bash nixpkgs#gh nixpkgs#jq nixpkgs#gnused nixpkgs#nix nixpkgs#coreutils --command bash

# Bumps pin.nix to the latest GitHub release/tag of each pinned Caddy plugin, then
# re-validates the combined xcaddy vendor hash via flake-lib's shared `revalidate-hash`
# (build → read nix's "got:" mismatch → rewrite the field → rebuild). Run from the flake
# root: `nix run .#update-version`.
#
# Plugin resolution is caddy-specific: a curated multi-component "manifest" source with no
# single upstream version, so it can't use the generic update-version. The vendor-hash
# dance, however, IS the shared build-failure strategy (flake-lib mkRevalidateHash).
# The build always runs against this flake's own pinned nixpkgs — consumers must NOT
# `follows` nixpkgs into us, or the hash will mismatch under their nixpkgs.

set -euo pipefail

if (( $# )); then
  echo "error: this script takes no arguments. Plugin selection lives in pin.nix." >&2
  exit 1
fi

FLAKE_ROOT="${FLAKE_ROOT:-${PWD}}"
pin="${FLAKE_ROOT}/pin.nix"

if [[ ! -f "${pin}" ]]; then
  echo "error: no pin.nix in ${FLAKE_ROOT}" >&2
  echo "Run from the flake root (where pin.nix lives), or set FLAKE_ROOT to point at it." >&2
  exit 1
fi

mapfile -t cur_plugins < <(nix eval --json --file "${pin}" plugins | jq -r '.[]')
cur_hash=$(nix eval --raw --file "${pin}" hash)

declare -a new_plugins=()
for entry in "${cur_plugins[@]}"; do
  module="${entry%@*}"
  cur_version="${entry##*@}"

  case "${module}" in
    github.com/*)
      # Module path may have a major-version suffix (e.g. /v2); strip everything past owner/repo for the API call.
      slug=$(echo "${module}" | cut -d/ -f2-3)
      ;;
    *)
      echo "warning: ${module} is not on GitHub; leaving at ${cur_version}." >&2
      new_plugins+=("${entry}")
      continue
      ;;
  esac
  # `gh api` emits the raw JSON error body on stdout for HTTP failures (and `--jq` is bypassed), so we MUST check exit status and only consume stdout on success — otherwise an error body gets baked into pin.nix as a "version".
  new_version=""
  echo "Querying GitHub for latest release of ${slug}..."
  if release_body=$(gh api "/repos/${slug}/releases/latest" 2>/dev/null); then
    new_version=$(jq -r '.tag_name // empty' <<<"${release_body}")
  fi
  if [[ -z "${new_version}" ]]; then
    # Many caddy plugins don't publish GitHub releases — only tags. Fall back to picking the highest semver tag (sort -V handles the "v0.2.10 > v0.2.9" case correctly).
    echo "  no release; falling back to tags..."
    if tags_body=$(gh api "/repos/${slug}/tags?per_page=100" 2>/dev/null); then
      new_version=$(jq -r '.[].name' <<<"${tags_body}" \
        | grep -E '^v?[0-9]+(\.[0-9]+){1,2}([-+].+)?$' \
        | sort -V \
        | tail -1)
    fi
  fi
  if [[ -z "${new_version}" ]]; then
    echo "warning: no release or version-shaped tag for ${slug}; leaving at ${cur_version}." >&2
    new_plugins+=("${entry}")
    continue
  fi
  # Defensive: tag must look like a normal version ref, not stray API output.
  if [[ ! "${new_version}" =~ ^v?[0-9]+(\.[0-9]+){1,2}([-+a-zA-Z0-9.]+)?$ ]]; then
    echo "warning: resolved tag '${new_version}' for ${slug} doesn't look like a version; leaving at ${cur_version}." >&2
    new_plugins+=("${entry}")
    continue
  fi

  echo "  ${module}: ${cur_version} -> ${new_version}"
  new_plugins+=("${module}@${new_version}")
done

write_pin () {
  local hash_value="$1"
  {
    echo "# Auto-managed by \`nix run .#update-version\`. Manual edits will be overwritten by the next bump."
    echo "{"
    echo "  plugins = ["
    for p in "${new_plugins[@]}"; do
      echo "    \"${p}\""
    done
    echo "  ];"
    echo "  hash = \"${hash_value}\";"
    echo "}"
  } > "${pin}"
}

# Stash the literal original pin so we can roll back on a non-hash-mismatch failure.
original_pin=$(cat "${pin}")

# Write the (possibly updated) plugin list with the existing hash. revalidate-hash will
# correct the hash if the plugin set OR an underlying nixpkgs/xcaddy/go piece moved.
write_pin "${cur_hash}"

# A non-hash build failure (e.g. a plugin version that doesn't compile) makes revalidate-hash
# exit non-zero; roll the pin back so we don't leave a broken plugin set committed.
if ! FLAKE_ROOT="${FLAKE_ROOT}" nix run --option post-build-hook "" "${FLAKE_ROOT}#revalidate-hash"; then
  echo "error: revalidation/build failed; rolling back pin.nix." >&2
  printf '%s' "${original_pin}" > "${pin}"
  exit 1
fi

echo
echo "Plugins:"
for p in "${new_plugins[@]}"; do
  echo "  ${p}"
done
if [[ "$(cat "${pin}")" != "${original_pin}" ]]; then
  echo "  pin.nix updated. Commit to capture."
else
  echo "  pin.nix unchanged."
fi
