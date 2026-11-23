#!/bin/sh
# =============================================================================
# fix-wifi.sh  -  make Wi-Fi work on the HP OmniBook 3 14-hz0 (Snapdragon X Plus)
# =============================================================================
#
# THE PROBLEM, IN PLAIN WORDS
#   The Wi-Fi chip (a Qualcomm WCN6855, driver name "ath11k") needs a small
#   settings file called "board data" before it will turn on. Linux keeps the
#   board data for many laptops packed together in ONE file:
#
#       /lib/firmware/ath11k/WCN6855/hw2.1/board-2.bin
#
#   Inside, each laptop's settings are labelled with an ID. When the driver
#   starts, it looks for the label that matches this laptop:
#
#       ...subsystem-vendor=103c,subsystem-device=8d9a...   (103c = HP)
#
#   That label isn't in the file, so the driver gives up and Wi-Fi never
#   appears.
#
# THE FIX
#   Make a copy of board-2.bin and add HP's label to an EXISTING set of
#   settings: the generic one for this chip (Windows uses the same settings
#   for this laptop). Nothing is invented. The same settings just get a second
#   name tag.
#
# WHERE THE COPY GOES (why this is safe)
#   Linux checks /lib/firmware/updates/ BEFORE /lib/firmware/. So the edited
#   copy goes in:
#
#       /lib/firmware/updates/ath11k/WCN6855/hw2.1/board-2.bin
#
#   The original file from your distro is never changed. To undo, delete that
#   one copy (run this script with --undo).
#
# HOW TO USE
#   ./fix-wifi.sh              Preview only. Shows what it WOULD do. Changes nothing.
#   sudo ./fix-wifi.sh --apply Actually does it.
#   sudo ./fix-wifi.sh --undo  Removes the copy this script added.
#   Add --rebuild-initramfs to --apply or --undo if the script tells you your
#   initramfs (the starter system in /boot) carries Wi-Fi firmware. Without
#   a rebuild, the driver keeps reading the OLD copy packed inside it.
#   Then REBOOT. (Don't unload and reload the Wi-Fi driver by hand with
#   modprobe. On this laptop that has crashed the Wi-Fi chip before.)
#
# WHAT IT NEEDS
#   python3 and git (only to download Qualcomm's free "ath11k-bdencoder" tool,
#   which can unpack and repack board-2.bin). If the clock is wrong, the
#   download fails: fix with  sudo timedatectl set-ntp true
#
# OPTIONS (you rarely need these)
#   --bdencoder PATH   Use an ath11k-bdencoder you already downloaded (no git needed).
#   FW_DIR=/some/dir   Use a different firmware folder (used for testing).
# =============================================================================

# Stop at the first error (-e) and treat unset variables as errors (-u).
set -eu

# ---- Settings ---------------------------------------------------------------

# The label the driver asks for on THIS laptop. If yours is different, it is
# printed in the error from:  sudo dmesg | grep -i 'board data'
NEW_NAME="bus=pci,vendor=17cb,device=1103,subsystem-vendor=103c,subsystem-device=8d9a,qmi-chip-id=18,qmi-board-id=255"

# The existing label whose settings we reuse: the chip's generic entry.
SOURCE_NAME="bus=pci,vendor=17cb,device=1103,subsystem-vendor=105b,subsystem-device=e105,qmi-chip-id=18,qmi-board-id=255"

# Where Qualcomm's free tools live.
TOOLS_URL="https://github.com/qca/qca-swiss-army-knife.git"

# Firmware folder: Fedora/Arch use /usr/lib/firmware, Debian/Ubuntu /lib/firmware
# (on most systems today they are the same folder).
if [ -z "${FW_DIR:-}" ]; then
  if [ -d /lib/firmware ]; then FW_DIR=/lib/firmware; else FW_DIR=/usr/lib/firmware; fi
fi

ORIGINAL_DIR="$FW_DIR/ath11k/WCN6855/hw2.1"            # distro's copy (read only)
OUR_DIR="$FW_DIR/updates/ath11k/WCN6855/hw2.1"         # where our copy goes
OUR_FILE="$OUR_DIR/board-2.bin"

# ---- Small helpers ------------------------------------------------------------

say()  { printf '==> %s\n' "$*"; }           # a step heading
info() { printf '    %s\n' "$*"; }           # extra detail
die()  { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
have() { command -v "$1" >/dev/null 2>&1; } # "is this program installed?"

# Print a firmware file's contents, unpacking it first if it is compressed
# (distros often ship board-2.bin.zst or board-2.bin.xz).
read_firmware() {
  case $1 in
    *.zst) zstd -dc "$1" ;;
    *.xz)  xz -dc "$1" ;;
    *)     cat "$1" ;;
  esac
}

