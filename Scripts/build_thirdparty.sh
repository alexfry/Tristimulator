#!/bin/bash
#
# build_thirdparty.sh
#
# Builds OpenColorIO / OpenImageIO / OpenEXR / Imath and their image-format
# transitive deps from source via vcpkg, statically, for arm64 macOS.
# Idempotent: re-running with an unchanged manifest is a no-op cache hit.
#
# Invoked by:
#   - Xcode "Run Script" build phase (first phase of the Tristimulator target)
#   - CI workflows
#   - Developers manually after touching vcpkg.json / Triplets/*.cmake
#
# Environment:
#   THIRDPARTY_ROOT  (optional) location of vcpkg clone + install prefix
#                    default: $HOME/Library/Caches/Tristimulator/ThirdParty
#   SRCROOT          (optional) repo root. Default: directory containing this script's parent
#   VCPKG_BASELINE   (optional) vcpkg commit SHA to check out. If empty, falls
#                    back to the baseline in vcpkg.json. If that's also empty,
#                    uses origin/master and prints a warning.

set -euo pipefail

# -----------------------------------------------------------------------------
# Toolchain
#
# Recent Command Line Tools installs ship without the libc++ stdlib headers
# (e.g. <cstdint>, <iostream>) — only Xcode does. Force xcrun + CMake to use
# Xcode's developer dir + clang so we get a complete toolchain.
# -----------------------------------------------------------------------------

if [ -d /Applications/Xcode.app/Contents/Developer ]; then
    export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
fi
if command -v xcrun >/dev/null 2>&1; then
    export SDKROOT="${SDKROOT:-$(xcrun --show-sdk-path)}"
    export CC="${CC:-$(xcrun --find clang)}"
    export CXX="${CXX:-$(xcrun --find clang++)}"
fi
export MACOSX_DEPLOYMENT_TARGET="${MACOSX_DEPLOYMENT_TARGET:-15.0}"

# vcpkg's .pc-fixup step needs pkg-config on PATH. If Homebrew already provides
# it we use that (saves the cost of a separate build); otherwise we fall back
# to vcpkg's own pkgconf port further down, after bootstrapping vcpkg itself.
case ":$PATH:" in
    *":/opt/homebrew/bin:"*) ;;
    *) [ -x /opt/homebrew/bin/pkg-config ] && export PATH="/opt/homebrew/bin:$PATH" ;;
esac
case ":$PATH:" in
    *":/usr/local/bin:"*) ;;
    *) [ -x /usr/local/bin/pkg-config ] && export PATH="/usr/local/bin:$PATH" ;;
esac

# -----------------------------------------------------------------------------
# Paths
# -----------------------------------------------------------------------------

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${SRCROOT:-$(cd "$SCRIPT_DIR/.." && pwd)}"
THIRDPARTY_ROOT="${THIRDPARTY_ROOT:-$HOME/Library/Caches/Tristimulator/ThirdParty}"

VCPKG_DIR="$THIRDPARTY_ROOT/vcpkg"
INSTALL_ROOT="$THIRDPARTY_ROOT/installed"
TRIPLET="arm64-osx-tristimulator"
INSTALL_PREFIX="$INSTALL_ROOT/$TRIPLET"

MANIFEST="$REPO_ROOT/vcpkg.json"
CONFIGURATION="$REPO_ROOT/vcpkg-configuration.json"
TRIPLETS_DIR="$REPO_ROOT/Triplets"
GENERATED_DIR="$REPO_ROOT/Generated"
GENERATED_XCCONFIG="$GENERATED_DIR/ThirdParty.generated.xcconfig"
HASH_FILE="$INSTALL_ROOT/.tristimulator-hash"

log() { printf '[build_thirdparty] %s\n' "$*" >&2; }
die() { log "ERROR: $*"; exit 1; }

[ -f "$MANIFEST" ] || die "Missing vcpkg.json at $MANIFEST"
[ -f "$CONFIGURATION" ] || die "Missing vcpkg-configuration.json at $CONFIGURATION"
[ -d "$TRIPLETS_DIR" ] || die "Missing Triplets/ at $TRIPLETS_DIR"

