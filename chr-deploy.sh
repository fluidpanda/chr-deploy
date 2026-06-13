#!/usr/bin/env bash
# chr-install-efi.sh — download, convert to UEFI-bootable, and dd MikroTik CHR
# Usage: sudo ./chr-install-efi.sh <target_disk> [--version X.Y.Z] [--hybrid-mbr]
#
# Dependencies: curl unzip qemu-utils dosfstools rsync
#               (optional) gdisk — only needed with --hybrid-mbr
#
# --version X.Y.Z: install a specific version instead of latest stable.
#                  useful for longterm releases — current version is on
#                  https://forum.mikrotik.com/c/announcements (look for [long-term])
# --hybrid-mbr:    additionally patches partition table for legacy BIOS+UEFI boot
#                  (needed if your hypervisor or bare metal still uses SeaBIOS)

set -euo pipefail

# ── helpers ───────────────────────────────────────────────────────────────────

log()  { echo "  [*] $*"; }
info() { echo ""; echo "══ $* ══"; }
die()  { echo "" >&2; echo "  [!] $*" >&2; exit 1; }

need() {
    command -v "$1" &>/dev/null || \
        die "Required tool not found: '$1'. Install: $2"
}

free_nbd() {
    # find the first nbd device not in use
    for dev in /dev/nbd{0..15}; do
        [[ -b "$dev" ]] || continue
        if ! lsblk "$dev" &>/dev/null || [[ -z "$(lsblk -no NAME "$dev" 2>/dev/null | tail -n+2)" ]]; then
            # double-check: qemu-nbd reports connected devices in /sys
            local sysname
            sysname=$(basename "$dev")
            if [[ ! -f "/sys/block/$sysname/pid" ]]; then
                echo "$dev"
                return 0
            fi
        fi
    done
    die "No free /dev/nbd* devices found. Is the nbd module loaded?"
}

# ── args ──────────────────────────────────────────────────────────────────────

TARGET=""
HYBRID_MBR=false
VERSION_OVERRIDE=""
WORKDIR_BASE=""

