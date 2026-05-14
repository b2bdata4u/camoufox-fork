#!/usr/bin/env bash
# Build a Camoufox tarball with our fork patches applied on top of upstream.
#
# Usage:
#   build.sh [<upstream-version>] [<build-target>]
#
# Examples:
#   build.sh                              # FF135 from UPSTREAM_VERSION (PROD)
#   build.sh 135.0.1-beta.24 linux-x86_64
#
# Default upstream-version matches the line tagged "(PROD)" in
# UPSTREAM_VERSION. Default build-target is linux-x86_64.
#
# Output: a packaged tarball + SHA256, copy-pasteable into Dockerfile pins.
#
# Time: 30-90 min on a 4-core VPS for the mach build. Bootstrap (first run)
# adds another ~15 min of apt installs from the Mozilla build environment.
#
# Environment overrides:
#   CAMOUFOX_DIR     — daijro/camoufox checkout (default: ./upstream-src or
#                      /root/Coding/camoufox if present)
#   PATCHES_B2B_DIR  — directory of our patches (default: ./patches-b2b)
#   MACH_JOBS        — parallelism (default: 2 — RAM-conservative for 8GB VPS)
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PATCHES_B2B_DIR="${PATCHES_B2B_DIR:-$REPO_ROOT/patches-b2b}"

# Resolve upstream checkout: prefer env, then ./upstream-src (CI), then dev VPS path.
if [ -n "${CAMOUFOX_DIR:-}" ]; then
  :
elif [ -d "$REPO_ROOT/upstream-src" ]; then
  CAMOUFOX_DIR="$REPO_ROOT/upstream-src"
elif [ -d "/root/Coding/camoufox" ]; then
  CAMOUFOX_DIR="/root/Coding/camoufox"
else
  echo "ERROR: no upstream camoufox checkout found." >&2
  echo "Either set CAMOUFOX_DIR, or clone: git clone https://github.com/daijro/camoufox.git ./upstream-src" >&2
  exit 1
fi

UPSTREAM_VERSION="${1:-}"
if [ -z "$UPSTREAM_VERSION" ]; then
  UPSTREAM_VERSION="$(grep '(PROD)' "$REPO_ROOT/UPSTREAM_VERSION" \
                       | sed -E 's/-b2b[0-9]+ \(PROD\)//' \
                       | tr -d ' ')"
fi
# BUILD_TARGET is the user-facing label (used in artefact filename + log).
# Camoufox's scripts/patch.py expects MAKE_BUILD_TARGET in "os,arch" form
# (e.g. "linux,x86_64"); we derive it from BUILD_TARGET below.
BUILD_TARGET="${2:-linux-x86_64}"
MAKE_BUILD_TARGET="${BUILD_TARGET//-/,}"
MACH_JOBS="${MACH_JOBS:-2}"

FF_VERSION="${UPSTREAM_VERSION%%-*}"
RELEASE="${UPSTREAM_VERSION#*-}"

echo "===================================================="
echo " Camoufox b2b fork build"
echo "===================================================="
echo " Upstream version : $UPSTREAM_VERSION  (ff=$FF_VERSION release=$RELEASE)"
echo " Build target     : $BUILD_TARGET"
echo " Camoufox dir     : $CAMOUFOX_DIR"
echo " b2b patches      : $PATCHES_B2B_DIR"
echo " Parallel jobs    : $MACH_JOBS"
echo "===================================================="

cd "$CAMOUFOX_DIR"

# Daijro's main branch tracks the latest Firefox release; targeting an older
# version means we MUST check out the matching tag, otherwise patches/*.patch
# is for the wrong Firefox source and ~25 patches reject. Tag format on daijro
# is `v<upstream-version>` (e.g. v135.0.1-beta.24).
DAIJRO_TAG="v${UPSTREAM_VERSION}"
if git rev-parse --verify --quiet "$DAIJRO_TAG" >/dev/null; then
  current="$(git rev-parse HEAD)"
  target="$(git rev-parse "$DAIJRO_TAG")"
  if [ "$current" != "$target" ]; then
    echo "[build] checking out daijro tag $DAIJRO_TAG ..."
    # Stash any uncommitted change to upstream.sh (we rewrite it next anyway).
    git stash --quiet 2>/dev/null || true
    git checkout --quiet "$DAIJRO_TAG"
  fi
