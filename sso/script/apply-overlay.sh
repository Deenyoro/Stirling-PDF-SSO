#!/bin/bash
set -euo pipefail

# ---------------------------------------------------------------------------
# SSO Overlay — apply-overlay.sh
# ---------------------------------------------------------------------------
# Copies the custom SSO/Enterprise unlock code into the Stirling-PDF source
# tree at Docker build time. Uses rsync --ignore-existing so upstream files
# are NEVER overwritten — new files only.
#
# Modifications to EXISTING upstream files are handled separately by
# apply-patches.sh (unified diffs). This split keeps `git merge upstream/main`
# conflict-free for everything except the small number of patched files.
#
# Called from the Dockerfile after "COPY . ." and before the Gradle build.
# ---------------------------------------------------------------------------

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SSO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
APP_ROOT="$(cd "${SSO_ROOT}/.." && pwd)"

COLLISIONS=0

echo "=========================================="
echo "SSO: Applying overlay"
echo "  Source: ${SSO_ROOT}"
echo "  Target: ${APP_ROOT}"
echo "=========================================="

# --- Collision detection -----------------------------------------------------
# Catch overlay files that would collide with an existing upstream file BEFORE
# rsyncing. rsync --ignore-existing would silently skip them, so fail loudly
# instead — a collision means the change belongs in a patch, not the overlay.
check_collisions() {
  local src_dir="$1"
  local target_dir="$2"
  local dir_name="$3"

  while IFS= read -r -d '' file; do
    local rel_path="${file#"${src_dir}/"}"
    local target_file="${target_dir}/${rel_path}"
    if [ -f "${target_file}" ]; then
      echo "SSO: ERROR — Collision: ${dir_name}/${rel_path} already exists upstream"
      echo "SSO:   Move this change into sso/patches/ as a unified diff instead."
      COLLISIONS=$((COLLISIONS + 1))
    fi
  done < <(find "${src_dir}" -type f ! -name '.gitkeep' -print0)
}

# --- Overlay directories -----------------------------------------------------
OVERLAY_DIRS="app"

for dir in ${OVERLAY_DIRS}; do
  if [ -d "${SSO_ROOT}/${dir}" ]; then
    file_count=$(find "${SSO_ROOT}/${dir}" -type f ! -name '.gitkeep' | wc -l)
    check_collisions "${SSO_ROOT}/${dir}" "${APP_ROOT}/${dir}" "${dir}"
    rsync -rv --ignore-existing --exclude='.gitkeep' "${SSO_ROOT}/${dir}/" "${APP_ROOT}/${dir}/"
    echo "SSO: Overlaid ${dir}/ (${file_count} files)"
  fi
done

# --- Final report ------------------------------------------------------------
if [ "${COLLISIONS}" -gt 0 ]; then
  echo "=========================================="
  echo "SSO: FATAL — ${COLLISIONS} file collision(s) detected!"
  echo "SSO: Overlay files must NOT share paths with upstream Stirling-PDF files."
  echo "=========================================="
  exit 1
fi

echo "=========================================="
echo "SSO: Overlay applied successfully"
echo "=========================================="
