#!/bin/bash
set -euo pipefail

# ---------------------------------------------------------------------------
# SSO Self-Healing Patches — heal-patches.sh
# ---------------------------------------------------------------------------
# Runs in CI (with a real git checkout) BEFORE the Docker build. Guarantees
# the unified diffs in sso/patches/ apply EXACTLY against the current tree —
# without manual intervention — even after upstream refactors shift the
# surrounding code:
#
#   1. `git apply --check`  → patch is exact, nothing to do.
#   2. `git apply --3way`   → re-anchor the change with git's 3-way merge
#      (survives context shifts, offsets, and nearby upstream edits that make
#      plain `patch` reject). The patch file is then REGENERATED from the
#      merged result, so drift never accumulates, and the refreshed patch is
#      committed & pushed back to the repo (set HEAL_PUSH_BRANCH).
#   3. `patch -p1 --force` with fuzz — last resort, result regenerated too.
#   4. If nothing lands: for a REQUIRED patch upstream rewrote the very lines
#      the unlock depends on — fail loudly (shipping a silently-locked image
#      is worse than a red build). For an OPTIONAL patch (patches/optional/,
#      not compiled into the runtime image) — warn and carry on.
#
# The working tree is left CLEAN apart from regenerated sso/patches/*.patch
# files: the Docker build still applies the patches itself, exactly as before.
# This script only guarantees they will apply.
#
# ci-patches/ are deliberately NOT healed here — they modify upstream-owned
# .github/workflows files and are applied locally, never committed, because
# committing them would break the "the fork never modifies an upstream file"
# invariant that keeps every sync conflict-free. Foreign workflows are
# switched off through the Actions API instead (see the housekeeping job in
# .github/workflows/sso-docker-build.yml).
#
# Requirements: git history for the pre-image blobs (actions/checkout with
# fetch-depth: 0). Blobless partial clones (filter=blob:none) are fine —
# git lazily fetches the blobs that `--3way` needs.
#
# Env:
#   HEAL_PUSH_BRANCH  branch to push refreshed patches to (e.g. main).
#                     Empty/unset = heal for this build only, do not push.
# ---------------------------------------------------------------------------

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SSO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
APP_ROOT="$(cd "${SSO_ROOT}/.." && pwd)"
PATCHES_DIR="${SSO_ROOT}/patches"

cd "${APP_ROOT}"

if [ ! -d "${PATCHES_DIR}" ]; then
  echo "SSO: No patches directory found, skipping"
  exit 0
fi

if ! git rev-parse --is-inside-work-tree > /dev/null 2>&1; then
  echo "SSO: FATAL — heal-patches.sh needs a git checkout (run it in CI, not in Docker)"
  exit 2
fi

HEALED=()
WARNED=()

echo "=========================================="
echo "SSO: Self-healing patch check"
echo "  Patches: ${PATCHES_DIR}"
echo "=========================================="

heal_one() {
  local patch_file="$1" tier="$2"
  local patch_name
  patch_name="$(basename "${patch_file}")"

  if git apply --check "${patch_file}" > /dev/null 2>&1; then
    echo "SSO: exact:  ${tier}/${patch_name}"
    return 0
  fi

  echo "SSO: drifted — re-anchoring with 3-way merge: ${tier}/${patch_name}"
  local files applied=""
  mapfile -t files < <(git apply --numstat "${patch_file}" | cut -f3)

  if git apply --3way "${patch_file}" > /dev/null 2>&1; then
    applied="3-way merge"
  else
    # Clear any conflict leftovers from the failed 3-way attempt.
    git checkout HEAD -- "${files[@]}" 2> /dev/null || true
    if command -v patch > /dev/null 2>&1 \
        && patch -p1 --dry-run --force < "${patch_file}" > /dev/null 2>&1; then
      patch -p1 --force --no-backup-if-mismatch < "${patch_file}" > /dev/null
      applied="fuzzy patch(1)"
    fi
  fi

  if [ -n "${applied}" ]; then
    git diff HEAD -- "${files[@]}" > "${patch_file}"
    git checkout HEAD -- "${files[@]}"
    if ! git apply --check "${patch_file}" > /dev/null 2>&1; then
      echo "SSO: FATAL — regenerated ${patch_name} is still not exact (bug?)"
      return 2
    fi
    echo "SSO: healed (${applied}): ${tier}/${patch_name}"
    HEALED+=("${tier}/${patch_name}")
    return 0
  fi

  # Nothing landed. Restore whatever the attempts touched.
  git checkout HEAD -- "${files[@]}" 2> /dev/null || true
  if [ "${tier}" = "optional" ]; then
    echo "SSO: WARN — optional patch ${patch_name} cannot be re-anchored; skipping."
    echo "SSO:        Files: ${files[*]}"
    WARNED+=("${tier}/${patch_name}")
    return 0
  fi

  echo "=========================================="
  echo "SSO: FATAL — CONFLICT in ${patch_name}"
  echo "SSO: Upstream rewrote the exact lines this REQUIRED patch changes;"
  echo "SSO: neither a 3-way merge nor a fuzzy apply can land it. A human must"
  echo "SSO: re-implement the change. See sso/README.md."
  echo "SSO: Files: ${files[*]}"
  echo "=========================================="
  return 2
}

shopt -s nullglob
for patch_file in "${PATCHES_DIR}"/*.patch; do
  heal_one "${patch_file}" required || exit 1
done
for patch_file in "${PATCHES_DIR}"/optional/*.patch; do
  heal_one "${patch_file}" optional || exit 1
done

if [ "${#WARNED[@]}" -gt 0 ]; then
  echo "SSO: ${#WARNED[@]} optional patch(es) skipped: ${WARNED[*]}"
fi

if [ "${#HEALED[@]}" -eq 0 ]; then
  echo "SSO: All patches are exact — nothing to heal."
  exit 0
fi

echo "SSO: Healed ${#HEALED[@]} patch(es): ${HEALED[*]}"

if [ -n "${HEAL_PUSH_BRANCH:-}" ]; then
  git config user.name "github-actions[bot]"
  git config user.email "41898282+github-actions[bot]@users.noreply.github.com"
  git add "${PATCHES_DIR}"
  git commit -m "chore(sso): auto-refresh drifted patches after upstream sync"
  # Best effort: a failed push (race, protection) must not fail the build —
  # the patches are already healed in this workspace and the next run heals again.
  git push origin "HEAD:refs/heads/${HEAL_PUSH_BRANCH}" \
    || echo "SSO: WARN — could not push refreshed patches (healed for this build only)"
else
  echo "SSO: HEAL_PUSH_BRANCH not set — healed for this build only."
fi