else
  echo "[build] WARNING: daijro tag $DAIJRO_TAG not found in current checkout." >&2
  echo "[build] If this is a shallow clone, run: git fetch --unshallow origin" >&2
  echo "[build] Proceeding with current HEAD — patches may not apply if HEAD targets a different Firefox version." >&2
fi

# Sanity-check rust toolchain — Camoufox's scripts/patch.py calls
# `~/.cargo/bin/rustup target add ...` for cross-compile targets.
# Camoufox does NOT bootstrap rust itself; we have to.
if [ ! -x "$HOME/.cargo/bin/rustup" ]; then
  echo "[build] WARNING: ~/.cargo/bin/rustup missing." >&2
  if command -v rustup >/dev/null; then
    echo "[build] linking $(command -v rustup) into ~/.cargo/bin/" >&2
    mkdir -p "$HOME/.cargo/bin"
    ln -sf "$(command -v rustup)" "$HOME/.cargo/bin/rustup"
    [ -x "$(command -v cargo)" ] && ln -sf "$(command -v cargo)" "$HOME/.cargo/bin/cargo"
    [ -x "$(command -v rustc)" ] && ln -sf "$(command -v rustc)" "$HOME/.cargo/bin/rustc"
  else
    echo "[build] install rust first: apt install rustup && rustup default stable" >&2
    exit 1
  fi
fi
# `make dir` calls patch.py which adds cross-targets; pre-add to avoid the
# build needing network mid-compile.
if rustup show 2>&1 | grep -q "no default toolchain"; then
  echo "[build] no default rust toolchain — setting stable" >&2
  rustup default stable
fi
rustup target add aarch64-unknown-linux-gnu i686-unknown-linux-gnu 2>&1 | tail -3 || true

# Sync Camoufox's version pin to what we asked for. The tag checkout above
# also wrote this file, but we may be on a non-tag commit so be explicit.
cat > upstream.sh <<EOF
version=$FF_VERSION
release=$RELEASE
closedsrc_rev=1.0.0
EOF

# 1. Fetch source if missing.
TARBALL="firefox-${FF_VERSION}.source.tar.xz"
if [ ! -f "$TARBALL" ]; then
  echo "[build] fetching $TARBALL ..."
  wget -q "https://archive.mozilla.org/pub/firefox/releases/${FF_VERSION}/source/${TARBALL}" -O "$TARBALL"
fi

# 2. Reset the build dir + apply upstream patches via Camoufox's `make dir`.
CF_SOURCE_DIR="camoufox-${FF_VERSION}-${RELEASE}"
if [ -d "$CF_SOURCE_DIR" ]; then
  echo "[build] removing previous $CF_SOURCE_DIR"
  rm -rf "$CF_SOURCE_DIR"
fi

# `make dir` runs `make setup` (extract + git-init) then
# `python3 scripts/patch.py $version $release` (apply all upstream patches).
echo "[build] make dir (extract + apply upstream patches/*.patch) ..."
make dir BUILD_TARGET="$MAKE_BUILD_TARGET"

# Mozilla bootstrap — installs apt build deps + downloads the prebuilt clang
# toolchain into ~/.mozbuild. Without this, `mach build` fails at
# `mach artifact toolchain --from-build toolchain-linux64-clang` because the
# source tree is a git init (not a mozilla-central clone) and mach can't
# resolve the right toolchain artefact from taskcluster.
# Skip if ~/.mozbuild/clang exists (bootstrap already ran on a prior build).
if [ ! -d "$HOME/.mozbuild/clang" ]; then
  echo "[build] mozbootstrap (one-time apt + toolchain download, ~15-30 min) ..."
  if [ ! -f /tmp/bootstrap.py ] || [ $(($(date +%s) - $(stat -c %Y /tmp/bootstrap.py 2>/dev/null || echo 0))) -gt 86400 ]; then
    wget -q https://hg.mozilla.org/mozilla-central/raw-file/default/python/mozboot/bin/bootstrap.py -O /tmp/bootstrap.py
  fi
  python3 /tmp/bootstrap.py --no-interactive --application-choice=browser