i=1
while [[ $i -le $# ]]; do
    arg="${!i}"
    case "$arg" in
        --hybrid-mbr)
            HYBRID_MBR=true
            ;;
        --version)
            i=$(( i + 1 ))
            [[ $i -le $# ]] || die "--version requires an argument (e.g. --version 7.21.4)"
            VERSION_OVERRIDE="${!i}"
            ;;
        --version=*)
            VERSION_OVERRIDE="${arg#--version=}"
            ;;
        --workdir)
            i=$(( i + 1 ))
            [[ $i -le $# ]] || die "--workdir requires a path argument"
            WORKDIR_BASE="${!i}"
            ;;
        --workdir=*)
            WORKDIR_BASE="${arg#--workdir=}"
            ;;
        /dev/*)
            TARGET="$arg"
            ;;
        *)
            die "Unknown argument: $arg"
            ;;
    esac
    i=$(( i + 1 ))
done

[[ -n "$TARGET" ]] || {
    echo "Usage: sudo $0 <target_disk> [--version X.Y.Z] [--workdir /path] [--hybrid-mbr]"
    echo "  Depends: curl, unzip, qemu-utils, rsync, dosfstools, gdisk"
    echo "  Examples:"
    echo "    sudo $0 /dev/vda"
    echo "    sudo $0 /dev/vda --version 7.21.4   # specific / longterm version"
    echo "    sudo $0 /dev/vda --workdir /mnt/data # custom workdir (~500 MB needed)"
    echo "    sudo $0 /dev/vda --hybrid-mbr        # BIOS + UEFI hybrid boot"
    exit 1
}

# ── preflight ─────────────────────────────────────────────────────────────────

info "Preflight checks"

[[ $EUID -eq 0 ]] || die "Must run as root (sudo $0 ...)"

[[ -b "$TARGET" ]] || die "Not a block device: $TARGET"

# warn if target disk partitions are mounted (normal for live-system installs)
if grep -q "^${TARGET}" /proc/mounts 2>/dev/null; then
    echo ""
    echo "  WARNING: $TARGET has mounted partitions (live system install)."
    echo "  The kernel will continue running from RAM during dd."
    echo "  Reboot immediately after the script finishes — do nothing else."
    echo ""
fi

need curl "curl"
need unzip "unzip"
need qemu-img "qemu-utils"
need qemu-nbd "qemu-utils"
need rsync "rsync"
need mkfs.fat "dosfstools"
need sgdisk "gdisk"

if $HYBRID_MBR; then
    need gdisk "gdisk"
fi

# ── confirm ───────────────────────────────────────────────────────────────────

echo ""
echo "  Target disk : $TARGET"
echo "  Hybrid MBR  : $HYBRID_MBR"
[[ -n "$VERSION_OVERRIDE" ]] && echo "  Version     : $VERSION_OVERRIDE (explicit)" || echo "  Version     : latest stable (auto)"
[[ -n "$WORKDIR_BASE"    ]] && echo "  Work dir    : $WORKDIR_BASE" || echo "  Work dir    : /tmp (default)"
DISK_SIZE=$(lsblk -dno SIZE "$TARGET" 2>/dev/null || echo "unknown")
echo "  Disk size   : $DISK_SIZE"
echo ""
echo "  !! ALL DATA ON $TARGET WILL BE PERMANENTLY DESTROYED !!"
echo ""
read -rp "  Type YES to proceed: " confirm
[[ "$confirm" == "YES" ]] || die "Aborted by user."

# ── workspace & cleanup ───────────────────────────────────────────────────────

if [[ -n "$WORKDIR_BASE" ]]; then
    [[ -d "$WORKDIR_BASE" ]] || die "Workdir does not exist: $WORKDIR_BASE"
    WORKDIR=$(mktemp -d "$WORKDIR_BASE/chr-install.XXXXXXXX")
else
    WORKDIR=$(mktemp -d /tmp/chr-install.XXXXXXXX)
fi
MNT_BIOS="/tmp/chr-mnt-bios"
MNT_EFI="/tmp/chr-mnt-efi"

NBD_BIOS=""
NBD_EFI=""

cleanup() {
    log "Cleaning up..."
    umount "$MNT_BIOS" 2>/dev/null || true
    umount "$MNT_EFI"  2>/dev/null || true
    [[ -n "$NBD_BIOS" ]] && qemu-nbd -d "$NBD_BIOS" 2>/dev/null || true
    [[ -n "$NBD_EFI"  ]] && qemu-nbd -d "$NBD_EFI"  2>/dev/null || true
    rm -rf "$WORKDIR" "$MNT_BIOS" "$MNT_EFI"
}
trap cleanup EXIT

cd "$WORKDIR"

# ── get latest version ────────────────────────────────────────────────────────

info "Resolving CHR version"

if [[ -n "$VERSION_OVERRIDE" ]]; then
    VERSION="$VERSION_OVERRIDE"
    log "Using explicit version: $VERSION"
else
    log "Fetching latest stable version..."
    VERSION=$(curl -fsSL --retry 3 --connect-timeout 10 \
        https://upgrade.mikrotik.com/routeros/NEWESTa7.stable | \
        awk '{print $1}')
    [[ -n "$VERSION" ]] || die "Could not determine latest RouterOS version."
    log "Latest stable: $VERSION"
fi

# ── download ──────────────────────────────────────────────────────────────────

info "Downloading CHR $VERSION"

URL="https://download.mikrotik.com/routeros/$VERSION/chr-$VERSION.img.zip"
log "URL: $URL"

curl -fL --retry 3 --connect-timeout 15 --progress-bar \
    -o chr.img.zip "$URL"

log "Extracting..."
unzip -q chr.img.zip
rm -f chr.img.zip

RAW_IMG=$(ls chr-*.img 2>/dev/null | head -1)
[[ -n "$RAW_IMG" ]] || die "No .img file found after extraction."
log "Image: $RAW_IMG ($(du -sh "$RAW_IMG" | cut -f1))"

# ── convert to qcow2 ──────────────────────────────────────────────────────────

info "Converting to qcow2"

log "Original image -> chr-bios.qcow2..."
qemu-img convert -f raw -O qcow2 "$RAW_IMG" chr-bios.qcow2

log "Copying -> chr-efi.qcow2 (this will be patched for UEFI)..."
cp chr-bios.qcow2 chr-efi.qcow2

rm -f "$RAW_IMG"

# ── load nbd ──────────────────────────────────────────────────────────────────

info "Setting up NBD devices"

# max_part=16 ensures partition devices like /dev/nbd0p1 appear
if ! lsmod | grep -q '^nbd '; then
    log "Loading nbd kernel module..."
    modprobe nbd max_part=16
else
    log "nbd module already loaded."
fi

# wait for /dev/nbd* to appear
sleep 0.5

NBD_BIOS=$(free_nbd)
log "Connecting chr-bios.qcow2 -> $NBD_BIOS"
qemu-nbd -c "$NBD_BIOS" chr-bios.qcow2

NBD_EFI=$(free_nbd)
log "Connecting chr-efi.qcow2  -> $NBD_EFI"
qemu-nbd -c "$NBD_EFI" chr-efi.qcow2

# let the kernel settle and enumerate partitions
sleep 1

# if partition devices still absent, try partprobe
if [[ ! -b "${NBD_BIOS}p1" ]]; then
    log "Partition not visible yet, running partprobe..."
    partprobe "$NBD_BIOS" 2>/dev/null || true
    partprobe "$NBD_EFI"  2>/dev/null || true
    sleep 1
fi

[[ -b "${NBD_BIOS}p1" ]] || die "Partition ${NBD_BIOS}p1 not found. Try: modprobe nbd max_part=16"
[[ -b "${NBD_EFI}p1"  ]] || die "Partition ${NBD_EFI}p1 not found."

# ── patch EFI partition ───────────────────────────────────────────────────────

info "Patching EFI boot partition"

log "Formatting ${NBD_EFI}p1 as FAT (was ext2)..."
mkfs.fat "${NBD_EFI}p1"

log "Syncing boot files from original to EFI image..."
mkdir -p "$MNT_BIOS" "$MNT_EFI"
mount "${NBD_BIOS}p1" "$MNT_BIOS"
mount "${NBD_EFI}p1"  "$MNT_EFI"

rsync -a "$MNT_BIOS/" "$MNT_EFI/"

umount "$MNT_BIOS"
umount "$MNT_EFI"

# ── optional: hybrid MBR (legacy BIOS + UEFI) ────────────────────────────────

if $HYBRID_MBR; then
    info "Patching Hybrid MBR (BIOS + UEFI)"
    log "Running gdisk on $NBD_EFI..."

    # gdisk interactive sequence:
    #   2       → switch to GPT mode
    #   t 1 8300 → set p1 type to Linux filesystem
    #   r       → recovery/transformation menu
    #   h       → create hybrid MBR
    #   1 2     → include partitions 1 and 2
    #   n       → don't place EFI GPT (0xEE) entry first
    #   <Enter> → hex code for p1 = 83 (Linux)
    #   y       → set bootable flag on p1
    #   <Enter> → hex code for p2 = 83
    #   n       → no bootable flag on p2
    #   n       → don't use unused space
    #   w y     → write and confirm
    (
        printf '2\nt\n1\n8300\nr\nh\n1 2\nn\n\ny\n\nn\nn\nw\ny\n'
    ) | gdisk "$NBD_EFI" || true
    # gdisk returns non-zero even on success sometimes; errors will be visible above
fi

# ── disconnect nbd ────────────────────────────────────────────────────────────

info "Disconnecting NBD devices"

qemu-nbd -d "$NBD_BIOS"
NBD_BIOS=""
qemu-nbd -d "$NBD_EFI"
NBD_EFI=""

# ── convert back to raw ───────────────────────────────────────────────────────

info "Converting EFI image back to raw"

log "chr-efi.qcow2 -> chr-efi.img..."
qemu-img convert -f qcow2 -O raw chr-efi.qcow2 chr-efi.img
IMG_SIZE=$(du -sh chr-efi.img | cut -f1)
log "Final image size: $IMG_SIZE"

# ── write to disk ─────────────────────────────────────────────────────────────

info "Writing to $TARGET"

# warn if target appears to be the current root device
ROOT_DEV=$(findmnt -n -o SOURCE / 2>/dev/null | sed 's/[0-9]*$//' || true)
if [[ -n "$ROOT_DEV" && "$ROOT_DEV" == "$TARGET" ]]; then
    echo ""
    echo "  NOTE: $TARGET appears to be your current root disk."
    echo "  The kernel will keep running from RAM — this is fine."
    echo "  Do NOT reboot manually before dd finishes. Reboot immediately after."
    echo ""
fi
echo "  This is the last chance to abort. Press Ctrl+C within 5 seconds..."
sleep 5

log "Running dd..."
dd if=chr-efi.img of="$TARGET" bs=4M status=progress conv=fsync

sync

log "Relocating GPT backup header to end of disk..."
sgdisk -e "$TARGET"

# ── done ──────────────────────────────────────────────────────────────────────

echo ""
echo "════════════════════════════════════════════════"
echo "  MikroTik CHR $VERSION (UEFI) written to $TARGET"
if $HYBRID_MBR; then
    echo "  Hybrid MBR: yes (BIOS + UEFI)"
else
    echo "  Hybrid MBR: no  (UEFI only)"
fi
echo "════════════════════════════════════════════════"
echo ""

read -rp "  Reboot now? [y/N] " do_reboot
if [[ "${do_reboot,,}" == "y" ]]; then
    echo "  Rebooting..."
    reboot
fi
