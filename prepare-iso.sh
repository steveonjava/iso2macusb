#!/usr/bin/env bash
#
# prepare-iso.sh — Stage 1 of the pipeline: turn a stock Proxmox VE ISO into a
# prepared *automated-install* ISO with your answer.toml baked in (fully offline,
# embedded-ISO mode by default).
#
# This wraps `proxmox-auto-install-assistant prepare-iso`. The output ISO is then
# fed to iso2macusb.sh (Stage 2) to produce a Mac-bootable FAT32 USB image.
#
# REQUIREMENTS (Debian 13 / Proxmox host or container):
#   - proxmox-auto-install-assistant   (Proxmox repos)
#   - xorriso
#   - whois (for mkpasswd, to generate the root password hash) — optional helper
#
# USAGE:
#   ./prepare-iso.sh -i proxmox-ve_9.x.iso -a answer.toml -o proxmox-auto.iso
#   ./prepare-iso.sh -i in.iso -a answer.toml -o out.iso --fetch-from http --url https://host/answer
#
# DEFAULT fetch mode = iso (embedded, offline). Recommended for Macs with no
# reliable installer-time NIC. Use --fetch-from http|partition for other setups.
#
set -euo pipefail

FETCH_FROM="iso"
URL=""
PART_LABEL=""
FIRSTBOOT=""
SRC=""; ANSWER=""; OUT=""

die(){ echo "ERROR: $*" >&2; exit 1; }

check_tools() {
  local tool pkg missing=0
  local -A tool_pkgs=(
    [proxmox-auto-install-assistant]="proxmox-auto-install-assistant"
    [xorriso]="xorriso"
  )
  for tool in proxmox-auto-install-assistant xorriso; do
    if ! command -v "$tool" >/dev/null 2>&1; then
      pkg="${tool_pkgs[$tool]}"
      echo "ERROR: missing required tool: $tool. Install: apt-get install $pkg" >&2
      missing=1
    fi
  done
  [[ $missing -eq 0 ]] || exit 1
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -i|--iso) SRC="$2"; shift 2;;
    -a|--answer) ANSWER="$2"; shift 2;;
    -o|--out) OUT="$2"; shift 2;;
    --fetch-from) FETCH_FROM="$2"; shift 2;;
    --url) URL="$2"; shift 2;;
    --partition-label) PART_LABEL="$2"; shift 2;;
    --first-boot) FIRSTBOOT="$2"; shift 2;;
    -h|--help) grep '^#' "$0" | sed 's/^# \{0,1\}//'; exit 0;;
    *) die "unknown arg: $1";;
  esac
done

[[ -n "$SRC" && -f "$SRC" ]] || die "give a valid source Proxmox ISO with -i"
[[ -n "$OUT" ]] || die "give an output path with -o"
check_tools

ARGS=(prepare-iso "$SRC" --fetch-from "$FETCH_FROM" --output "$OUT")

case "$FETCH_FROM" in
  iso)
    [[ -n "$ANSWER" && -f "$ANSWER" ]] || die "--fetch-from iso requires -a <answer.toml>"
    echo "== validating answer file =="
    proxmox-auto-install-assistant validate-answer "$ANSWER"
    ARGS+=(--answer-file "$ANSWER")
    ;;
  http)
    [[ -n "$URL" ]] || echo "note: no --url given; installer will use DHCP opt 250 / DNS TXT"
    [[ -n "$URL" ]] && ARGS+=(--url "$URL")
    ;;
  partition)
    [[ -n "$PART_LABEL" ]] && ARGS+=(--partition-label "$PART_LABEL")
    ;;
  *) die "invalid --fetch-from: $FETCH_FROM (iso|http|partition)";;
esac

[[ -n "$FIRSTBOOT" ]] && ARGS+=(--on-first-boot "$FIRSTBOOT")

echo "== preparing ISO =="
echo "  proxmox-auto-install-assistant ${ARGS[*]}"
proxmox-auto-install-assistant "${ARGS[@]}"

echo "== verifying prepared ISO =="
proxmox-auto-install-assistant inspect-iso "$OUT" || true
sha256sum "$OUT"
echo
echo "NEXT: convert to a Mac-bootable USB image:"
echo "  sudo ./iso2macusb.sh -i $OUT -o ${OUT%.iso}-macusb.img"