else
  echo "[build] ~/.mozbuild/clang exists — skipping mozbootstrap"
fi

# 3. Apply patches-b2b on top.
echo "[build] applying patches-b2b/*.patch ..."
for p in "$PATCHES_B2B_DIR"/*.patch; do
  echo "[build]   $p"
  (cd "$CF_SOURCE_DIR" && patch -p1 --silent < "$p") \
    || { echo "FAILED b2b: $p"; exit 1; }
done

# Prepend the bootstrapped clang dir to PATH. mach build with
# --disable-bootstrap won't auto-find llvm-objdump / llvm-readelf / etc
# in ~/.mozbuild/clang/bin — it expects them on PATH.
if [ -d "$HOME/.mozbuild/clang/bin" ]; then
  export PATH="$HOME/.mozbuild/clang/bin:$PATH"
fi

# Disable `--enable-bootstrap` in mozconfig. Camoufox's default mozconfig
# enables it; mach then tries to fetch the prebuilt clang toolchain from
# taskcluster, which fails because our source tree is a git-init (not a
# mozilla-central clone) so mach can't resolve which artefact to fetch.
# We installed clang locally via mozbootstrap above, so we don't need the
# auto-bootstrap path. Flip it to --disable-bootstrap.
if grep -q "^ac_add_options --enable-bootstrap" "$CF_SOURCE_DIR/mozconfig"; then
  sed -i 's/^ac_add_options --enable-bootstrap$/ac_add_options --disable-bootstrap/' \
    "$CF_SOURCE_DIR/mozconfig"
  echo "[build] flipped mozconfig --enable-bootstrap → --disable-bootstrap"
fi

# 4. Build via Camoufox's `make build` (calls `./mach build` internally).
echo "[build] make build  (30-90 min) ..."
MACH_ARGS=""
if [ "$MACH_JOBS" != "auto" ] && [ -n "$MACH_JOBS" ]; then
  MACH_ARGS="-j$MACH_JOBS"
fi
make build _ARGS="$MACH_ARGS" 2>&1 | tee /tmp/camoufox-build.log | tail -50

# 5. Package via Camoufox's `make package-linux`.
echo "[build] make package-linux ..."
make package-linux 2>&1 | tee -a /tmp/camoufox-build.log | tail -20

# 6. Find packaged tarball, rename with our convention, checksum.
ARTEFACT="$(ls "$CF_SOURCE_DIR"/*.tar.bz2 2>/dev/null | head -1)"
if [ -z "$ARTEFACT" ]; then
  ARTEFACT="$(find "$CF_SOURCE_DIR" -maxdepth 2 -name '*.tar.bz2' | head -1)"
fi
if [ -z "$ARTEFACT" ] || [ ! -f "$ARTEFACT" ]; then
  echo "ERROR: no .tar.bz2 produced. Inspect /tmp/camoufox-build.log" >&2
  exit 2
fi

OUTPUT_NAME="camoufox-${FF_VERSION}-${RELEASE}-b2b.${BUILD_TARGET//x86_64/x86_64}.tar.bz2"
OUTPUT_PATH="$CAMOUFOX_DIR/$OUTPUT_NAME"
cp "$ARTEFACT" "$OUTPUT_PATH"
SHA256="$(sha256sum "$OUTPUT_PATH" | awk '{print $1}')"

echo "===================================================="
echo " BUILD COMPLETE"
echo "===================================================="
echo " Artefact : $OUTPUT_PATH"
echo " SHA256   : $SHA256"
echo "===================================================="
echo
echo " Next steps:"
echo "   1. Upload to a GitHub release on b2bdata4u/camoufox-fork"
echo "   2. In consumer Dockerfile + docker/provisioner/Dockerfile bump:"
echo "        ARG CAMOUFOX_VERSION=${FF_VERSION}-${RELEASE}-b2b1"
echo "        ARG CAMOUFOX_SHA256=$SHA256"
echo "   3. Smoke: probe_camoufox_h2_fork_axes.py — both probes PASS."