# ---- Read the command line ------------------------------------------------------

MODE=preview
BDENCODER=""
REBUILD=no
while [ $# -gt 0 ]; do
  case $1 in
    --apply) MODE=apply ;;
    --undo)  MODE=undo ;;
    --bdencoder) [ $# -ge 2 ] || die "--bdencoder needs a path"; BDENCODER=$2; shift ;;
    --rebuild-initramfs) REBUILD=yes ;;
    # Print the comment block at the top of this file (every line starting
    # with "#", stopping at the first line that doesn't).
    -h|--help) awk 'NR>1 && /^#/ {sub(/^# ?/, ""); print; next} NR>1 {exit}' "$0"; exit 0 ;;
    *) die "unknown option: $1  (try --help)" ;;
  esac
  shift
done

# Changing /lib/firmware needs administrator rights.
if [ "$MODE" != preview ] && [ "$(id -u)" != 0 ]; then
  die "run with sudo for --apply or --undo"
fi

# ---- The initramfs ------------------------------------------------------------
# The initramfs is a small starter system in /boot that loads drivers before
# your main disk is ready. If it carries its own copy of board-2.bin, the
# Wi-Fi driver reads THAT copy and never sees the fixed one on disk. So after
# changing the firmware, the initramfs has to be rebuilt.

KVER=$(uname -r)                                   # the kernel you're running now
WIFI_FW_PATH="ath11k/WCN6855/hw2.1/board-2.bin"

# Work out which kind of initramfs this system uses. There are two common styles:
#   Ubuntu / Debian: /boot/initrd.img-<version>, built by update-initramfs,
#                    looked inside with lsinitramfs
#   Fedora / dracut: /boot/initramfs-<version>.img, built by dracut,
#                    looked inside with lsinitrd
if [ -f "/boot/initrd.img-$KVER" ] && have update-initramfs; then
  STYLE=ubuntu; IMG="/boot/initrd.img-$KVER"; LISTER=lsinitramfs
elif [ -f "/boot/initramfs-$KVER.img" ] && have dracut; then
  STYLE=dracut; IMG="/boot/initramfs-$KVER.img"; LISTER=lsinitrd
else
  STYLE=unknown; IMG="(not found)"; LISTER=""
fi

# Answers "does the initramfs carry Wi-Fi firmware?" with yes / no / unknown.
# The LISTER program prints the list of files inside the initramfs. Read only.
initramfs_has_wifi_fw() {
  if [ "$STYLE" = unknown ] || ! have "$LISTER"; then echo unknown; return; fi
  if "$LISTER" "$IMG" 2>/dev/null | grep -q "$WIFI_FW_PATH"; then echo yes; else echo no; fi
}

# Rebuild the initramfs so it packs the current firmware files.
#   $1 = "present" after --apply (fixed file should be inside)
#        "absent"  after --undo  (fixed file should be gone)
rebuild_initramfs() {
  if [ "$STYLE" = ubuntu ]; then rebuild_ubuntu "$1"; return; fi
  rebuild_dracut "$1"
}

# Ubuntu: keep a backup copy, then run Ubuntu's own update-initramfs, the
# normal command Ubuntu itself runs after updates. If it fails, put the
# backup back.
rebuild_ubuntu() {
  say "Rebuilding the initramfs (Ubuntu style): $IMG"
  cp -p "$IMG" "$IMG.before-fix-wifi"
  info "backup saved as $IMG.before-fix-wifi"
  if ! update-initramfs -u -k "$KVER"; then
    cp -p "$IMG.before-fix-wifi" "$IMG"
    die "update-initramfs failed, so the backup was put back. Nothing changed."
  fi
  if lsinitramfs "$IMG" | grep -q "updates/$WIFI_FW_PATH"; then inside=present; else inside=absent; fi
  [ "$inside" = "$1" ] || info "WARNING: expected the fixed Wi-Fi file to be $1 in the new initramfs, but it is $inside."
  info "done"
}