# -----------------------------------------------------------------------------
# Hash the manifest inputs. If the hash matches what we built last time, skip.
# -----------------------------------------------------------------------------

MANIFEST_HASH=$(
    {
        cat "$MANIFEST"
        cat "$CONFIGURATION"
        find "$TRIPLETS_DIR" -type f -name '*.cmake' -print0 | sort -z | xargs -0 cat
    } | shasum -a 256 | awk '{print $1}'
)

if [ -f "$HASH_FILE" ] && [ -f "$GENERATED_XCCONFIG" ]; then
    STORED_HASH=$(cat "$HASH_FILE" 2>/dev/null || true)
    if [ "$STORED_HASH" = "$MANIFEST_HASH" ]; then
        log "cache hit ($MANIFEST_HASH) — nothing to do"
        exit 0
    fi
fi

log "manifest hash $MANIFEST_HASH — rebuilding third-party libs"

# -----------------------------------------------------------------------------
# Bootstrap or update vcpkg
# -----------------------------------------------------------------------------

mkdir -p "$THIRDPARTY_ROOT"

if [ ! -d "$VCPKG_DIR/.git" ]; then
    log "cloning vcpkg into $VCPKG_DIR"
    git clone --filter=blob:none https://github.com/microsoft/vcpkg "$VCPKG_DIR"
fi

# Determine which commit to check out.
BASELINE_FROM_MANIFEST=$(
    /usr/bin/python3 -c '
import json, sys
try:
    with open(sys.argv[1]) as f:
        m = json.load(f)
    print(m.get("builtin-baseline", "") or "")
except Exception:
    pass
' "$MANIFEST"
)

VCPKG_REF="${VCPKG_BASELINE:-$BASELINE_FROM_MANIFEST}"

if [ -z "$VCPKG_REF" ]; then
    log "WARNING: no builtin-baseline in vcpkg.json and no VCPKG_BASELINE env var."
    log "         Falling back to origin/master — builds are NOT reproducible."
    log "         Pin a baseline by running: cd \"$VCPKG_DIR\" && git rev-parse HEAD"
    log "         then paste that SHA into vcpkg.json:\"builtin-baseline\"."
    VCPKG_REF="master"
fi

(
    cd "$VCPKG_DIR"
    git fetch --quiet origin
    git checkout --quiet --detach "origin/$VCPKG_REF" 2>/dev/null \
        || git checkout --quiet --detach "$VCPKG_REF"
)

if [ ! -x "$VCPKG_DIR/vcpkg" ]; then
    log "bootstrapping vcpkg"
    "$VCPKG_DIR/bootstrap-vcpkg.sh" -disableMetrics
fi

# -----------------------------------------------------------------------------
# pkg-config — vcpkg's port system shells out to it during the .pc-fixup step
# of nearly every port. If the host doesn't have one, install vcpkg's own
# pkgconf port using the *default* host triplet (arm64-osx, not our static
# triplet) and prepend its bin dir to PATH for the rest of this script.
# -----------------------------------------------------------------------------

if ! command -v pkg-config >/dev/null 2>&1; then
    log "no system pkg-config — installing pkgconf via vcpkg"
    # Run from VCPKG_DIR (no vcpkg.json there) so we're in classic mode, not
    # manifest mode.
    ( cd "$VCPKG_DIR" && ./vcpkg install pkgconf --disable-metrics )
    PKGCONF_BIN="$VCPKG_DIR/installed/arm64-osx/tools/pkgconf"
    # The pkgconf binary checks argv[0] and behaves like pkg-config if invoked
    # under that name. A symlink is enough — vcpkg's port system uses
    # `command -v pkg-config` to discover it.
    if [ -x "$PKGCONF_BIN/pkgconf" ] && [ ! -e "$PKGCONF_BIN/pkg-config" ]; then
        ln -sf pkgconf "$PKGCONF_BIN/pkg-config"
    fi
    [ -d "$PKGCONF_BIN" ] && export PATH="$PKGCONF_BIN:$PATH"
