#!/bin/bash
set -euo pipefail

# ---------------------------------------------------------------------------
# SSO Overlay — verify-patches.sh
# ---------------------------------------------------------------------------
# Dry-runs every SSO source patch and CI patch against the CURRENT working
# tree WITHOUT running the Docker build. Use it after an upstream sync (or in
# a lightweight CI job) to find out — in seconds — whether anything needs
# regenerating.
#
# Exit code:
#   0  every REQUIRED patch still applies (optional drift is reported, not fatal)
#   1  at least one REQUIRED source patch or any CI patch no longer applies
#
# This mirrors the tolerance of apply-patches.sh: a patch counts as "ok" if it
# is already applied, applies exactly, or applies with fuzz.
# ---------------------------------------------------------------------------

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SSO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
REPO_ROOT="$(cd "${SSO_ROOT}/.." && pwd)"

REQUIRED_FAIL=0
OPTIONAL_FAIL=0
CI_FAIL=0

# check_one <patch_file> <target_root> <label>
# echoes a status line; returns 0 if applies/already-applied/fuzzy, 1 otherwise.
check_one() {
  local patch_file="$1"
  local target_root="$2"
  local label="$3"
  local name
  name="$(basename "${patch_file}")"

  # Target gone upstream -> the patch is obsolete, not broken.  Report it so
  # it can be deleted, but never fail the check on it: an upstream deletion
  # must not be able to block a sync.
  local tgt
  tgt="$(grep -m1 '^--- a/' "${patch_file}" | sed 's|--- a/||')"
  if [ -n "${tgt}" ] && [ ! -e "${target_root}/${tgt}" ]; then
    echo "  obsolete (target gone) ${label}/${name}  <- safe to 'git rm'"
    return 0
  fi

  if patch -p1 --reverse --dry-run --directory="${target_root}" < "${patch_file}" > /dev/null 2>&1; then
    echo "  ok (already applied)  ${label}/${name}"
    return 0
  fi
  if patch -p1 --dry-run --directory="${target_root}" < "${patch_file}" > /dev/null 2>&1; then
    echo "  ok (applies clean)    ${label}/${name}"
    return 0
  fi
  if patch -p1 -F3 --ignore-whitespace --dry-run --directory="${target_root}" < "${patch_file}" > /dev/null 2>&1; then
    echo "  ok (applies w/ fuzz)  ${label}/${name}  <- consider regenerating"
    return 0
  fi
  echo "  FAIL (needs regen)    ${label}/${name}"
  return 1
}

echo "=========================================="
echo "SSO: verifying patches against the current tree"
echo "=========================================="

shopt -s nullglob

echo "Required source patches (baked into the image, build-gating):"
for p in "${SSO_ROOT}"/patches/*.patch; do
  check_one "${p}" "${REPO_ROOT}" "patches" || REQUIRED_FAIL=$((REQUIRED_FAIL + 1))
done

echo "Optional source patches (best-effort, non-gating):"
for p in "${SSO_ROOT}"/patches/optional/*.patch; do
  check_one "${p}" "${REPO_ROOT}" "patches/optional" || OPTIONAL_FAIL=$((OPTIONAL_FAIL + 1))
done

echo "CI patches (re-applied to .github/workflows after a sync):"
for p in "${SSO_ROOT}"/ci-patches/*.patch; do
  check_one "${p}" "${REPO_ROOT}" "ci-patches" || CI_FAIL=$((CI_FAIL + 1))
done

# --- CI patches must still produce parseable workflow YAML -------------------
# A patch can apply "successfully" and still wreck the file: patch(1) does not
# know YAML, so an insertion landing in the wrong block yields a workflow
# GitHub refuses to run. This actually happened to ci-patch 0001, which
# inserted shell into an `env:` mapping. Apply every CI patch to a scratch
# copy of the tree and parse the result.
YAML_FAIL=0
if command -v python3 > /dev/null 2>&1 && python3 -c 'import yaml' > /dev/null 2>&1; then
  echo "CI patches produce valid workflow YAML:"
  SCRATCH="$(mktemp -d)"
  trap 'rm -rf "${SCRATCH}"' EXIT
  # Only .github/workflows is needed to validate the CI patches.
  mkdir -p "${SCRATCH}/.github"
  cp -a "${REPO_ROOT}/.github/workflows" "${SCRATCH}/.github/workflows"
  for p in "${SSO_ROOT}"/ci-patches/*.patch; do
    name="$(basename "${p}")"
    tgt="$(grep -m1 '^--- a/' "${p}" | sed 's|--- a/||')"
    [ -n "${tgt}" ] && [ -e "${SCRATCH}/${tgt}" ] || continue
    patch -p1 -F3 --ignore-whitespace --directory="${SCRATCH}" < "${p}" > /dev/null 2>&1 || true
    if python3 -c "import yaml,sys; yaml.safe_load(open(sys.argv[1]))" "${SCRATCH}/${tgt}" 2>/dev/null; then
      echo "  ok (valid yaml)       ci-patches/${name}"
    else
      echo "  FAIL (breaks yaml)    ci-patches/${name} -> ${tgt}"
      echo "                        the patch applies but the result will not parse;"
      echo "                        GitHub will refuse to run that workflow."
      YAML_FAIL=$((YAML_FAIL + 1))
    fi
  done
  rm -rf "${SCRATCH}"
  trap - EXIT
else
  echo "CI patches produce valid workflow YAML:"
  echo "  SKIP — python3 with PyYAML not available."
fi

echo "=========================================="
echo "SSO: required-fail=${REQUIRED_FAIL} optional-fail=${OPTIONAL_FAIL} ci-fail=${CI_FAIL} yaml-fail=${YAML_FAIL}"
echo "=========================================="

if [ "${REQUIRED_FAIL}" -gt 0 ] || [ "${CI_FAIL}" -gt 0 ] || [ "${YAML_FAIL}" -gt 0 ]; then
  echo "SSO: regenerate the FAILing patch(es) above with:"
  echo "SSO:   git fetch upstream && git diff upstream/main HEAD -- <target-file> > <patch-path>"
  exit 1
fi

if [ "${OPTIONAL_FAIL}" -gt 0 ]; then
  echo "SSO: ${OPTIONAL_FAIL} optional patch(es) drifted (non-fatal); regenerate when convenient."
fi

echo "SSO: all required and CI patches still apply."