# dracut: same way the old omnibook3-setup.sh did it, with extra safety:
# build to a NEW file, check it, keep a backup of the old one, then swap them.
rebuild_dracut() {
  say "Rebuilding the initramfs (dracut style): $IMG"
  # --no-hostonly = include ALL drivers. Without it, your old notes say the
  # boot hung because the disk driver was left out. Don't remove it.
  dracut -f --no-hostonly --kver "$KVER" "$IMG.new"
  # Safety check 1: the disk driver (nvme) must be inside, or the laptop
  # can't find its disk at boot. If missing, stop and keep the old file.
  if ! lsinitrd "$IMG.new" | grep -q nvme; then
    rm -f "$IMG.new"
    die "the new initramfs has no disk (nvme) driver, so it was NOT installed. Your old one is unchanged."
  fi
  # Check 2: is our fixed Wi-Fi file inside (or gone, after --undo)?
  if lsinitrd "$IMG.new" | grep -q "updates/$WIFI_FW_PATH"; then inside=present; else inside=absent; fi
  [ "$inside" = "$1" ] || info "WARNING: expected the fixed Wi-Fi file to be $1 in the new initramfs, but it is $inside."
  cp -p "$IMG" "$IMG.before-fix-wifi"          # backup of the old one
  mv "$IMG.new" "$IMG"
  info "done. The old initramfs is saved as $IMG.before-fix-wifi"
  info "(if the laptop won't boot, pick another kernel in the boot menu and copy that file back)"
}

# Decide what to do about the initramfs, after --apply or --undo.
handle_initramfs() {
  state=$(initramfs_has_wifi_fw)
  case $state in
    yes)
      if [ "$REBUILD" = yes ]; then
        rebuild_initramfs "$1"
      else
        say "IMPORTANT: your initramfs carries its own copy of the Wi-Fi firmware."
        info "Until it's rebuilt, the change won't take effect. Either run this script"
        info "again with --rebuild-initramfs, or run this yourself:"
        if [ "$STYLE" = ubuntu ]; then
          info "  sudo update-initramfs -u -k $KVER"
        else
          info "  sudo dracut -f --no-hostonly --kver $KVER $IMG"
        fi
      fi ;;
    no)
      info "your initramfs ($IMG) has no Wi-Fi firmware, so it doesn't need rebuilding" ;;
    unknown)
      info "couldn't find or check your initramfs for kernel $KVER."
      info "If Wi-Fi still fails after a reboot, rebuild it with your distro's tool:"
      info "  dracut: sudo dracut -f --no-hostonly    Arch: sudo mkinitcpio -P"
      info "  Debian/Ubuntu: sudo update-initramfs -u" ;;
  esac
}

# ---- Undo -----------------------------------------------------------------------

if [ "$MODE" = undo ]; then
  if [ -f "$OUR_FILE" ]; then
    rm -f "$OUR_FILE"
    # Remove the folders we made, only if they are now empty.
    rmdir -p "$OUR_DIR" 2>/dev/null || true
    say "Removed $OUR_FILE."
    handle_initramfs absent
    say "Reboot to go back to the original."
  else
    say "Nothing to undo: $OUR_FILE does not exist."
  fi
  exit 0
fi

# ---- Step 1: find the distro's board-2.bin ------------------------------------------

say "Step 1: find the original board-2.bin"
ORIGINAL=""
for f in "$ORIGINAL_DIR/board-2.bin" "$ORIGINAL_DIR/board-2.bin.zst" "$ORIGINAL_DIR/board-2.bin.xz"; do
  if [ -f "$f" ]; then ORIGINAL=$f; break; fi
done
[ -n "$ORIGINAL" ] || die "no board-2.bin in $ORIGINAL_DIR. Install your distro's linux-firmware package first."
info "found $ORIGINAL"

# If your distro has already added HP's label, nothing needs doing.
if read_firmware "$ORIGINAL" | grep -qaF "$NEW_NAME"; then
  say "Your distro's board-2.bin already knows this laptop. Nothing to do."
  if [ -f "$OUR_FILE" ]; then
    info "Our old copy at $OUR_FILE is no longer needed: run  sudo $0 --undo"
  fi
  exit 0
fi
info "it does NOT contain this laptop's label yet, so the fix is needed"

if [ "$MODE" = preview ]; then
  say "Preview only. With --apply this script would:"
  info "1. download Qualcomm's ath11k-bdencoder tool into a temporary folder"
  info "2. unpack a COPY of $ORIGINAL"
  info "3. add this laptop's label to the generic WCN6855 settings"
  info "4. repack it and check the label is really there"
  info "5. save it as $OUR_FILE"
  info "Your original file is never changed."
  case $(initramfs_has_wifi_fw) in
    yes) info "6. NOTE: your initramfs ($IMG) carries Wi-Fi firmware, so it must be"
         info "   rebuilt too. Add --rebuild-initramfs to have this script do it." ;;
    no)  info "6. your initramfs has no Wi-Fi firmware, so no rebuild is needed" ;;
    *)   info "6. couldn't check your initramfs; the script will tell you what to do" ;;
  esac
  exit 0
