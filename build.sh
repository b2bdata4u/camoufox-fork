#!/usr/bin/env bash
# Build a Camoufox tarball with our fork patches applied on top of upstream.
#
# Usage:
#   scripts/camoufox_fork_build.sh [<upstream-version>] [<build-target>]
#
# Examples:
#   scripts/camoufox_fork_build.sh                              # FF135 / linux-x86_64
#   scripts/camoufox_fork_build.sh 135.0.1-beta.24 linux-x86_64
#
# Default upstream-version matches the line tagged "(PROD)" in
# vendor/camoufox/UPSTREAM_VERSION. Default build-target is linux-x86_64.
#
# Output: a packaged tarball + SHA256, copy-pasteable into Dockerfile pins.
#
# Time: 30-90 min on a 4-core VPS. Bootstrap (first run) adds another ~15 min
# of apt installs from the Mozilla build environment.
#
# Prerequisites:
#   - The daijro/camoufox checkout at $CAMOUFOX_DIR (default /root/Coding/camoufox)
#   - aria2c, python3, msitools, golang-go on PATH (installed by `make bootstrap`)
#   - 25+ GB free disk
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CAMOUFOX_DIR="${CAMOUFOX_DIR:-/root/Coding/camoufox}"
PATCHES_B2B_DIR="$REPO_ROOT/vendor/camoufox/patches-b2b"

UPSTREAM_VERSION="${1:-}"
if [ -z "$UPSTREAM_VERSION" ]; then
  # Read the (PROD) line from UPSTREAM_VERSION — strip the "-b2bN (PROD)" suffix.
  UPSTREAM_VERSION="$(grep '(PROD)' "$REPO_ROOT/vendor/camoufox/UPSTREAM_VERSION" \
                       | sed -E 's/-b2b[0-9]+ \(PROD\)//')"
fi
BUILD_TARGET="${2:-linux-x86_64}"

if [ ! -d "$CAMOUFOX_DIR" ]; then
  echo "ERROR: CAMOUFOX_DIR=$CAMOUFOX_DIR does not exist." >&2
  echo "Clone first: git clone https://github.com/daijro/camoufox.git $CAMOUFOX_DIR" >&2
  exit 1
fi

if [ ! -d "$PATCHES_B2B_DIR" ] || [ -z "$(ls -A "$PATCHES_B2B_DIR"/*.patch 2>/dev/null)" ]; then
  echo "ERROR: no .patch files in $PATCHES_B2B_DIR" >&2
  exit 1
fi

# Parse upstream version → "version" + "release" components used by Camoufox's Makefile.
# Format: <ff-version>-<release>  e.g. 135.0.1-beta.24
FF_VERSION="${UPSTREAM_VERSION%%-*}"
RELEASE="${UPSTREAM_VERSION#*-}"

echo "===================================================="
echo " Camoufox fork build"
echo "===================================================="
echo " Upstream version : $UPSTREAM_VERSION  (ff=$FF_VERSION release=$RELEASE)"
echo " Build target     : $BUILD_TARGET"
echo " Source dir       : $CAMOUFOX_DIR"
echo " b2b patches      : $PATCHES_B2B_DIR"
echo "===================================================="

cd "$CAMOUFOX_DIR"

# Confirm the upstream checkout matches the requested version. Camoufox's
# Makefile reads `version` + `release` from upstream.sh; sync those to the
# requested values so `make` does the right thing.
echo "version=$FF_VERSION" > upstream.sh
echo "release=$RELEASE"   >> upstream.sh
echo "closedsrc_rev=1.0.0" >> upstream.sh

# 1. Ensure the Firefox source tarball is present.
TARBALL="firefox-${FF_VERSION}.source.tar.xz"
if [ ! -f "$TARBALL" ]; then
  echo "[build] fetching $TARBALL ..."
  wget -q "https://archive.mozilla.org/pub/firefox/releases/${FF_VERSION}/source/${TARBALL}" -O "$TARBALL"
fi

# 2. Make a fresh build dir.
BUILD_DIR="camoufox-${FF_VERSION}-${RELEASE}"
if [ -d "$BUILD_DIR" ]; then
  echo "[build] cleaning previous $BUILD_DIR"
  rm -rf "$BUILD_DIR"
fi
mkdir -p "$BUILD_DIR"
echo "[build] extracting source ..."
tar -xJf "$TARBALL" -C "$BUILD_DIR" --strip-components=1

# 3. Apply upstream patches.
echo "[build] applying upstream patches/*.patch ..."
for p in patches/*.patch; do
  (cd "$BUILD_DIR" && patch -p1 --silent < "../$p") \
    || { echo "FAILED: $p"; exit 1; }
done

# 4. Copy in /camoucfg additions (header path used by `LOCAL_INCLUDES`).
echo "[build] copying additions/camoucfg/ ..."
cp -r additions/camoucfg "$BUILD_DIR/camoucfg"

# 5. Apply our patches-b2b on top.
echo "[build] applying patches-b2b/*.patch ..."
for p in "$PATCHES_B2B_DIR"/*.patch; do
  (cd "$BUILD_DIR" && patch -p1 --silent < "$p") \
    || { echo "FAILED b2b: $p"; exit 1; }
done

# 6. Build.
echo "[build] starting compile (30-90 min) ..."
cd "$BUILD_DIR"
./mach build 2>&1 | tee /tmp/camoufox-build.log | tail -30

# 7. Package.
echo "[build] packaging ..."
./mach package
ARTEFACT="$(find obj-* -name 'firefox-*.tar.bz2' -o -name 'firefox-*.tar.xz' | head -1)"
if [ -z "$ARTEFACT" ]; then
  echo "ERROR: no artefact produced. See /tmp/camoufox-build.log" >&2
  exit 2
fi

# 8. Rename to our convention + checksum.
OUTPUT_NAME="camoufox-${FF_VERSION}-${RELEASE}-b2b.${BUILD_TARGET//x86_64/x86_64}.tar.bz2"
cp "$ARTEFACT" "$CAMOUFOX_DIR/$OUTPUT_NAME"
cd "$CAMOUFOX_DIR"
SHA256="$(sha256sum "$OUTPUT_NAME" | awk '{print $1}')"

echo "===================================================="
echo " BUILD COMPLETE"
echo "===================================================="
echo " Artefact : $CAMOUFOX_DIR/$OUTPUT_NAME"
echo " SHA256   : $SHA256"
echo "===================================================="
echo
echo " Next steps:"
echo "   1. Upload \$OUTPUT_NAME to a release host (GitHub release on a fork repo)"
echo "   2. Bump these vars in Dockerfile + docker/provisioner/Dockerfile:"
echo "        CAMOUFOX_VERSION=${FF_VERSION}-${RELEASE}-b2b1"
echo "        CAMOUFOX_SHA256=$SHA256"
echo "   3. Update the URL in the Dockerfile RUN line to point at the new host"
echo "   4. Smoke-test via scripts/probe_camoufox_h2_prefs.py — confirm new"
echo "      MaskConfig axes (priorities_enabled, pseudo_header_order) move on"
echo "      the wire"
