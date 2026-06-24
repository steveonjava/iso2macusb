#!/usr/bin/env bash
#
# iso2macusb.sh — Convert a prepared Proxmox VE *automated-install* ISO into a
# FAT32/GPT USB image that UEFI-boots on Apple Macs (e.g. MacPro6,1 "trashcan")
# whose BootROM refuses to boot the hybrid ISO directly.
#
# Why: On some Apple UEFI firmware, dd'ing the Proxmox hybrid ISO to USB drops to
# a `grub>` prompt with "invalid magic number" — the El-Torito/ISO GRUB path
# doesn't survive the Apple BootROM. This tool rebuilds a clean FAT32 ESP with a
# self-contained `grub-mkstandalone` EFI (all modules + grub.cfg embedded, no
# external .mod files, no prefix dependency) that boots reliably.
#
# Proven 2026-06-24 installing PVE 9.2-1 on a MacPro6,1.
#
# REQUIREMENTS (run on a Debian/Proxmox host — NOT inside a restricted sandbox):
#   - root (loop devices + mount)
#   - grub-mkstandalone + /usr/lib/grub/x86_64-efi/*.mod   (pkg: grub-efi-amd64-bin)
#   - xorriso or bsdtar (to extract kernel/initrd from the source ISO)
#   - sgdisk (gptfdisk), mkfs.vfat (dosfstools), losetup, mount
#
# USAGE:
#   sudo ./iso2macusb.sh -i proxmox-auto.iso -o proxmox-macusb.img
#   sudo ./iso2macusb.sh -i in.iso -o out.img --label PVEBOOT --extra-args "nomodeset modprobe.blacklist=b43,bcma,wl"
#
# Then flash + verify (see printed instructions, or --flash /dev/sdX to do it here).
#
set -euo pipefail

LABEL="PVEBOOT"
EXTRA_ARGS="nomodeset modprobe.blacklist=b43,b43legacy,ssb,bcma,brcmsmac,brcmfmac,wl"
KERNEL_NAME="linux26"        # Proxmox ISO kernel filename under /boot
INITRD_NAME="initrd.img"
FLASH_DEV=""
SRC_ISO=""
OUT_IMG=""

die(){ echo "ERROR: $*" >&2; exit 1; }

check_tools() {
  local tool pkg missing=0
  local -A tool_pkgs=(
    [grub-mkstandalone]="grub-efi-amd64-bin"
    [sgdisk]="gdisk"
    [mkfs.vfat]="dosfstools"
    [losetup]="util-linux"
    [blkid]="util-linux"
  )
  for tool in grub-mkstandalone sgdisk mkfs.vfat losetup blkid; do
    if ! command -v "$tool" >/dev/null 2>&1; then
      pkg="${tool_pkgs[$tool]}"
      echo "ERROR: missing required tool: $tool. Install: apt-get install $pkg" >&2
      missing=1
    fi
  done
  [[ $missing -eq 0 ]] || exit 1
  [[ -d /usr/lib/grub/x86_64-efi ]] || die "missing /usr/lib/grub/x86_64-efi (install grub-efi-amd64-bin)"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -i|--iso) SRC_ISO="$2"; shift 2;;
    -o|--out) OUT_IMG="$2"; shift 2;;
    --label) LABEL="$2"; shift 2;;
    --extra-args) EXTRA_ARGS="$2"; shift 2;;
    --flash) FLASH_DEV="$2"; shift 2;;
    -h|--help) grep '^#' "$0" | sed 's/^# \{0,1\}//'; exit 0;;
    *) die "unknown arg: $1";;
  esac
done

[[ -n "$SRC_ISO" && -f "$SRC_ISO" ]] || die "give a valid source ISO with -i"
[[ -n "$OUT_IMG" ]] || die "give an output image path with -o"
[[ $EUID -eq 0 ]] || die "run as root (loop/mount needed)"
check_tools

WORK="$(mktemp -d)"; ISO_MNT="$(mktemp -d)"; IMG_MNT="$(mktemp -d)"
LOOP_ISO=""; LOOP_IMG=""
cleanup(){
  set +e
  mountpoint -q "$IMG_MNT" && umount "$IMG_MNT"
  [[ -n "$LOOP_IMG" ]] && losetup -d "$LOOP_IMG"
  mountpoint -q "$ISO_MNT" && umount "$ISO_MNT"
  [[ -n "$LOOP_ISO" ]] && losetup -d "$LOOP_ISO"
  rm -rf "$WORK" "$ISO_MNT" "$IMG_MNT"
}
trap cleanup EXIT INT TERM

echo "== [1/6] mounting source ISO =="
LOOP_ISO="$(losetup --find --show "$SRC_ISO")"
mount -o ro "$LOOP_ISO" "$ISO_MNT"

# locate kernel + initrd (Proxmox keeps them under /boot)
KSRC=""; ISRC=""
for p in "/boot/$KERNEL_NAME" "/$KERNEL_NAME"; do [[ -f "$ISO_MNT$p" ]] && KSRC="$ISO_MNT$p" && break; done
for p in "/boot/$INITRD_NAME" "/$INITRD_NAME"; do [[ -f "$ISO_MNT$p" ]] && ISRC="$ISO_MNT$p" && break; done
[[ -n "$KSRC" ]] || die "kernel '$KERNEL_NAME' not found on ISO (looked in /boot and /)"
[[ -n "$ISRC" ]] || die "initrd '$INITRD_NAME' not found on ISO (looked in /boot and /)"
# sanity: kernel must be a real bzImage (HdrS magic at offset 514)
if [[ "$(dd if="$KSRC" bs=1 skip=514 count=4 2>/dev/null)" != "HdrS" ]]; then
  die "$KSRC is not a valid bzImage (no HdrS magic) — wrong kernel name?"
