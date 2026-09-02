#!/bin/bash
set -uo pipefail

# ---------------------------------------------------------------------------
# SSO Sync-Safety Check — check-sync-safety.sh
# ---------------------------------------------------------------------------
# Answers one question before you sync: "will pulling upstream conflict?"
#
# WHY THIS EXISTS
#   The GitHub "Sync fork" button runs `git merge upstream/main` and CANNOT
#   resolve conflicts — it just fails, and the usual escape hatch (a hard
#   reset to upstream) silently destroys the fork's commits. That is exactly
#   what happened once already.
#
# THE INVARIANT THAT KEEPS SYNCS CLEAN
#   A merge conflict requires the fork and upstream to have both changed the
#   SAME LINES of the SAME upstream-tracked file. This fork therefore holds
#   its entire footprint in files upstream does not have:
#
#       sso/                              all custom code, patches, tooling
#       Dockerfile                        fork-only (upstream ships docker/*)
#       .github/workflows/sso-docker-build.yml
#
#   Upstream files are left BYTE-FOR-BYTE PRISTINE in git. Changes to them
#   live as unified diffs under sso/patches/ (applied inside the Docker
#   build) and sso/ci-patches/ (re-applied after a sync). Zero shared lines
#   means zero possible conflicts.
#
# WHAT THIS SCRIPT CHECKS
#   [1/4] Simulates the merge with `git merge-tree` — the definitive answer.
#   [2/4] Lists the fork's footprint and fails on any MODIFIED upstream file
#         (added files are always safe; modified ones are what conflict).
#   [3/4] Dry-runs every patch so drift is caught before it breaks a build.
#   [4/4] Checks the upstream contract — the symbols sso/app/ compiles
#         against — which diffs and merge simulation are both blind to.
#
# USAGE
#   sso/script/check-sync-safety.sh           # uses upstream/main as-is
#   sso/script/check-sync-safety.sh --fetch   # git fetch upstream first
#   UPSTREAM_REMOTE=upstream UPSTREAM_BRANCH=main sso/script/check-sync-safety.sh
#
# EXIT CODES
#   0 = safe to sync   1 = conflict or risk detected   2 = setup error
# ---------------------------------------------------------------------------

UPSTREAM_REMOTE="${UPSTREAM_REMOTE:-upstream}"
UPSTREAM_BRANCH="${UPSTREAM_BRANCH:-main}"
UPSTREAM_REF="${UPSTREAM_REMOTE}/${UPSTREAM_BRANCH}"

# Paths the fork owns outright. Everything here is a NEW file that upstream
# does not track, so it can never collide during a merge.
FORK_OWNED=("sso/" "Dockerfile" ".github/workflows/sso-docker-build.yml")

FETCH=0
for arg in "$@"; do
  case "$arg" in
    --fetch) FETCH=1 ;;
    -h|--help) sed -n '2,40p' "$0"; exit 0 ;;
    *) echo "Unknown argument: $arg" >&2; exit 2 ;;
  esac
done

cd "$(git rev-parse --show-toplevel)" || { echo "Not in a git repository." >&2; exit 2; }

if [ "$FETCH" -eq 1 ]; then
  echo "Fetching ${UPSTREAM_REMOTE}…"
  git fetch "${UPSTREAM_REMOTE}" --prune || { echo "git fetch failed." >&2; exit 2; }
fi

if ! git rev-parse --verify --quiet "${UPSTREAM_REF}" >/dev/null; then
  echo "ERROR: ${UPSTREAM_REF} not found." >&2
  echo "Add the upstream remote, e.g.:" >&2
  echo "  git remote add upstream https://github.com/Stirling-Tools/Stirling-PDF.git" >&2
  echo "  git fetch upstream" >&2
  exit 2
fi

MB="$(git merge-base "${UPSTREAM_REF}" HEAD)" || { echo "No merge-base with ${UPSTREAM_REF}." >&2; exit 2; }

echo "=========================================="
echo "SSO Sync-Safety Check"
echo "  HEAD:       $(git rev-parse --short HEAD)"
echo "  Upstream:   ${UPSTREAM_REF} ($(git rev-parse --short "${UPSTREAM_REF}"))"
echo "  Merge base: $(git rev-parse --short "${MB}")"
echo "  Behind by:  $(git rev-list --count HEAD.."${UPSTREAM_REF}") upstream commit(s)"
echo "=========================================="

RISK=0

# --- [1/4] Merge simulation --------------------------------------------------
echo
echo "[1/4] Simulating 'git merge ${UPSTREAM_REF}' …"
MERGE_OUT="$(git merge-tree --write-tree --messages HEAD "${UPSTREAM_REF}" 2>&1)"
MERGE_RC=$?
if [ "${MERGE_RC}" -eq 0 ]; then
  echo "      CLEAN — the merge would apply without conflicts."
