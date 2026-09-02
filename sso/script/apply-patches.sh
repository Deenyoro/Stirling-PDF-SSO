#!/bin/bash
set -euo pipefail

# ---------------------------------------------------------------------------
# SSO Overlay — apply-patches.sh
# ---------------------------------------------------------------------------
# Applies the SSO/Enterprise unlock patches to EXISTING upstream files at
# Docker build time.
#
# Unlike the overlay (rsync --ignore-existing) which only adds NEW files,
# these patches modify existing upstream files to:
#   - bypass the keygen.sh paid-license verification (run as ENTERPRISE)
#   - keep the proprietary unit tests in sync with that behaviour
#
# TWO TIERS — this is what makes an upstream sync survivable:
#
#   REQUIRED  sso/patches/*.patch
#     Load-bearing for the unlock. If one of these cannot be applied (even
#     with fuzz), the build fails loudly — shipping an image that silently
#     is NOT unlocked is worse than a red build.
#
#   OPTIONAL  sso/patches/optional/*.patch
#     Best-effort. These are NOT compiled into the runtime image (e.g. test
#     sources — the Gradle build runs with `-x test`). If upstream drift
#     stops them applying, we warn and CONTINUE so the image still builds.
#
# Application is deliberately tolerant:
#   1. reverse dry-run  → already applied, skip.
#   2. exact dry-run    → apply cleanly.
#   3. fuzzy dry-run    → apply with -F3 --ignore-whitespace (context drift).
# `patch` already absorbs line-offset drift by default; the fuzz fallback
# additionally tolerates whitespace and small context changes. Only a genuine
# edit to the exact lines a patch adds/removes can defeat all three.
#
# To keep the required patches robust, they are written as MINIMAL insertions
# anchored on stable lines rather than large block replacements. When one does
# finally break, regenerate it against a fresh checkout:
#   git diff upstream/main HEAD -- <file> > sso/patches/<name>.patch
# `sso/script/verify-patches.sh` reports which (if any) need regenerating
# without running the whole Docker build.
# ---------------------------------------------------------------------------

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SSO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
APP_ROOT="$(cd "${SSO_ROOT}/.." && pwd)"
PATCHES_DIR="${SSO_ROOT}/patches"
OPTIONAL_DIR="${PATCHES_DIR}/optional"

if [ ! -d "${PATCHES_DIR}" ]; then
  echo "SSO: No patches directory found, skipping"
  exit 0
fi

REQUIRED_FAIL=0
APPLIED=0
SKIPPED=0
OPTIONAL_FAIL=0

echo "=========================================="
echo "SSO: Applying patches"
echo "  Patches: ${PATCHES_DIR}"
echo "  Target:  ${APP_ROOT}"
echo "=========================================="

# apply_patch <patch_file> <tier: required|optional>
apply_patch() {
  local patch_file="$1"
  local tier="$2"
  local patch_name
  patch_name="$(basename "${patch_file}")"

  # 1. Already applied? (reverse dry-run succeeds when the change is in place.)
  if patch -p1 --reverse --dry-run --directory="${APP_ROOT}" < "${patch_file}" > /dev/null 2>&1; then
    echo "SSO: SKIP (already applied) — ${patch_name}"
    SKIPPED=$((SKIPPED + 1))
    return 0
  fi

  # 2. Exact apply.
  if patch -p1 --dry-run --directory="${APP_ROOT}" < "${patch_file}" > /dev/null 2>&1; then
    patch -p1 --directory="${APP_ROOT}" < "${patch_file}" > /dev/null
    echo "SSO: APPLIED — ${patch_name}"
    APPLIED=$((APPLIED + 1))
    return 0
  fi

  # 3. Fuzzy apply (tolerate whitespace + small context drift).
  if patch -p1 -F3 --ignore-whitespace --dry-run --directory="${APP_ROOT}" < "${patch_file}" > /dev/null 2>&1; then
    patch -p1 -F3 --ignore-whitespace --directory="${APP_ROOT}" < "${patch_file}" > /dev/null
    echo "SSO: APPLIED (with fuzz) — ${patch_name}"
    echo "SSO:   Applied with fuzz/whitespace tolerance; consider regenerating this patch."
    APPLIED=$((APPLIED + 1))
    return 0
  fi

  # Could not apply by any means.
  local target
  target="$(grep -m1 '^--- a/' "${patch_file}" | sed 's|--- a/||')"
  if [ "${tier}" = "optional" ]; then
    echo "SSO: WARN (optional, skipped) — ${patch_name}"
    echo "SSO:   Target file: ${target}"
    echo "SSO:   Not baked into the runtime image; build continues. Regenerate when convenient:"
    echo "SSO:     git diff upstream/main HEAD -- ${target} > sso/patches/optional/${patch_name}"
    OPTIONAL_FAIL=$((OPTIONAL_FAIL + 1))
    return 0
  fi

  echo "SSO: ERROR — Required patch failed to apply: ${patch_name}"
  echo "SSO:   Target file: ${target}"
  echo "SSO:   Upstream changed the exact lines this patch modifies."
  echo "SSO:   Fix: regenerate against a fresh checkout —"
  echo "SSO:     git diff upstream/main HEAD -- ${target} > sso/patches/${patch_name}"
  echo "SSO:   Diagnostic:"
  patch -p1 -F3 --ignore-whitespace --dry-run --directory="${APP_ROOT}" < "${patch_file}" 2>&1 | sed 's/^/SSO:     /' || true
  REQUIRED_FAIL=$((REQUIRED_FAIL + 1))
  return 0
}

shopt -s nullglob

# Required patches (top-level only; the optional/ subdir is handled separately).
for patch_file in "${PATCHES_DIR}"/*.patch; do
  apply_patch "${patch_file}" required
done

# Optional patches (best-effort).
if [ -d "${OPTIONAL_DIR}" ]; then
  for patch_file in "${OPTIONAL_DIR}"/*.patch; do
    apply_patch "${patch_file}" optional
  done
fi

echo "=========================================="
echo "SSO: applied=${APPLIED} skipped=${SKIPPED} optional-skipped=${OPTIONAL_FAIL} required-failed=${REQUIRED_FAIL}"
echo "=========================================="

if [ "${REQUIRED_FAIL}" -gt 0 ]; then
  echo "SSO: FATAL — ${REQUIRED_FAIL} required patch(es) failed to apply!"
  echo "SSO: The Enterprise unlock would be incomplete. Sync upstream and regenerate."
  exit 1
fi

if [ "${OPTIONAL_FAIL}" -gt 0 ]; then
  echo "SSO: NOTE — ${OPTIONAL_FAIL} optional patch(es) were skipped (non-fatal)."
fi

echo "SSO: All required patch(es) applied successfully"