fi

# Everything from here on happens in a temporary folder that is deleted at the end.
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT INT TERM

# ---- Step 2: get the unpack/repack tool ----------------------------------------------

say "Step 2: get ath11k-bdencoder (Qualcomm's tool for board-2.bin)"
have python3 || die "python3 is needed"
if [ -n "$BDENCODER" ]; then
  [ -f "$BDENCODER" ] || die "not found: $BDENCODER"
elif have ath11k-bdencoder; then
  BDENCODER=$(command -v ath11k-bdencoder)
else
  have git || die "git is needed to download the tool (or use --bdencoder PATH)"
  git clone --quiet --depth 1 "$TOOLS_URL" "$WORK/tools" \
    || die "download failed. Check the internet connection and the clock (sudo timedatectl set-ntp true)."
  BDENCODER="$WORK/tools/tools/scripts/ath11k/ath11k-bdencoder"
fi
info "using $BDENCODER"

# ---- Step 3: unpack a copy ----------------------------------------------------------
# "-e" (extract) turns board-2.bin into board-2.json (the list of labels) plus
# one small file per set of settings.

say "Step 3: unpack a copy of board-2.bin"
read_firmware "$ORIGINAL" > "$WORK/original.bin"
mkdir "$WORK/unpacked"
( cd "$WORK/unpacked" && python3 "$BDENCODER" -e "$WORK/original.bin" >/dev/null )
[ -f "$WORK/unpacked/board-2.json" ] || die "unpacking failed (no board-2.json)"

# ---- Step 4: add HP's label ---------------------------------------------------------
# board-2.json looks like:  {"board": [ {"names": ["label A", ...], "data": "file"}, ... ]}
# This small Python program finds the entry whose "names" list contains the
# generic label and adds HP's label next to it. It prints how many it changed.

say "Step 4: add this laptop's label to the generic settings"
CHANGED=$(python3 - "$WORK/unpacked/board-2.json" "$SOURCE_NAME" "$NEW_NAME" <<'PYTHON'
import json, sys
path, source_name, new_name = sys.argv[1], sys.argv[2], sys.argv[3]
with open(path) as f:
    data = json.load(f)
changed = 0
sections = data if isinstance(data, list) else [data]   # a list of sections (or just one)
for section in sections:
    for entry in section.get("board", []):
        names = entry.get("names", [])
        if source_name in names and new_name not in names:
            names.append(new_name)       # same settings, one more name tag
            changed += 1
with open(path, "w") as f:
    json.dump(data, f, indent=2)
print(changed)
PYTHON
)
if [ "$CHANGED" = 0 ]; then
  info "The generic label was not found. Labels for this chip that DO exist:"
  grep -o 'bus=pci[^"]*qmi-chip-id=18,qmi-board-id=255[^"]*' "$WORK/unpacked/board-2.json" | sort -u | head -20
  die "edit SOURCE_NAME near the top of this script to one of those and try again"
fi
info "added the label to $CHANGED entry"

# ---- Step 5: repack and double-check ------------------------------------------------------
# "-c" (create) packs the folder back into one board-2.bin. Then we unpack the
# new file again and make sure HP's label really made it in.

say "Step 5: repack and check"
( cd "$WORK/unpacked" && python3 "$BDENCODER" -c board-2.json -o "$WORK/new.bin" >/dev/null )
[ -s "$WORK/new.bin" ] || die "repacking produced an empty file"
mkdir "$WORK/check"
( cd "$WORK/check" && python3 "$BDENCODER" -e "$WORK/new.bin" >/dev/null )
grep -qF "$NEW_NAME" "$WORK/check/board-2.json" || die "check failed: label missing from the new file"
info "check passed"

# ---- Step 6: install the copy ---------------------------------------------------------------

say "Step 6: save the new copy"
mkdir -p "$OUR_DIR"
install -m 644 "$WORK/new.bin" "$OUR_FILE"   # copy with permissions rw-r--r--
info "saved $OUR_FILE"

# ---- Step 7: the initramfs ------------------------------------------------------------------

say "Step 7: check the initramfs (the starter system in /boot)"
handle_initramfs present

say "Done. Reboot, then check Wi-Fi with:  nmcli device wifi list"
info "If it still fails:  sudo dmesg | grep -i ath11k"
info "If a future linux-firmware update adds this laptop itself, this script"
info "will say so. Then remove the copy with:  sudo $0 --undo"
