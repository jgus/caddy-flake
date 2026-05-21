#!/usr/bin/env -S nix shell nixpkgs#bash nixpkgs#gh nixpkgs#jq nixpkgs#gnused nixpkgs#coreutils --command bash

# Bumps pin.nix to the latest GitHub release of each pinned Caddy plugin, then re-validates the combined vendor hash. Run from the flake root: `nix run .#update-version`.
#
# Plugins are referenced by their full Go module path (e.g. github.com/caddy-dns/cloudflare). The combined hash is the `outputHash` of caddy's xcaddy-built source tree (see nixpkgs caddy/plugins.nix); it can drift any time a plugin version OR an underlying nixpkgs piece (xcaddy / go / caddy / transitive Go deps) moves, so we always re-validate: try the build with the current hash, and on mismatch extract the actual hash from nix's error and rewrite pin.nix. The build always runs against this flake's own pinned nixpkgs — consumers must NOT `follows` nixpkgs into us, or the hash will mismatch under their nixpkgs.

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

# Compare plugin lists (order-stable: same indexes).
versions_changed=0
for i in "${!cur_plugins[@]}"; do
  if [[ "${cur_plugins[${i}]}" != "${new_plugins[${i}]}" ]]; then
    versions_changed=1
    break
  fi
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

if (( versions_changed )); then
  echo "Plugin versions changed; writing pin.nix and re-validating vendor hash..."
else
  echo "All plugins already at latest versions; re-validating vendor hash..."
fi
# Write the (possibly updated) plugin list with the existing hash. The build below will tell us whether that hash still matches, and the mismatch error gives us the right hash if it doesn't.
write_pin "${cur_hash}"

echo "Building caddy..."
set +e
build_out=$(nix build --option post-build-hook "" \
  "${FLAKE_ROOT}#caddy" --no-link 2>&1)
build_exit=$?
set -e

if (( build_exit != 0 )); then
  new_hash=$(printf '%s\n' "${build_out}" | sed -nE 's/.*got:[[:space:]]+(sha256-[A-Za-z0-9+/=]+).*/\1/p' | head -1)
  if [[ -z "${new_hash}" ]]; then
    echo "error: caddy build failed and it wasn't a hash mismatch:" >&2
    printf '%s\n' "${build_out}" >&2
    printf '%s' "${original_pin}" > "${pin}"
    exit 1
  fi
  echo "  vendor hash drift: ${cur_hash:-<empty>} -> ${new_hash}"
  write_pin "${new_hash}"

  echo "Verifying caddy build..."
  nix build --option post-build-hook "" \
    "${FLAKE_ROOT}#caddy" --no-link
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