fi

if ! command -v pkg-config >/dev/null 2>&1; then
    die "pkg-config still not on PATH after vcpkg pkgconf install. Investigate $VCPKG_DIR/installed/arm64-osx/tools/pkgconf/."
fi

# -----------------------------------------------------------------------------
# Install the dependency set
# -----------------------------------------------------------------------------

log "running vcpkg install (this may take 30–60 minutes on first run)"

"$VCPKG_DIR/vcpkg" install \
    --triplet="$TRIPLET" \
    --overlay-triplets="$TRIPLETS_DIR" \
    --x-install-root="$INSTALL_ROOT" \
    --x-manifest-root="$REPO_ROOT" \
    --clean-after-build \
    --disable-metrics

[ -d "$INSTALL_PREFIX/lib" ] || die "vcpkg install completed but $INSTALL_PREFIX/lib is missing"

# -----------------------------------------------------------------------------
# Emit Generated/ThirdParty.generated.xcconfig
#
# Enumerate every .a in the install prefix, emit -l<name> entries for each.
# Linker order matters for static libs — put the high-level libs first
# (OpenColorIO, OpenImageIO, OpenEXR, Imath) and let the linker pull in the
# rest. macOS ld64 makes multiple passes over the .a list and handles cycles,
# so a strict topological sort isn't required.
# -----------------------------------------------------------------------------

mkdir -p "$GENERATED_DIR"

# High-priority libs first (in this exact order — ld64 makes multiple passes but
# leading high-level libs make it pick up the right symbols fastest). Then
# everything else alphabetically. bash 3.2 lacks associative arrays, so we use a
# delimited string for the "seen" set.
HIGH_PRIORITY="OpenColorIO OpenImageIO OpenImageIO_Util OpenEXR OpenEXRUtil OpenEXRCore Iex IlmThread Imath"

ALL_LIBS=""
for f in "$INSTALL_PREFIX"/lib/*.a; do
    [ -f "$f" ] || continue
    base=$(basename "$f" .a)
    base="${base#lib}"
    ALL_LIBS="$ALL_LIBS $base"
done

SEEN=" "
ORDERED=""

# Pass 1: high-priority, in declared order.
for h in $HIGH_PRIORITY; do
    case " $ALL_LIBS " in
        *" $h "*)
            case "$SEEN" in
                *" $h "*) ;;
                *) ORDERED="$ORDERED $h"; SEEN="$SEEN$h " ;;
            esac
            ;;
    esac
done

# Pass 2: everything else, alphabetical.
SORTED=$(printf '%s\n' $ALL_LIBS | LC_ALL=C sort -u)
for l in $SORTED; do
    case "$SEEN" in
        *" $l "*) ;;
        *) ORDERED="$ORDERED $l"; SEEN="$SEEN$l " ;;
    esac
done

LDFLAGS_LINE="OTHER_LDFLAGS = \$(inherited) -lc++"
LIB_COUNT=0
for l in $ORDERED; do
    LDFLAGS_LINE="$LDFLAGS_LINE -l$l"
    LIB_COUNT=$((LIB_COUNT + 1))
done
# System frameworks needed by ImageIO, OIIO threading, and EXR threading.
LDFLAGS_LINE+=" -framework CoreFoundation -framework Foundation -framework ImageIO -framework CoreGraphics -framework CoreServices"

cat > "$GENERATED_XCCONFIG" <<EOF
// Generated by Scripts/build_thirdparty.sh — DO NOT EDIT.
// Re-runs whenever vcpkg.json / vcpkg-configuration.json / Triplets/*.cmake change.

$LDFLAGS_LINE
EOF

log "wrote $GENERATED_XCCONFIG ($LIB_COUNT static libs)"

# -----------------------------------------------------------------------------
# Stamp the hash so the next invocation is a fast cache hit.
# -----------------------------------------------------------------------------

mkdir -p "$INSTALL_ROOT"
echo "$MANIFEST_HASH" > "$HASH_FILE"

log "done. install prefix: $INSTALL_PREFIX"
