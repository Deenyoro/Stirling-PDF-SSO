# Stirling-PDF-SSO changelog

Fork releases are tagged `v<upstream version>-sso.<n>`: the upstream
Stirling-PDF release the tree is based on, plus the fork's own revision.
Images are published as `gitlabreg.kawa.link/dean/stirling-pdf-sso:<yyyy.mm.dd>-<sha8>`
(also `sha-<sha>` and `latest`).

## v3.5.0-sso.1 (2026-11-24)

- Synced with upstream `main` up to `a8053654b` (upstream version 3.5.0):
  37 new upstream commits. Among them: LibreOffice, Calibre, WeasyPrint and
  OpenCV replaced by the built-in Stirling Office Convert (the old
  `system.customPaths`/`processExecutor` LibreOffice settings are now unused),
  editing text inside the viewer, accessibility tagging fixes, macOS keychain
  and OS trust store signing (`useOSTrust`, off by default), and an
  off-by-default Server license user-count reporter.
- Root `Dockerfile`: added upstream's new `-XX:-UseBASE64Intrinsics` JVM flag,
  so it again differs from upstream's embedded Dockerfile only by the SSO
  additions. Base image unchanged (1.1.1).
- No overlay change was needed: all SSO patches apply exactly, CI patches
  apply, upstream contract 21/21, sync safety SAFE. Upstream's `DatabaseConfig`
  change only adds the `serverregistration` package to the JPA scan.

## v3.3.0-sso.2 — 2026-11-17

- Synced with upstream `main` up to `c718a3707` (still upstream version 3.3.0):
  31 new upstream commits. Among them: SCIM 2.0 user provisioning (off until
  `security.scimToken` is set), an option to block changes to digitally signed
  PDFs (`security.blockSignedPdfEdits`, off by default), server-provided fonts
  and font-embedding fixes in the PDF text editor, custom page size in Scale
  Pages, page numbers on rotated and cropped pages, and omitted PDF metadata
  now preserved in background jobs.
- Upstream removed the PostScript vector conversion endpoints
  (`/convert/vector/pdf`, `/convert/pdf/vector`: PS/EPS/PCL/XPS).
- Upstream changed the default of `storage.sharing.enabled` to `true`. An
  existing `settings.yml` keeps its own value, and sharing still needs
  `storage.enabled`.
- No overlay change was needed: all SSO patches apply exactly, CI patches
  apply, upstream contract 21/21, sync safety SAFE, and the root `Dockerfile`
  still differs from upstream's embedded Dockerfile only by the SSO additions.

## v3.3.0-sso.1 — 2026-11-14

- Based on upstream Stirling-PDF 3.3.0 (`main` up to `ad38e38ce`), including
  the 2026-11-06 and 2026-11-11 syncs that were not tagged, and the fork
  Dockerfile now tracking upstream's embedded Dockerfile.
- 19 new upstream commits: accessibility checking and tagging, PDF text
  editor fixes, connected OneDrive/SharePoint/Google Drive accounts for
  pipelines, bundled-only public fonts route.
- All SSO patches apply exactly, CI patches apply, upstream contract 21/21,
  sync safety SAFE.

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
