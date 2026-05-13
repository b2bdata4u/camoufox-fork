# camoufox-fork

Thin patch overlay on top of [daijro/camoufox](https://github.com/daijro/camoufox). Our additions live in [`patches-b2b/`](./patches-b2b/) — they get applied *after* upstream's `patches/*.patch` at build time. The full daijro source is never vendored here; it's fetched at the version pinned in [`UPSTREAM_VERSION`](./UPSTREAM_VERSION) when [`build.sh`](./build.sh) or the CI workflow runs.

## Why this fork exists

LinkedIn / PerimeterX scores HTTP/2 fingerprint axes that stock Camoufox doesn't expose to per-profile rotation:

- Pseudo-header emit order (`m,p,a,s` vs `m,a,s,p` etc.) — emitted by `Http2Compression::EncodeHeaderBlock` in source order
- PRIORITY frame count (0 vs 6) — gated on Firefox prefs that aren't safely per-session toggleable
- `ENABLE_PUSH` and `MAX_FRAME_SIZE` SETTINGS values — hardcoded in `Http2Session::SendHello`

The 2026-05-12 fleet audit found 143 of 204 post-JA3-fix accounts sharing one Akamai HTTP/2 fingerprint — PX learned the shape and silently scored every account as scraping before the captcha solver could even run. Stock Camoufox prefs can rotate the wire SETTINGS field 1 + 4, but the four axes above require a C++ patch.

Background: [`.claude/memory/project_h2_fingerprint_collapse_2026_05_12.md`](https://github.com/b2bdata4u/content_scraper_linkedin/blob/develop/.claude/memory/project_h2_fingerprint_collapse_2026_05_12.md) in the consumer repo.

## Repo layout

```
patches-b2b/
  h2-fingerprint-axes.patch    # The patch — adds MaskConfig::Get… reads at 4 axes
  README.md                    # Patch-by-patch rationale + maintenance notes
UPSTREAM_VERSION               # Pinned daijro/camoufox version (PROD + NEXT)
build.sh                       # Build script — fetch upstream → apply patches → mach build → package
.github/workflows/
  validate.yml                 # Every push: confirm patches still apply to pinned upstream
  build.yml                    # On tag release/v…-b2b…: full build + GitHub Releases upload
```

## Consumer

[`b2bdata4u/content_scraper_linkedin`](https://github.com/b2bdata4u/content_scraper_linkedin) pulls the built artefact via SHA256-pinned `RUN wget && sha256sum -c` in `Dockerfile` and `docker/provisioner/Dockerfile`. Python integration (`_apply_akamai_h2_axes_to_maskconfig` in `app/infrastructure/browser/camoufox_manager.py`) sets the MaskConfig keys per profile.

## Building

### Local
```sh
./build.sh                                 # uses (PROD) version from UPSTREAM_VERSION
./build.sh 135.0.1-beta.24 linux-x86_64    # explicit
```

Time: ~30–90 min once `make bootstrap` deps are installed. RAM: ≥8GB recommended; ≥16GB swap for 4-core builds. Disk: ~25 GB free.

### CI
Push a tag `release/v<upstream-version>-b2b<n>` (e.g. `release/v135.0.1-beta.24-b2b1`) and the build workflow runs, packages, and uploads `camoufox-…-b2b.linux.x86_64.tar.bz2` to a GitHub Release with the SHA256 in the release notes.

## Tracking upstream

`upstream` remote points at `https://github.com/daijro/camoufox`. To pull a new upstream version:

```sh
git fetch upstream
# Decide which upstream tag to retarget — typically the new daijro release.
# Then update UPSTREAM_VERSION (NEXT line) and retarget the patch hunks
# against the new upstream source. The patch is intentionally small (≈100
# lines, two files) so this re-port is usually <30 min of work.
```

The validate.yml workflow flags incompatibility immediately if our patches stop applying to a new pinned upstream commit.

## Versioning

Tags follow `release/v<upstream-version>-b2b<n>`:

- `release/v135.0.1-beta.24-b2b1` — first build against upstream 135.0.1-beta.24
- `release/v135.0.1-beta.24-b2b2` — same upstream, second iteration of our patch
- `release/v150.0.2-beta.25-b2b1` — when we re-port to upstream 150.0.2

The `b2b<n>` suffix increments for every patch-set revision against the same upstream version.
