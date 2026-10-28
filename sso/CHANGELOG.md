# Stirling-PDF-SSO changelog

Fork releases are tagged `v<upstream version>-sso.<n>`: the upstream
Stirling-PDF release the tree is based on, plus the fork's own revision.
Images are published as `ghcr.io/deenyoro/stirling-pdf-sso:<yyyy.mm.dd>-<sha8>`
(also `sha-<sha>` and `latest`).

## v3.2.1-sso.2 — 2026-10-28

- Automatic PDF metadata is no longer switched on at every start. With it on,
  every processed PDF had its Author replaced by the signed-in username (an
  email address with OIDC). It now follows
  `premium.proFeatures.customMetadata.autoUpdateMetadata` in settings.yml,
  which is off by default, so PDFs keep their original Author.
- Audit logging is no longer forced on either. It follows
  `premium.enterpriseFeatures.audit.enabled` in settings.yml, which is on by
  default, so nothing changes unless you turn it off there.
- `sso/deploy/docker-compose.yml` has no default admin password any more:
  `INITIAL_ADMIN_PASSWORD` must be set or compose refuses to start. Added the
  `sso/deploy/.env.example` the README refers to.

## v3.2.1-sso.1 — 2026-10-23

- Synced with upstream Stirling-PDF 3.2.1 (latest stable, 2026-10-21) plus
  upstream `main` up to `04e1ee402`. The merge was clean: no conflicts, every
  required, optional and CI patch still applies, and all 21 upstream symbols the
  overlay depends on are still present.
- Root `Dockerfile` brought back in line with upstream's
  `docker/embedded/Dockerfile`: Stirling-PDF base image 1.0.6 -> 1.1.0, Task
  3.53.1 -> 3.54.0, upstream's handling of the Supabase/SaaS build args, and the
  prototypes build flag dropped (upstream deleted the prototypes frontend).
- `check-sync-safety.sh` now counts `.gitlab-ci.yml` and
  `upstream-auto-sync.yml` as fork-owned files, so it no longer reports a false
  "risk detected" on every sync.
