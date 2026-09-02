#!/bin/bash
set -euo pipefail

# ---------------------------------------------------------------------------
# SSO Overlay — apply-ci-patches.sh
# ---------------------------------------------------------------------------
# Re-applies the fork-specific CI overrides to .github/workflows/ after an
# upstream sync.
#
# WHY THIS EXISTS, SEPARATELY FROM apply-overlay.sh / apply-patches.sh:
#
#   - apply-overlay.sh and apply-patches.sh run INSIDE the Docker build,
#     against the source tree that gets baked into the image.
#   - GitHub Actions workflow files (.github/workflows/*.yml) must be in
#     the *repo at the commit SHA that GitHub Actions runs from* — they
#     are read by GitHub, not by the Docker build.
#   - So workflow modifications can't be deferred to Docker build time;
#     they must be present in the repo and committed before push.
#
# USAGE
#
#   # Sync from upstream Stirling-PDF main:
#   git fetch upstream main
#   git merge upstream/main    # or: gh repo sync (GitHub "Sync fork")
#
#   # Re-apply fork CI overrides if the merge clobbered any of them:
#   ./sso/script/apply-ci-patches.sh
#
#   # Review what changed, commit, push:
#   git diff .github/workflows/
#   git commit -am "ci: re-apply fork CI overrides after upstream sync"
#   git push
#
# WHAT THE PATCHES DO
#
#   0001 — force is_fork=true in _runner-pick.yml on any non-upstream repo
#          so downstream jobs pick ubuntu-latest instead of the depot.dev
#          runners that only exist on Stirling-Tools/Stirling-PDF.
#   0002 — skip push-docker.yml (upstream Docker Hub publish).
#   0004 — skip swagger.yml (upstream docs site publish).
#   0005 — skip sync_files_v2.yml (cross-repo file sync, needs upstream PAT).
#   0007 — skip build-enterprise.yml (needs PREMIUM_KEY_ENTERPRISE secret
#          AND runs against unpatched source — overlay only applies in
#          Docker build, not gradle bootRun).
#   0008 — skip frontend-backend-licenses-update.yml (License Report Workflow;
#          uses the setup-bot GitHub App token / APP_ID secret that only
#          exists on the upstream repo).
#   0009 — skip nightly.yml (Nightly E2E Tests: cross-browser Playwright +
#          Tauri desktop cache warming — upstream infra the fork doesn't ship).
#
#   (0003 and 0006 previously disabled deploy-on-v2-commit.yml and
#    testdriver.yml; upstream has since deleted both workflows, so those
#    patches were removed. Numbering is left with the gaps on purpose.)
#
# Each patch is idempotent: if it's already applied, the script skips it.
# If upstream DELETED the workflow a patch targets, the patch is reported as
# obsolete and skipped — an upstream deletion must never be able to wedge a
# sync. Only genuine drift (the file exists but the patch will not apply, even
# fuzzily) prints a regeneration hint and exits non-zero.
# ---------------------------------------------------------------------------

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SSO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
REPO_ROOT="$(cd "${SSO_ROOT}/.." && pwd)"
PATCHES_DIR="${SSO_ROOT}/ci-patches"

if [ ! -d "${PATCHES_DIR}" ]; then
  echo "SSO CI: no patches directory at ${PATCHES_DIR}, nothing to do"
  exit 0
fi

cd "${REPO_ROOT}"

APPLIED=0
SKIPPED=0
FAILED=0
OBSOLETE=0

echo "=========================================="
echo "SSO CI: re-applying fork-specific workflow overrides"
echo "  Patches: ${PATCHES_DIR}"
echo "  Target:  ${REPO_ROOT}"
echo "=========================================="

