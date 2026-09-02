# SSO Overlay

Custom overlay that unlocks **SSO and all premium/enterprise features** of
Stirling-PDF **without a paid license key** — applied at Docker build time, with
the upstream source tree kept pristine so the fork syncs cleanly.

Modelled on the `kc/` overlay pattern from `zammad-kc`.

---

## Why an overlay?

Stirling-PDF gates SAML2 SSO, audit logging, persistent metrics and other
features behind a paid license that is validated against `api.keygen.sh`. This
overlay removes that gate. Keeping the change as an **overlay + patches** instead
of editing files in place means:

- `git merge upstream/main` (or GitHub's **Sync fork**) produces **zero
  conflicts** in application code.
- The only files that can ever conflict are the handful named in
  `sso/patches/` — and if upstream changes one, the Docker build **fails loudly**
  telling you to regenerate that patch.
- Every customization is isolated in `sso/`, easy to audit and to remove.

---

## How the build works

The root `Dockerfile` runs two scripts after `COPY . .` and before the Gradle
build:

| Step | Script | Mechanism | Used for |
|---|---|---|---|
| 1 | `sso/script/apply-overlay.sh` | `rsync --ignore-existing` | **New** files (never overwrites upstream) |
| 2 | `sso/script/apply-patches.sh` | `patch -p1` (unified diffs) | **Modifications** to existing upstream files |

`apply-patches.sh` is deliberately drift-tolerant so an upstream sync rarely
breaks the build:

- **Required** patches (`patches/*.patch`) are load-bearing for the unlock. Each
  is a *minimal insertion* anchored on a stable line rather than a large block
  replacement, so upstream edits nearby don't disturb it. They apply exactly,
  then fall back to fuzz + whitespace tolerance. Only a genuine edit to the exact
  lines a patch touches makes the build fail — and then it fails loudly, because
  shipping an image that is silently *not* unlocked is worse than a red build.
- **Optional** patches (`patches/optional/*.patch`) are best-effort. They are not
  compiled into the runtime image (e.g. test sources — Gradle runs with `-x test`),
  so if they drift the build **warns and continues** instead of failing.
- The step is idempotent (a rebuilt layer detects already-applied patches and
  skips them).

The image is then built with `STIRLING_FLAVOR=proprietary`, which compiles the
Enterprise/SSO module. At runtime Stirling auto-activates the `security` Spring
profile because `SecurityConfiguration` is on the classpath
(`SPDFApplication#getActiveProfile`), and `PremiumFeatureUnlock` flips the
premium switch + safe features on at boot.

---

## Directory structure

```
sso/
├── README.md                       # this file
├── app/                            # NEW files, overlaid via rsync --ignore-existing
│   └── proprietary/src/{main,test}/java/.../ee/
│       ├── PremiumFeatureUnlock.java       # @PostConstruct: enables premium + safe features
│       └── PremiumFeatureUnlockTest.java
├── patches/                        # diffs applied to EXISTING upstream files (Docker build time)
│   ├── 0001-keygenlicenseverifier-enterprise-bypass.patch   # REQUIRED: verifyLicense() -> ENTERPRISE, no keygen.sh call
│   ├── 0002-licensekeychecker-grant-enterprise.patch        # REQUIRED: no key -> ENTERPRISE; @DependsOn ordering
│   └── optional/                                            # best-effort: not in the runtime image, never fails the build
│       └── 0003-licensekeycheckertest-expectations.patch    # test sources updated to the new behaviour
├── ci-patches/                     # diffs applied to .github/workflows/ (applied LOCALLY, not in Docker)
│   ├── 0001-runner-pick-force-fork-on-non-upstream.patch    # _runner-pick.yml: force is_fork=true on the fork
│   ├── 0002-push-docker-skip-on-fork.patch                  # push-docker.yml: skip on non-upstream repos
│   ├── 0004-swagger-skip-on-fork.patch                      # swagger.yml: skip on non-upstream repos
│   ├── 0005-sync-files-v2-skip-on-fork.patch                # sync_files_v2.yml: skip on non-upstream repos
│   ├── 0007-build-enterprise-skip-on-fork.patch             # build-enterprise.yml: skip on non-upstream repos
│   ├── 0008-license-report-skip-on-fork.patch               # frontend-backend-licenses-update.yml: skip on non-upstream repos
│   └── 0009-nightly-e2e-skip-on-fork.patch                  # nightly.yml: skip Playwright + Tauri cache on non-upstream repos
├── script/
│   ├── apply-overlay.sh            # Docker-build time: rsync new files into the tree
│   ├── apply-patches.sh            # Docker-build time: apply patches/ to upstream files (tolerant, tiered)
│   ├── apply-ci-patches.sh         # LOCAL, after-upstream-sync: re-apply ci-patches/ to .github/workflows/
│   ├── verify-patches.sh           # LOCAL/CI: dry-run all patches; reports what needs regenerating
│   ├── check-upstream-contract.sh  # LOCAL/CI: do the upstream symbols the overlay compiles against still exist?
│   ├── check-sync-safety.sh        # LOCAL/CI: will the next sync conflict? (merge simulation + footprint)
│   └── sync-upstream.sh            # LOCAL: one command — stamp recovery ref, merge, re-apply CI, verify
├── upstream-contract.tsv           # upstream symbols sso/app/ depends on (checked by check-upstream-contract.sh)
└── deploy/
    ├── docker-compose.yml          # ready-to-run stack with login enabled
    └── .env.example
```

## What gets unlocked

- **OAuth2 / OIDC SSO** (was already free) and **SAML2 SSO** (was paywalled).
- **License tier** reported as `ENTERPRISE` (`runningProOrHigher` / `runningEE` true).
- Self-contained features turned on automatically: audit logging, persistent
  metrics, automatic PDF metadata, DB backup/import notifications.

Toggles that need extra configuration are left **off** so a fresh deploy boots
cleanly — enable them in settings once configured:
`proFeatures.googleDrive` (API keys), `proFeatures.database` (external DB),
`proFeatures.ssoAutoLogin` (redirects past the login page).

All of these defaults are enforced at **runtime** by `PremiumFeatureUnlock`
(`@PostConstruct`), so there is intentionally **no patch to `settings.yml.template`**.
That template is one of the most frequently-edited upstream files; patching it
was pure churn (the runtime bean already wins) and was the main thing that used
to break the build on a sync. It is now left pristine.

---

## Syncing upstream

### The invariant

**The fork never modifies an upstream-tracked file.** Its entire footprint is
files upstream does not have:

```
sso/                                    all custom code, patches and tooling
Dockerfile                              fork-only (upstream ships docker/*)
.github/workflows/sso-docker-build.yml  fork-only
```

A merge conflict requires both sides to have changed the same lines of the same
file. Since the fork shares **zero lines** with upstream, `git merge
upstream/main` is structurally incapable of conflicting. Changes that must touch
upstream files live as unified diffs and are applied *after* the merge
(`ci-patches/`) or *inside the Docker build* (`patches/`).

If you ever need to edit an upstream file, don't. Turn it into a patch:

```bash
git diff upstream/main HEAD -- <file> > sso/patches/<name>.patch
git checkout upstream/main -- <file>          # restore it to pristine
```

`check-sync-safety.sh` fails if this invariant is ever broken.

### Doing the sync

```bash
git remote add upstream https://github.com/Stirling-Tools/Stirling-PDF.git   # once
./sso/script/check-sync-safety.sh --fetch   # optional: predict the merge first
./sso/script/sync-upstream.sh               # do it
git push                                    # rebuilds & pushes the image to GHCR
```

`sync-upstream.sh`:
1. fetches `upstream/main`,
2. **stamps a recovery ref** at the current HEAD (`refs/sso-presync/<timestamp>`),
3. runs the sync-safety pre-flight,
4. merges `upstream/main` (stops on conflict with instructions),
5. re-applies the fork CI overrides to `.github/workflows/` (`apply-ci-patches.sh`),
6. dry-runs every source + CI patch (`verify-patches.sh`),
7. checks the upstream contract (`check-upstream-contract.sh`).

Use `--check` to fetch and verify **without** merging.

### NEVER do this

> **Do not `git reset --hard upstream/main`, and do not accept GitHub's "Sync
> fork" offer to _discard commits_.** Both delete every fork commit — the whole
> `sso/` overlay with them. This has already happened to this repo once: the
> remote was reset to pure upstream and the overlay had to be rebuilt from a
> local clone.
>
> If a sync goes wrong, the recovery ref stamped in step 2 is the way back:
>
> ```bash
> git for-each-ref refs/sso-presync/        # list recovery points
> git reset --hard refs/sso-presync/<timestamp>
> ```
>
> And if the remote is ever ahead of a healthy local clone, **push the local
> clone** — never pull the damage down.

### The four checks, and what each one catches

| Check | Catches | Blind to |
|---|---|---|
| `check-sync-safety.sh` `[1]` merge simulation | real merge conflicts | anything that merges cleanly but breaks |
| `check-sync-safety.sh` `[2]` footprint + residue | the invariant being broken; overlay copies left in `app/` | file content |
| `verify-patches.sh` | patches that no longer apply | patches that apply to *moved* code |
| `check-upstream-contract.sh` | upstream renaming/moving a symbol `sso/app/` compiles against | anything not listed in `upstream-contract.tsv` |

The last one exists because a sync can be conflict-free **and** patch-clean
while the build is still broken — upstream renames a class the overlay imports
and nothing diff-based notices. Add a row to `sso/upstream-contract.tsv`
whenever the overlay starts depending on a new upstream symbol.

### If a patch no longer applies

`verify-patches.sh` (and the Docker build, for required patches) name the exact
file. Regenerate against a fresh upstream diff:

```bash
git diff upstream/main HEAD -- <target-file> > <patch-path>
# source patch:   sso/patches/<name>.patch  (or sso/patches/optional/<name>.patch)
# CI patch:       sso/ci-patches/<name>.patch
```

If the target file was **deleted** upstream, the patch is obsolete rather than
broken — both the apply and verify scripts report it as such and keep going.
Delete it at your convenience: `git rm sso/ci-patches/<name>.patch`.

Only **required** source patches and **CI** patches are build-gating. Optional
patches (test sources) drift without breaking anything. The number of
build-gating source patches is kept deliberately small (two minimal insertions
into the licensing code) precisely so a sync almost never breaks.

---

## Local build & run

```bash
docker build -t stirling-pdf-sso .
docker run -p 8080:8080 -e SECURITY_ENABLELOGIN=true stirling-pdf-sso
# or the full stack:
cp sso/deploy/.env.example sso/deploy/.env   # edit values
docker compose --env-file sso/deploy/.env -f sso/deploy/docker-compose.yml up -d
```

> Note: this overlay only removes the license gate. SSO still requires you to
> configure your IdP (OAuth2/OIDC env vars, or `security.saml2.*` in
> `settings.yml`) and to enable login (`SECURITY_ENABLELOGIN=true`).
