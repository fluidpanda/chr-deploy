# chr-deploy

Automated build and installation of MikroTik RouterOS CHR with UEFI boot support.

The official CHR image ships with an ext2 first partition which UEFI firmware cannot read.
This project reformats it to FAT and publishes a ready-to-use EFI image via GitHub Releases.
A new release is built automatically whenever a new RouterOS stable version is detected.

## Install

Boot your target machine from any Linux live ISO, then run:

```bash
curl -fsSL https://raw.githubusercontent.com/fluidpanda/chr-deploy/main/chr-deploy.sh | bash -s -- /dev/vda
```

The script downloads the prebuilt EFI image from Releases and writes it to the target disk with `dd`.
After rebooting, CHR will expand its data partition to fill the available disk space on first boot.

**Dependencies:** `curl`, `unzip` — available on any live ISO out of the box.

## How it works

### Image build (`build.yml`)

Runs daily and on manual trigger. If a newer RouterOS stable version is found and no release exists for it yet:

1. Downloads the official `chr-<version>.img.zip` from `download.mikrotik.com`
2. Mounts the image via `qemu-nbd`
3. Reformats the first partition from ext2 to FAT (preserving `EFI/BOOT/BOOTX64.EFI` and `map`)
4. Converts back to raw and publishes as `chr-efi-<version>.img.zip` in GitHub Releases

### Install script (`chr-deploy.sh`)

1. Fetches the latest release version from GitHub API (or uses `--version`)
2. Downloads and extracts the prebuilt EFI image
3. Writes it to the target disk with `dd`

## VM requirements

- Firmware: **UEFI** (OVMF)
- Machine type: **Q35**
- OS variant: **Generic Linux 2022** or equivalent
- Disk: VirtIO

For legacy BIOS setups use the official unmodified image from [mikrotik.com/download](https://mikrotik.com/download).
