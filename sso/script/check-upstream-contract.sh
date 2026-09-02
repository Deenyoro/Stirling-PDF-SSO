#!/bin/bash
set -uo pipefail

# ---------------------------------------------------------------------------
# SSO Overlay — check-upstream-contract.sh
# ---------------------------------------------------------------------------
# Verifies that the upstream symbols the overlay COMPILES AGAINST still exist.
#
# WHY: a sync can be conflict-free AND every patch can still apply, while the
# build is nonetheless broken — because upstream renamed a class, moved a
# package, or dropped a config property that sso/app/ references. Diff-based
# tooling is blind to that; only a symbol check catches it, and it catches it
# in one second instead of twenty minutes into a Docker build.
#
# The contract lives in sso/upstream-contract.tsv. Add a row whenever the
# overlay starts depending on a new upstream symbol.
#
# Usage:  sso/script/check-upstream-contract.sh
# Exit:   0 = every dependency present, 1 = something moved
# ---------------------------------------------------------------------------

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SSO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
REPO_ROOT="$(cd "${SSO_ROOT}/.." && pwd)"
CONTRACT="${SSO_ROOT}/upstream-contract.tsv"

if [ ! -f "${CONTRACT}" ]; then
  echo "SSO contract: no ${CONTRACT}, nothing to check"
  exit 0
fi

cd "${REPO_ROOT}"

OK=0
BROKEN=0
BROKEN_LINES=()

echo "=========================================="
echo "SSO: checking the upstream contract"
echo "  Contract: ${CONTRACT}"
echo "=========================================="

while IFS=$'\t' read -r path pattern reason; do
  # Skip comments and blanks.
  case "${path}" in ''|\#*) continue ;; esac
  [ -n "${pattern:-}" ] || continue

  if [ ! -e "${path}" ]; then
    echo "  GONE     ${path}"
    echo "           needed by: ${reason:-unspecified}"
    BROKEN_LINES+=("${path} — path no longer exists (${reason:-unspecified})")
    BROKEN=$((BROKEN + 1))
    continue
  fi

  # A directory row just asserts the path exists.
  if [ -d "${path}" ]; then
    OK=$((OK + 1))
    continue
  fi

  if grep -Eq -- "${pattern}" "${path}"; then
    OK=$((OK + 1))
  else
    echo "  MISSING  ${path}"
    echo "           pattern:   ${pattern}"
    echo "           needed by: ${reason:-unspecified}"
    BROKEN_LINES+=("${path} — '${pattern}' not found (${reason:-unspecified})")
    BROKEN=$((BROKEN + 1))
  fi
done < "${CONTRACT}"

echo "=========================================="
echo "SSO contract: ok=${OK} broken=${BROKEN}"
echo "=========================================="

if [ "${BROKEN}" -gt 0 ]; then
  echo
  echo "Upstream moved something the overlay depends on. The patches may still"
  echo "apply and the merge may still be clean — the BUILD is what breaks."
  echo
  echo "Fix each item above by finding where it went, then update whichever of"
  echo "these references it:"
  echo "  sso/app/...                 overlay source that imports/calls it"
  echo "  sso/patches/*.patch         patch anchored on it"
  echo "  sso/upstream-contract.tsv   this contract's row (new path/pattern)"
  echo
  echo "Locate a moved symbol with, e.g.:"
  echo "  git grep -n 'PersistentMetrics' -- '*.java' | head"
  exit 1
fi

echo "SSO contract: every upstream dependency is present."
