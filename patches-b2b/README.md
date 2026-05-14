# `patches-b2b/` — our additions to Camoufox

Applied on top of upstream `daijro/camoufox` patches (in alphabetical order, after `patches/*.patch`). Naming convention: `<area>-<purpose>.ff<MAJOR>.patch` — the `.ffNN` suffix pins the target Firefox major version. `build.sh` only applies patches matching the upstream's `FF_VERSION` major number, so FF135 builds skip `.ff150.patch` files and vice versa.

Cross-version patches (rare — typically only the small JS layer ones) can be named `<area>-<purpose>.allff.patch` and apply to every build. Use sparingly: most hunks differ at line numbers and surrounding context across FF versions.

## Patch index

| Patch | Targets | Touches | Adds MaskConfig keys | Data trail |
|---|---|---|---|---|
| [`h2-fingerprint-axes.ff135.patch`](./h2-fingerprint-axes.ff135.patch) | Firefox **135.0.1** (matches prod Camoufox `135.0.1-beta.24`) | `Http2Session.cpp`, `Http2Compression.cpp` | `network.http2.settings.enablePush`, `network.http2.settings.maxFrameSize`, `network.http2.priorities.enabled`, `network.http2.pseudoHeaderOrder` | [`project_h2_fingerprint_collapse_2026_05_12.md`](../../../.claude/memory/project_h2_fingerprint_collapse_2026_05_12.md), probe output 2026-05-13 |
| [`h2-fingerprint-axes.ff150.patch`](./h2-fingerprint-axes.ff150.patch) | Firefox **150.0.2** (daijro main, FF135 successor) | same | same | same — ported from FF135 by retargeting hunks against the FF150 SendHello layout (ENABLE_PUSH is unconditional in 150, conditional on `network_http_http2_allow_push` pref in 135) |

### Switching upstream Firefox version

To bump production from FF135 to FF150:
1. Move the FF150 line of `UPSTREAM_VERSION` to `(PROD)` and demote the FF135 line.
2. Run `build.sh` — it auto-checks out the matching daijro tag and applies the `.ff150.patch` variant.
3. SHA256-pin the new artefact in the consumer's `Dockerfile` + `docker/provisioner/Dockerfile`.

Keep both `.ff135.patch` and `.ff150.patch` until the legacy fleet is fully migrated — rollback to the older Camoufox version is a `Dockerfile` revert away.

## `h2-fingerprint-axes.patch` — rationale

The 2026-05-12 audit found that 143/204 post-JA3-fix accounts shared the Akamai fingerprint `1:16384;2:0;4:524288;5:16384|12517377|0|m,p,a,s` — 114 of them already in `verify_challenge`, captcha solver showing `payload_calls=0` (PX denying the bframe at the wire). Cardinality of `akamai_fingerprint` across the cohort was 7/204 = 3.4%.

The HEADER_TABLE_SIZE and INITIAL_WINDOW_SIZE axes are pref-reachable (probe-validated 2026-05-13 — see `scripts/probe_camoufox_h2_prefs.py`). The remaining axes are not:

1. **Field 2 `ENABLE_PUSH`** — `Http2Session::SendHello` hardcodes the value portion to 0 via `memset`. Real Firefox always sends 0, so rotation is a no-op today, but having the MaskConfig surface in place means future PX pivots that score "always 0" as a Firefox flag can be neutralised quickly.
2. **Field 5 `MAX_FRAME_SIZE`** — hardcoded to `kMaxFrameData` (16384). Same Firefox-realism caveat as ENABLE_PUSH.
3. **PRIORITY frame count** — gated on `StaticPrefs::network_http_http2_enabled_deps()` AND `gHttpHandler->CriticalRequestPrioritization()`. The pref-based path is fragile — Mozilla can deprecate or rename either. MaskConfig override gives us a stable per-profile control point.
4. **Pseudo-header order** — `Http2Compression::EncodeHeaderBlock` emits `:method, :path, :authority, :scheme` in fixed call order (lines 1054-1058 of `Http2Compression.cpp` in Firefox 150.0.2). Real Firefox 150 emits this order; older / branched Firefox builds emit `m,a,s,p`. Rotation between Firefox-shipped orders lets the fleet look like a mix of Firefox versions rather than one structural shape.

## Build pipeline

**Phase 1 (current):** local manual build on `cloud-claude` dev VPS via [`scripts/camoufox_fork_build.sh`](../../../scripts/camoufox_fork_build.sh) — checks out matching upstream tag, applies upstream `patches/*.patch` + our `patches-b2b/*.patch`, builds, packages, prints SHA256 for `Dockerfile` pinning. ~30–90 min on a 4-core build.

**Phase 2 (planned):** GitHub Releases artefact, SHA256-pinned `RUN wget && sha256sum -c` in `Dockerfile`. Build runs in a fork repo's CI on tag push. The brief at [`.claude/briefs/camoufox-fork-baseline.md`](../../../.claude/briefs/camoufox-fork-baseline.md) (PR #657 pre-design) covers the fork repo split when patch set grows past 2-3 files.

## Patch authoring convention

- Diff against the **upstream Camoufox-patched tree**, not pristine Firefox. Our patches run *after* `patches/*.patch`. If an upstream patch already added an `#include "MaskConfig.hpp"` to the file we're touching, we don't add it again.
- Touched files in `netwerk/protocol/http/` already have `LOCAL_INCLUDES += ["/camoucfg"]` in `moz.build` (added by upstream `network-patches.patch`), so MaskConfig.hpp is on the include path.
- Match the existing MaskConfig idiom: `if (auto value = MaskConfig::GetUint32("..."); value.has_value()) { ... }`.
- Defaults match the upstream behaviour — every MaskConfig key is an *override*, never a behaviour change for un-configured profiles.
- One cohesive patch per layer (TLS, H/2, JS-surface). Don't fragment the diff across axes within the same layer — keeps the patch hunk small and rebase-friendly when upstream Firefox bumps.
