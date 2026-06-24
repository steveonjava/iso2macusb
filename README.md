# iso2macusb — boot a Proxmox VE automated-install ISO on an Apple Mac

Convert a prepared **Proxmox VE automated-install ISO** into a **FAT32/GPT USB image** that
UEFI-boots on Apple Macs (tested: **MacPro6,1 "trashcan"**) whose BootROM refuses to boot the
stock hybrid ISO.

## The problem

`dd`-ing the Proxmox hybrid ISO to a USB stick and booting it on some Apple firmware fails:

- It drops to a `grub>` prompt, and `linux /boot/linux26` returns **`error: invalid magic number`** —
  the El-Torito / ISO9660 GRUB path doesn't survive the Apple BootROM's UEFI loader.
- Hand-built FAT32 images often fail differently: a **modular** GRUB EFI binary lands at a bare
  prompt with **`error: file '/x86_64-efi/ls.mod' not found`** because its `prefix` is empty/wrong,
  so it can't load runtime `.mod` files *or* its own `grub.cfg`, and `search --label` returns
  `no such device`.

## The fix

Rebuild the USB as a clean **FAT32/GPT** image whose EFI loader is a **`grub-mkstandalone`**
binary: all GRUB modules **and** `grub.cfg` are embedded inside `BOOTX64.EFI` as an internal
memdisk. No external `.mod` files, no `prefix` dependency, no rescue prompt. The Mac reads FAT32
natively, GRUB loads the kernel/initrd as plain files, and the Proxmox auto-installer runs.

Proven 2026-06-24 installing **PVE 9.2-1** unattended on a MacPro6,1.

## Requirements

**Stage 2** (`iso2macusb.sh`) requires:

- root (loop devices + mount)
- `grub-mkstandalone` and `/usr/lib/grub/x86_64-efi/*.mod` -- `apt install grub-efi-amd64-bin`
- `sgdisk` (`gdisk`), `mkfs.vfat` (`dosfstools`), `losetup`, `mount`, `blkid`

**Stage 2 requires real loop devices and must be run on a physical or VM Linux host -- it will NOT work in an unprivileged container or standard CI.**

**Stage 1** (`prepare-iso.sh`) requires `proxmox-auto-install-assistant` (from Proxmox repos) and `xorriso`. It runs fine in a Debian container or VM.

## Pipeline overview

Two stages (plus flash):

```
stock Proxmox ISO ──prepare-iso.sh──▶ automated-install ISO ──iso2macusb.sh──▶ FAT32 USB image ──dd──▶ boot on Mac
   (download)         (+ answer.toml,        (offline, embedded         (grub-mkstandalone)
                       --fetch-from iso)       initrd)
```

- **Stage 1 — `prepare-iso.sh`**: bakes your `answer.toml` into a stock Proxmox ISO via
  `proxmox-auto-install-assistant`. Default `--fetch-from iso` = fully offline (embedded initrd),
  best for Macs with no reliable installer-time NIC. *(Needs the Proxmox repos / a Debian-13 host
  or container with `proxmox-auto-install-assistant`.)*
- **Stage 2 — `iso2macusb.sh`**: converts that ISO into the Mac-bootable FAT32/GPT image.

## Usage

```bash
# 0) Download a stock Proxmox VE ISO and verify its SHA256 against the published SHA256SUMS.

# 1) Prepare the automated-install ISO (bake in answer.toml, offline mode):
cp answer.toml.example answer.toml   # then edit: fqdn, root hash (mkpasswd -m yescrypt), ssh key, disk filter
./prepare-iso.sh -i proxmox-ve_9.x.iso -a answer.toml -o proxmox-auto.iso

# 2) Convert it to a Mac-bootable USB image:
sudo ./iso2macusb.sh -i proxmox-auto.iso -o proxmox-macusb.img

# Optional flags:
#   --label PVEBOOT                  FAT label (default PVEBOOT)
#   --extra-args "nomodeset ..."     extra kernel cmdline (default blacklists Apple BCM Wi-Fi)
#   --flash /dev/sdX                 also flash + md5-verify to a device (prompts YES)

# 3) Flash + verify (the script prints exact commands):
sudo dd if=proxmox-macusb.img of=/dev/sdX bs=4M conv=fsync status=progress
sync; sudo blockdev --flushbufs /dev/sdX
sudo dd if=/dev/sdX bs=4M iflag=fullblock 2>/dev/null | head -c <BYTES> | md5sum   # must match
```

Identify the USB unambiguously first: `lsblk -o NAME,SIZE,TYPE,TRAN,MODEL,SERIAL` — pick the one
with `TRAN=usb` and `removable=1`. **Double-check the device; `dd` to the wrong disk is destructive.**

## Booting on the Mac

1. Insert the USB in a **rear/direct port** (avoid hubs/front ports). Power on; hold **Option (⌥)**
   if needed and pick the EFI Boot volume.
2. GRUB shows a 2-entry menu and auto-selects entry 1 after 5s:
   `Loading kernel...` → `Loading initrd (...)` (a pause if the initrd is large) → the Proxmox
   auto-installer reads your `answer.toml` and installs unattended.
3. `L1TF CPU bug present and SMT on, data leaks possible` at boot is a **harmless advisory** on
   older Xeons, not an error.
4. **Pull the USB after install** so it doesn't re-enter the installer.

## Important: initrd / `--fetch-from` mode

This tool copies the ISO's `/boot/linux26` and `/boot/initrd.img` onto the FAT image.

- If you built the ISO with **`--fetch-from iso`** (the *embedded-ISO* variant), the initrd is
  large (~1.7 GB) and contains the whole installer payload — fully offline install. **Recommended**
  for a Mac with no reliable installer NIC at boot.
- If you used the default prepared ISO, `/boot/initrd.img` is small (~55 MB) and the installer
  expects to **fetch the rest over the network/HTTP** — make sure that path works on the target.

Either way the boot mechanics here are identical; just know which initrd you're shipping.

## If it still drops to `grub>`

`ls` is embedded, so you can recover by hand:

```
ls                                   # list devices; find the USB partition with linux26/initrd.img
search --no-floppy --label PVEBOOT --set=root      # or: set root=(hd0,gpt1)  /  set root=(hd0)
linux /linux26 ro ramdisk_size=16777216 rw quiet splash=silent proxmox-start-auto-installer nomodeset
initrd /initrd.img
boot
```

…or load the baked-in menu: `configfile (memdisk)/boot/grub/grub.cfg`.

## Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| `invalid magic number` on `linux` | booting the hybrid ISO, or wrong kernel file | use this tool's FAT32 image; verify kernel is a bzImage (`HdrS` at offset 514) |
| `error: file '/x86_64-efi/ls.mod' not found` | modular GRUB with bad prefix | use `grub-mkstandalone` (this tool does) |
| `search ... no such device` at bare prompt | FAT module not active / wrong prefix | `grub-mkstandalone` build; or `set root=(hd0,gpt1)` manually |
| Booted but it's the OLD installer | stale USB — image wasn't re-flashed | re-flash and **md5-verify the readback** every time |
| `ls (hd0)/` shows `mach_kernel`, `*.squashfs` | stick still has the ISO, not your image | re-flash with the `.img` |

## License / credits

Built from a real MacPro6,1 PVE9 ZFS-root rebuild. Adapt freely.
**Do not commit secrets**: keep `answer.toml`, password hashes, SSH keys, internal IPs/hostnames out
of the published ISO/image and out of this repo.
