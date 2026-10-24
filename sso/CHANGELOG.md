# Stirling-PDF-SSO changelog

Fork releases are tagged `v<upstream version>-sso.<n>`: the upstream
Stirling-PDF release the tree is based on, plus the fork's own revision.
Images are published as `ghcr.io/deenyoro/stirling-pdf-sso:<yyyy.mm.dd>-<sha8>`
(also `sha-<sha>` and `latest`).

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