for patch_file in "${PATCHES_DIR}"/*.patch; do
  [ -f "${patch_file}" ] || continue
  patch_name=$(basename "${patch_file}")
  target=$(grep -m1 "^--- a/" "${patch_file}" | sed 's|--- a/||')

  # Target gone?  Upstream deleted the workflow this patch neutralises, so
  # there is nothing left to disable and the patch has served its purpose.
  # This is a SUCCESS, not a failure: treating it as an error would wedge
  # every future sync on a file that no longer exists.
  if [ -n "${target}" ] && [ ! -e "${REPO_ROOT}/${target}" ]; then
    echo "SSO CI: OBSOLETE (target deleted upstream) — ${patch_name}"
    echo "SSO CI:   ${target} no longer exists; delete this patch at your convenience:"
    echo "SSO CI:     git rm sso/ci-patches/${patch_name}"
    OBSOLETE=$((OBSOLETE + 1))
    continue
  fi

  # Already applied?  Reverse-apply dry-run succeeds when the patch is
  # already in place; if it does, skip without touching the file.
  if patch -p1 --reverse --dry-run --directory="${REPO_ROOT}" < "${patch_file}" > /dev/null 2>&1; then
    echo "SSO CI: SKIP (already applied) — ${patch_name}"
    SKIPPED=$((SKIPPED + 1))
    continue
  fi

  # Try a forward dry-run.  If it succeeds, apply for real.
  if patch -p1 --dry-run --directory="${REPO_ROOT}" < "${patch_file}" > /dev/null 2>&1; then
    patch -p1 --directory="${REPO_ROOT}" < "${patch_file}" > /dev/null
    echo "SSO CI: APPLIED — ${patch_name}"
    APPLIED=$((APPLIED + 1))
    continue
  fi

  # Fuzzy apply (tolerate whitespace + small context drift).  This tier must
  # exist here because verify-patches.sh accepts fuzzy patches; without it a
  # patch could verify green and then fail the actual sync.
  if patch -p1 -F3 --ignore-whitespace --dry-run --directory="${REPO_ROOT}" < "${patch_file}" > /dev/null 2>&1; then
    patch -p1 -F3 --ignore-whitespace --directory="${REPO_ROOT}" < "${patch_file}" > /dev/null
    echo "SSO CI: APPLIED (with fuzz) — ${patch_name}"
    echo "SSO CI:   Context drifted; regenerate to keep it exact:"
    echo "SSO CI:     git diff HEAD -- ${target} > sso/ci-patches/${patch_name}"
    APPLIED=$((APPLIED + 1))
    continue
  fi

  # Neither already-applied nor applicable, even fuzzily — upstream drifted.
  echo "SSO CI: ERROR — Patch failed to apply: ${patch_name}"
  echo "SSO CI:   Target file: ${target}"
  echo "SSO CI:   Cause: upstream changed the file's structure around the patched lines."
  echo "SSO CI:   Fix:"
  echo "SSO CI:     1. Open ${target} and re-apply the gate manually."
  echo "SSO CI:        Pattern:  if: github.repository == 'Stirling-Tools/Stirling-PDF'"
  echo "SSO CI:        (or for _runner-pick.yml, the is_fork=true override block)"
  echo "SSO CI:     2. Regenerate the patch:"
  echo "SSO CI:        git diff HEAD -- ${target} > sso/ci-patches/${patch_name}"
  echo "SSO CI:     3. Rerun this script."
  echo "SSO CI:   Diagnostic:"
  patch -p1 -F3 --ignore-whitespace --dry-run --directory="${REPO_ROOT}" < "${patch_file}" 2>&1 | sed 's/^/SSO CI:     /' || true
  FAILED=$((FAILED + 1))
done

echo "=========================================="
echo "SSO CI: applied=${APPLIED} skipped=${SKIPPED} obsolete=${OBSOLETE} failed=${FAILED}"
echo "=========================================="

if [ "${FAILED}" -gt 0 ]; then
  exit 1
fi

if [ "${APPLIED}" -gt 0 ]; then
  echo "SSO CI: review with 'git diff .github/workflows/' then commit + push."
fi