fi
KSIZE=$(stat -c%s "$KSRC"); ISIZE=$(stat -c%s "$ISRC")
echo "  kernel: $KSRC ($KSIZE bytes, bzImage OK)"
echo "  initrd: $ISRC ($ISIZE bytes)"

echo "== [2/6] sizing image =="
# image = kernel + initrd + ~120MB slack for EFI binary + FS overhead, rounded up
SLACK=$((180*1024*1024))
PAYLOAD=$((KSIZE + ISIZE + SLACK))
# round up to 16MB
IMG_BYTES=$(( ((PAYLOAD + 16*1024*1024 - 1) / (16*1024*1024)) * 16*1024*1024 ))
echo "  image size: $IMG_BYTES bytes"
rm -f "$OUT_IMG"
truncate -s "$IMG_BYTES" "$OUT_IMG"

echo "== [3/6] GPT + FAT32 ESP =="
sgdisk --zap-all "$OUT_IMG" >/dev/null
# one EFI System partition spanning the disk (1MiB aligned)
sgdisk -n 1:2048:0 -t 1:ef00 -c 1:ESP "$OUT_IMG" >/dev/null
LOOP_IMG="$(losetup --find --show -P "$OUT_IMG")"; sleep 1
PART="${LOOP_IMG}p1"
[[ -b "$PART" ]] || die "partition device $PART missing"
mkfs.vfat -F32 -n "$LABEL" "$PART" >/dev/null
FATUUID="$(blkid -s UUID -o value "$PART")"
mount "$PART" "$IMG_MNT"

echo "== [4/6] building embedded grub.cfg + standalone BOOTX64.EFI =="
cat > "$WORK/grub.cfg" <<EOF
set timeout=5
set default=0
insmod part_gpt
insmod fat
insmod search
insmod search_label
insmod search_fs_uuid
insmod normal
insmod linux
insmod echo
insmod all_video
insmod gfxterm
search --no-floppy --label $LABEL --set=root
if [ -z "\$root" ]; then search --no-floppy --fs-uuid $FATUUID --set=root; fi
menuentry "Install Proxmox VE (Automated, Mac, embedded ISO)" {
    echo "Loading kernel..."
    linux /$KERNEL_NAME ro ramdisk_size=16777216 rw quiet splash=silent proxmox-start-auto-installer $EXTRA_ARGS
    echo "Loading initrd (large, please wait)..."
    initrd /$INITRD_NAME
}
menuentry "Install Proxmox VE (serial debug)" {
    linux /$KERNEL_NAME ro ramdisk_size=16777216 rw proxmox-start-auto-installer $EXTRA_ARGS console=ttyS0,115200 console=tty0
    initrd /$INITRD_NAME
}
EOF

mkdir -p "$IMG_MNT/EFI/BOOT"
grub-mkstandalone \
  -O x86_64-efi \
  -o "$IMG_MNT/EFI/BOOT/BOOTX64.EFI" \
  --modules="part_gpt fat search search_label search_fs_uuid normal linux echo configfile all_video gfxterm test halt reboot ls" \
  "boot/grub/grub.cfg=$WORK/grub.cfg"

echo "== [5/6] copying kernel + initrd + grub.cfg to FAT root =="
cp "$KSRC" "$IMG_MNT/$KERNEL_NAME"
cp "$ISRC" "$IMG_MNT/$INITRD_NAME"
cp "$WORK/grub.cfg" "$IMG_MNT/grub.cfg"
sync
umount "$IMG_MNT"
losetup -d "$LOOP_IMG"; LOOP_IMG=""
umount "$ISO_MNT"
losetup -d "$LOOP_ISO"; LOOP_ISO=""

echo "== [6/6] done =="
MD5="$(md5sum "$OUT_IMG" | awk '{print $1}')"
echo "  image : $OUT_IMG"
echo "  bytes : $IMG_BYTES"
echo "  md5   : $MD5"
echo "  label : $LABEL   fs-uuid: $FATUUID"
echo
echo "FLASH + VERIFY (replace /dev/sdX with your USB; this ERASES it):"
echo "  dd if=$OUT_IMG of=/dev/sdX bs=4M conv=fsync status=progress"
echo "  sync; blockdev --flushbufs /dev/sdX"
echo "  dd if=/dev/sdX bs=4M iflag=fullblock 2>/dev/null | head -c $IMG_BYTES | md5sum   # expect $MD5"

if [[ -n "$FLASH_DEV" ]]; then
  echo
  read -r -p "Flash to $FLASH_DEV now? This ERASES it. [type YES]: " ans
  [[ "$ans" == "YES" ]] || die "aborted flash"
  dd if="$OUT_IMG" of="$FLASH_DEV" bs=4M conv=fsync status=progress
  sync; blockdev --flushbufs "$FLASH_DEV"
  RB="$(dd if="$FLASH_DEV" bs=4M iflag=fullblock 2>/dev/null | head -c "$IMG_BYTES" | md5sum | awk '{print $1}')"
  if [[ "$RB" == "$MD5" ]]; then
    echo "VERIFY OK ($RB)"
  else
    die "VERIFY MISMATCH: got $RB want $MD5"
  fi
fi
