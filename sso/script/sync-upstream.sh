#!/bin/bash
set -euo pipefail

# ---------------------------------------------------------------------------
# SSO Overlay — sync-upstream.sh
# ---------------------------------------------------------------------------
# One command to sync this fork with upstream Stirling-PDF and leave the repo
# in a state where CI/CD passes. Run it instead of a bare `git merge`.
#
# What it does:
#   1. fetch upstream/main
#   2. stamp a recovery ref at the current HEAD (refs/sso-presync/<timestamp>)
#   3. run the sync-safety pre-flight (merge simulation + footprint + patches)
#   4. merge upstream/main into the current branch (unless --check)
#   5. re-apply the fork's CI overrides to .github/workflows/ (apply-ci-patches)
#   6. verify every SSO source patch still applies (verify-patches)
#   7. check the upstream contract — that the symbols sso/app/ compiles
#      against still exist (check-upstream-contract)
#
# It never pushes and never force-anything. If a merge conflict or a broken
# required patch is found, it stops and tells you exactly what to fix.
#
# NEVER RECOVER A BAD SYNC WITH `git reset --hard upstream/main`, and never
# use GitHub's "Sync fork" button when it offers to DISCARD commits — both
# throw away every fork commit. That has already cost this repo its overlay
# once. Step 2 exists so there is always a way back:
#   git log --oneline refs/sso-presync/<timestamp>
#   git reset --hard refs/sso-presync/<timestamp>
#
# Usage:
#   ./sso/script/sync-upstream.sh            # fetch + merge + re-apply + verify
#   ./sso/script/sync-upstream.sh --check    # fetch + verify only (no merge)
#
# Prereqs: an 'upstream' remote pointing at Stirling-Tools/Stirling-PDF.
#   git remote add upstream https://github.com/Stirling-Tools/Stirling-PDF.git
# ---------------------------------------------------------------------------

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SSO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
REPO_ROOT="$(cd "${SSO_ROOT}/.." && pwd)"
cd "${REPO_ROOT}"

CHECK_ONLY=0
[ "${1:-}" = "--check" ] && CHECK_ONLY=1

hr() { echo "=========================================="; }

if ! git remote get-url upstream > /dev/null 2>&1; then
  echo "ERROR: no 'upstream' remote. Add it with:"
  echo "  git remote add upstream https://github.com/Stirling-Tools/Stirling-PDF.git"
  exit 1
fi

hr
echo "SSO sync: fetching upstream/main"
hr
git fetch upstream main

# --- Recovery point ----------------------------------------------------------
# Stamped BEFORE anything is merged, on every run. Costs nothing (a ref is 40
# bytes) and makes an accidental history loss trivially reversible.
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
RECOVERY_REF="refs/sso-presync/${STAMP}"
git update-ref "${RECOVERY_REF}" HEAD
hr
echo "SSO sync: recovery point stamped"
echo "  ${RECOVERY_REF} -> $(git rev-parse --short HEAD)"
echo "  Restore with: git reset --hard ${RECOVERY_REF}"
hr

# --- Pre-flight --------------------------------------------------------------
# Predicts the merge instead of discovering it the hard way. Advisory: a
# conflict is a normal thing to resolve by hand, so this warns, it doesn't block.
if [ -x "${SCRIPT_DIR}/check-sync-safety.sh" ]; then
  hr
  echo "SSO sync: pre-flight safety check"
  hr
  bash "${SCRIPT_DIR}/check-sync-safety.sh" || {
    echo
    echo "Pre-flight reported risk. Read it above before continuing."
    echo "The merge below may need manual conflict resolution."
    echo
  }
fi

if [ "${CHECK_ONLY}" -eq 0 ]; then
  if ! git diff --quiet || ! git diff --cached --quiet; then
    echo "ERROR: working tree is dirty. Commit or stash first, then re-run."
    exit 1
  fi

  hr
  echo "SSO sync: merging upstream/main"
  hr
  if ! git merge --no-edit upstream/main; then
    echo
    echo "MERGE CONFLICT — resolve the files above, then:"
    echo "  git add -A && git commit --no-edit"
    echo "  ./sso/script/sync-upstream.sh --check   # re-run the checks"
    echo
    echo "To abandon the merge entirely and go back to where you started:"
    echo "  git merge --abort"
    echo "  git reset --hard ${RECOVERY_REF}   # only if --abort is not enough"
    exit 1
  fi

  hr
  echo "SSO sync: re-applying fork CI overrides"
  hr
  bash "${SCRIPT_DIR}/apply-ci-patches.sh"
fi

hr
echo "SSO sync: verifying SSO source + CI patches still apply"
hr
if ! bash "${SCRIPT_DIR}/verify-patches.sh"; then
  echo
  echo "One or more REQUIRED patches no longer apply. Regenerate them (see hints"
  echo "above), commit, and re-run './sso/script/sync-upstream.sh --check'."
  exit 1
fi

hr
echo "SSO sync: checking the upstream contract"
hr
if ! bash "${SCRIPT_DIR}/check-upstream-contract.sh"; then
  echo
  echo "Upstream moved a symbol the overlay compiles against. Fix the references"
  echo "listed above before building — the patches applying is not enough."
  exit 1
fi

hr
if [ "${CHECK_ONLY}" -eq 1 ]; then
  echo "SSO sync: check complete — everything still applies."
else
  echo "SSO sync: done. Review, then push:"
  echo "  git diff --stat ${RECOVERY_REF} HEAD"
  echo "  git push"
  echo
  echo "Recovery point kept at ${RECOVERY_REF} — delete once you are happy:"
  echo "  git update-ref -d ${RECOVERY_REF}"
fi
hr
