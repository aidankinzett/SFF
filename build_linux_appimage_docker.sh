#!/usr/bin/env bash
# Build the SteaMidra AppImage inside an Ubuntu 24.04 container.
#
# Usage: bash build_linux_appimage_docker.sh [--fresh] [SRC_DIR]
#
#   --fresh    wipe the container's .venv and reinstall from scratch.
#              Only needed after requirements-linux.txt changes; without it
#              the venv is reused and the build skips straight to PyInstaller
#              (~3 min instead of ~15).
#   SRC_DIR    tree to build (default: this script's directory).
#
# Why a container:
#   * build_linux_appimage.sh targets Debian/Ubuntu — it probes dpkg and
#     python3.12, neither of which exists on Arch-family distros.
#   * ubuntu:24.04 is what upstream CI uses (release.yml: runs-on ubuntu-24.04).
#   * Building against the older glibc there keeps the AppImage portable:
#     a binary linked against 2.39 runs on newer systems, not the reverse.
#
# Build in a SEPARATE tree, not your working copy — the build creates a
# Python 3.12 .venv and would clobber whatever .venv you run from source with.
# A detached worktree shares the git object store and costs no extra history:
#
#   git worktree add --detach ../SFF-build local-fixes
#   bash build_linux_appimage_docker.sh ../SFF-build
#
# Output: SteaMidra-<version>-x86_64.AppImage in SRC_DIR, owned by you.

set -eo pipefail

BUILD_ARGS=""
SRC_DIR=""
for arg in "$@"; do
    case "$arg" in
        --fresh) BUILD_ARGS="--fresh" ;;
        *)       SRC_DIR="$arg" ;;
    esac
done
if [ -z "$SRC_DIR" ]; then
    SRC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
fi
SRC_DIR="$(cd "$SRC_DIR" && pwd)"

command -v docker >/dev/null 2>&1 || {
    echo "ERROR: docker not found in PATH." >&2
    exit 1
}
[ -f "$SRC_DIR/build_linux_appimage.sh" ] || {
    echo "ERROR: $SRC_DIR is not a SteaMidra checkout (no build_linux_appimage.sh)." >&2
    exit 1
}

echo "==> Building $SRC_DIR in ubuntu:24.04 ${BUILD_ARGS:+($BUILD_ARGS)}"

docker run --rm \
    -v "$SRC_DIR":/src \
    -e HOST_UID="$(id -u)" \
    -e HOST_GID="$(id -g)" \
    -e BUILD_ARGS="$BUILD_ARGS" \
    ubuntu:24.04 bash -c '
set -eo pipefail

# Hand artifacts back to the invoking user even on failure, so a broken build
# does not leave root-owned files behind in the source tree.
trap "chown -R ${HOST_UID}:${HOST_GID} /src 2>/dev/null || true" EXIT

echo "=== apt: installing build prerequisites ==="
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
# git and binutils are needed by the build itself (VCS pin in
# requirements-linux.txt, and objdump for PyInstaller). They come preinstalled
# on GitHub runners, so CI never has to ask for them; a bare image does.
apt-get install -y -qq --no-install-recommends \
    python3.12 python3.12-venv python3.12-dev wget ca-certificates git \
    binutils desktop-file-utils file \
    libfuse2 libatomic1 libnss3 libnspr4 libxkbfile1 \
    libxkbcommon-x11-0 libxcb-cursor0 libxcb-xkb1 libxcb-image0 \
    libxcb-keysyms1 libxcb-util1 libxcb-render-util0 libxcb-icccm4 \
    libxcb-shape0 libasound2t64 \
    >/dev/null

# appimagetool is itself an AppImage and self-mounts via FUSE, which a
# container has no access to. This makes it extract and run instead.
export APPIMAGE_EXTRACT_AND_RUN=1

cd /src
bash build_linux_appimage.sh ${BUILD_ARGS}
ls -lh /src/*.AppImage
'
