#!/usr/bin/env bash
# chr-deploy.sh — install MikroTik CHR EFI image from GitHub Releases
# Usage: sudo ./chr-deploy.sh <target_disk> [--version X.Y.Z]
#
# One-liner:
#   curl -fsSL https://raw.githubusercontent.com/fluidpanda/chr-deploy/refs/heads/master/chr-deploy.sh \
#     | bash -s -- /dev/vda

set -euo pipefail

RELEASES_URL="https://api.github.com/repos/fluidpanda/chr-deploy/releases"

# ── helpers ───────────────────────────────────────────────────────────────────

log()  { echo "  [*] $*"; }
info() { echo ""; echo "══ $* ══"; }
die()  { echo "" >&2; echo "  [!] $*" >&2; exit 1; }

need() { command -v "$1" &>/dev/null || die "Required: $1 (install: $2)"; }

# ── args ──────────────────────────────────────────────────────────────────────

TARGET=""
VERSION_OVERRIDE=""

i=1
while [[ $i -le $# ]]; do
    arg="${!i}"
    case "$arg" in
        --version)   i=$(( i+1 )); VERSION_OVERRIDE="${!i}" ;;
        --version=*) VERSION_OVERRIDE="${arg#--version=}" ;;
        /dev/*)      TARGET="$arg" ;;
        *)           die "Unknown argument: $arg" ;;
    esac
    i=$(( i+1 ))
done

[[ -n "$TARGET" ]] || {
    echo "Usage: sudo $0 <target_disk> [--version X.Y.Z]"
    echo "  sudo $0 /dev/vda"
    echo "  sudo $0 /dev/vda --version 7.21.4"
    exit 1
}

# ── preflight ─────────────────────────────────────────────────────────────────

info "Preflight checks"

[[ $EUID -eq 0 ]] || die "Must run as root"
[[ -b "$TARGET" ]] || die "Not a block device: $TARGET"

if grep -q "^${TARGET}" /proc/mounts 2>/dev/null; then
    die "$TARGET has mounted partitions. Run the script from a live ISO, not from a running system. \
    If you run script on mounted partitions all installation will fail brutally."
fi

need curl "curl"
need unzip "unzip"

# ── resolve version & download URL ────────────────────────────────────────────

info "Resolving version"

if [[ -n "$VERSION_OVERRIDE" ]]; then
    VERSION="$VERSION_OVERRIDE"
    log "Using explicit version: $VERSION"
else
    log "Fetching latest release..."
    VERSION=$(curl -fsSL "$RELEASES_URL/latest" | grep '"tag_name"' | head -1 | cut -d'"' -f4)
    [[ -n "$VERSION" ]] || die "Could not determine latest version from GitHub releases."
    log "Latest: $VERSION"
fi

DOWNLOAD_URL=$(curl -fsSL "$RELEASES_URL/tags/$VERSION" \
    | grep '"browser_download_url"' \
    | grep '\.img\.zip' \
    | head -1 \
    | cut -d'"' -f4)

[[ -n "$DOWNLOAD_URL" ]] || die "No .img.zip found in release $VERSION. Check that the release exists."
log "URL: $DOWNLOAD_URL"

# ── confirm ───────────────────────────────────────────────────────────────────

echo ""
echo "  Target disk : $TARGET"
echo "  Version     : $VERSION"
DISK_SIZE=$(lsblk -dno SIZE "$TARGET" 2>/dev/null || echo "unknown")
echo "  Disk size   : $DISK_SIZE"
echo ""
echo "  !! ALL DATA ON $TARGET WILL BE PERMANENTLY DESTROYED !!"
echo ""
read -rp "  Type YES to proceed: " confirm
[[ "$confirm" == "YES" ]] || die "Aborted."

# ── download ──────────────────────────────────────────────────────────────────

info "Downloading CHR EFI $VERSION"

WORKDIR=$(mktemp -d)
trap 'rm -rf "$WORKDIR"' EXIT
cd "$WORKDIR"

curl -fL --retry 3 --progress-bar -o chr-efi.img.zip "$DOWNLOAD_URL"
unzip -q chr-efi.img.zip
IMG=$(ls *.img 2>/dev/null | head -1)
[[ -n "$IMG" ]] || die "No .img file found after extraction."
log "Image: $IMG ($(du -sh "$IMG" | cut -f1))"

# ── write to disk ─────────────────────────────────────────────────────────────

info "Writing to $TARGET"

echo "  This is the last chance to abort. Press Ctrl+C within 5 seconds..."
sleep 5

log "Running dd..."
dd if="$IMG" of="$TARGET" bs=4M status=progress conv=fsync
sync

echo ""
echo "════════════════════════════════════════════════"
echo "  MikroTik CHR $VERSION (EFI) written to $TARGET"
echo "════════════════════════════════════════════════"
echo ""

read -rp "  Reboot now? [y/N] " do_reboot
if [[ "${do_reboot,,}" == "y" ]]; then
    echo "  Rebooting..."
    reboot
fi