else
  echo "      CONFLICT — the merge would FAIL. Offending paths:"
  echo "${MERGE_OUT}" | grep -E 'CONFLICT|^[0-9]+ ' | sed 's/^/        /' | head -40
  echo
  echo "      Do NOT 'reset --hard' to fix this — that deletes the fork's commits."
  echo "      Resolve the listed files, keeping the fork's side out of upstream files."
  RISK=1
fi

# --- [2/4] Fork footprint ----------------------------------------------------
echo
echo "[2/4] Fork footprint versus the merge base …"
is_fork_owned() {
  local path="$1" owned
  for owned in "${FORK_OWNED[@]}"; do
    case "${owned}" in
      */) [[ "${path}" == "${owned}"* ]] && return 0 ;;
      *)  [[ "${path}" == "${owned}"  ]] && return 0 ;;
    esac
  done
  return 1
}

ADDED_COUNT=0
MODIFIED=()
while IFS=$'\t' read -r status path _rest; do
  [ -n "${path}" ] || continue
  if is_fork_owned "${path}"; then
    ADDED_COUNT=$((ADDED_COUNT + 1))
    continue
  fi
  # An upstream-tracked file the fork touched — this is what conflicts.
  MODIFIED+=("${status}  ${path}")
done < <(git diff --name-status "${MB}" HEAD)

echo "      ${ADDED_COUNT} file(s) in fork-owned paths (always merge-safe)."
if [ "${#MODIFIED[@]}" -eq 0 ]; then
  echo "      0 upstream files modified — the invariant holds."
else
  echo "      ${#MODIFIED[@]} UPSTREAM file(s) modified — each one can conflict on sync:"
  printf '        %s\n' "${MODIFIED[@]}"
  echo
  echo "      Move these changes into sso/patches/ (build-time) or"
  echo "      sso/ci-patches/ (post-sync) and restore the file to pristine:"
  echo "        git diff ${UPSTREAM_REF} HEAD -- <file> > sso/patches/<name>.patch"
  echo "        git checkout ${UPSTREAM_REF} -- <file>"
  RISK=1
fi

# Overlay residue: apply-overlay.sh copies sso/app/ into app/ at build time.
# If a local build left those copies behind and they get committed, the fork
# starts owning upstream-tracked paths again and the merge-safety invariant is
# gone. Catch them while they are still untracked.
RESIDUE=()
if [ -d "sso/app" ]; then
  while IFS= read -r -d '' f; do
    t="${f#sso/}"
    [ -e "${t}" ] && RESIDUE+=("${t}")
  done < <(find sso/app -type f ! -name '.gitkeep' -print0)
fi
if [ "${#RESIDUE[@]}" -gt 0 ]; then
  echo
  echo "      OVERLAY RESIDUE — ${#RESIDUE[@]} overlay file(s) are sitting in the source tree:"
  printf '        %s\n' "${RESIDUE[@]}"
  echo "      These are build artefacts of sso/script/apply-overlay.sh. Delete them;"
  echo "      committing them would break the merge-safety invariant:"
  printf '        rm %s\n' "${RESIDUE[@]}"
  RISK=1
fi

# --- [3/4] Patch drift -------------------------------------------------------
echo
echo "[3/4] Dry-running every patch against the current tree …"
if [ -x "sso/script/verify-patches.sh" ]; then
  if sso/script/verify-patches.sh 2>&1 | sed 's/^/      /'; then
    :
  else
    echo "      One or more patches need regenerating (see above)."
    RISK=1
  fi
else
  echo "      SKIP — sso/script/verify-patches.sh not found or not executable."
fi

# --- [4/4] Upstream contract -------------------------------------------------
echo
echo "[4/4] Checking upstream symbols the overlay compiles against …"
if [ -x "sso/script/check-upstream-contract.sh" ]; then
  if sso/script/check-upstream-contract.sh 2>&1 | sed 's/^/      /'; then
    :
  else
    echo "      Upstream moved something the overlay needs (see above)."
    RISK=1
  fi
else
  echo "      SKIP — sso/script/check-upstream-contract.sh not found or not executable."
fi

# --- Verdict -----------------------------------------------------------------
echo
echo "=========================================="
if [ "${RISK}" -eq 0 ]; then
  echo "VERDICT: SAFE TO SYNC"
  echo "  Sync with:  sso/script/sync-upstream.sh"
else
  echo "VERDICT: RISK DETECTED — read the sections above before syncing."
fi
echo "=========================================="
exit "${RISK}"
