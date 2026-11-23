#!/bin/sh
# =============================================================================
# omisetup-all.sh - Wi-Fi + sound for the HP OmniBook 3 14-hz0 (Snapdragon X Plus)
# =============================================================================
#
# WHAT THIS DOES
#   One script that makes Wi-Fi and sound work on the HP OmniBook 3 Laptop
#   14-hz0xxx (Qualcomm X1P42100) in Linux, on any common distro:
#   Ubuntu/Debian, Fedora, Arch, openSUSE and their relatives.
#
#   It assumes Linux already BOOTS on the laptop (kernel + device tree set up).
#
# HOW TO USE
#   ./omisetup-all.sh                  Preview: checks everything, changes nothing.
#   sudo ./omisetup-all.sh --deps      Install the tools it needs (git, python3,
#                                      m4, alsa-utils, zstd, xz) with your
#                                      distro's package manager.
#   sudo ./omisetup-all.sh --apply     Fix Wi-Fi and sound. Then reboot.
#   ./omisetup-all.sh --status         After the reboot: is it working? (read only)
#   sudo ./omisetup-all.sh --undo      Remove everything this script added.
#
#   Extra options:
#     --only wifi | --only audio   Do just one part.
#     --legacy-audio               Old sound setup (Surface Laptop 7 diagram +
#                                  ThinkPad T14s recipe) instead of the IdeaPad one.
#     --no-initramfs               Don't rebuild the starter system in /boot.
#
# WHAT IT CHANGES (and nothing else)
#   /lib/firmware/updates/ath11k/WCN6855/hw2.1/board-2.bin              Wi-Fi
#   /lib/firmware/updates/qcom/x1e80100/X1E80100-HP-OMNIBOOK-3-tplg.bin sound
#   /usr/share/alsa/ucm2/Qualcomm/x1e80100/HP-OmniBook3.conf            sound
#   /usr/share/alsa/ucm2/Qualcomm/x1e80100/HP-OmniBook3-HiFi.conf       sound
#   /usr/share/alsa/ucm2/conf.d/x1e80100/<sound card name>.conf         sound (shortcut)
#   the initramfs in /boot, ONLY if it carries Wi-Fi firmware (backup kept)
#   Your distro's own files are never edited. Linux checks
#   /lib/firmware/updates/ before /lib/firmware/, so the copies win.
#
# !!  SPEAKER SAFETY  !!
#   Keep speaker volume at about half until you know it sounds clean.
#
# The full plain-language explanation is in README.md next to this script.
# =============================================================================

set -eu   # stop at the first error (-e); treat unset variables as errors (-u)

# ============================ SETTINGS =======================================

# --- Wi-Fi ---
# The label the Wi-Fi driver looks for on THIS laptop (103c = HP).
WIFI_NEW_NAME="bus=pci,vendor=17cb,device=1103,subsystem-vendor=103c,subsystem-device=8d9a,qmi-chip-id=18,qmi-board-id=255"
# The chip's generic label, whose settings get reused (same as Windows uses).
WIFI_SOURCE_NAME="bus=pci,vendor=17cb,device=1103,subsystem-vendor=105b,subsystem-device=e105,qmi-chip-id=18,qmi-board-id=255"
WIFI_FW_PATH="ath11k/WCN6855/hw2.1/board-2.bin"
QCA_TOOLS_URL="https://github.com/qca/qca-swiss-army-knife.git"

# --- Sound --- (pinned = exact versions that were reviewed and tested)
TOPO_URL="https://github.com/jglathe/audioreach-topology.git"
TOPO_COMMIT="a737c27fcd1339698efa72e77c6cd4682d69d9e1"   # IdeaPad Slim 3 topology
TOPO_SOURCE="X1E80100-LENOVO-Ideapad-3.m4"
UCM_URL="https://github.com/jglathe/alsa-ucm-conf.git"
UCM_COMMIT="6e1a6d7aafb431b055c3af8596e170e4f06afe52"    # IdeaPad Slim 3 recipe
TPLG_NAME="X1E80100-HP-OMNIBOOK-3-tplg.bin"              # the name Linux asks for
LEGACY_TPLG="X1E80100-Romulus-tplg.bin"
LEGACY_TARGET="../../Qualcomm/x1e80100/LENOVO-T14s.conf"
OUR_RECIPE="HP-OmniBook3.conf"
OUR_RECIPE_HIFI="HP-OmniBook3-HiFi.conf"
OUR_TARGET="../../Qualcomm/x1e80100/$OUR_RECIPE"
DEFAULT_LONGNAME="HP-HPOmniBook3Laptop14_hz0xxx-ConfigID-8EF1"

# --- Folders --- (FW_DIR / UCM_DIR can be overridden for testing)
if [ -z "${FW_DIR:-}" ]; then
  if [ -d /lib/firmware ]; then FW_DIR=/lib/firmware; else FW_DIR=/usr/lib/firmware; fi
fi
UCM_DIR=${UCM_DIR:-/usr/share/alsa/ucm2}
WIFI_DISTRO_DIR="$FW_DIR/ath11k/WCN6855/hw2.1"
WIFI_OUR_DIR="$FW_DIR/updates/ath11k/WCN6855/hw2.1"
WIFI_OUR_FILE="$WIFI_OUR_DIR/board-2.bin"
TPLG_DISTRO_DIR="$FW_DIR/qcom/x1e80100"
TPLG_OUR_DIR="$FW_DIR/updates/qcom/x1e80100"
TPLG_OUR_FILE="$TPLG_OUR_DIR/$TPLG_NAME"
RECIPE_DIR="$UCM_DIR/Qualcomm/x1e80100"
UCM_LINK_DIR="$UCM_DIR/conf.d/x1e80100"
BACKUP_SUFFIX=".before-omisetup"

# ============================ HELPERS ========================================

say()  { printf '\n==> %s\n' "$*"; }        # a step heading
info() { printf '    %s\n' "$*"; }          # a detail line
warn() { printf '    WARNING: %s\n' "$*"; }
die()  { printf '\nERROR: %s\n' "$*" >&2; exit 1; }
have() { command -v "$1" >/dev/null 2>&1; } # "is this program installed?"

# Print a firmware file's contents, unpacking .zst/.xz. The "<" feeds the
# contents in, so distros that ship these files as shortcuts (symlinks),
# like Ubuntu, work too. Given a shortcut by name, zstd refuses it.
read_firmware() {
  case $1 in
    *.zst) zstd -dc < "$1" ;;
    *.xz)  xz -dc < "$1" ;;
    *)     cat "$1" ;;
  esac
}

# Find a firmware file whether it's shipped plain, .zst or .xz.
find_firmware() {
  for f in "$1" "$1.zst" "$1.xz"; do
    if [ -f "$f" ]; then printf '%s\n' "$f"; return 0; fi
  done
  return 1
}

# Download one exact version (commit) of a git repository into a folder.
fetch_pinned() {  # $1 = url, $2 = commit, $3 = folder
  git init -q "$3"
  git -C "$3" fetch -q --depth 1 "$1" "$2" \
    || die "download of $1 failed. Check the internet and the clock (sudo timedatectl set-ntp true)."
  git -C "$3" checkout -q FETCH_HEAD
}

# The sound card's long name from /proc/asound/cards (the line after "x1e80100 - ").
card_longname() {
  if [ -n "${CARD_LONGNAME:-}" ]; then printf '%s\n' "$CARD_LONGNAME"; return; fi
  name=""
  if [ -r /proc/asound/cards ]; then
    name=$(awk '/x1e80100 - /{getline; gsub(/^[ \t]+|[ \t]+$/, ""); print; exit}' /proc/asound/cards)
  fi
  [ -n "$name" ] || name=$DEFAULT_LONGNAME
  printf '%s\n' "$name"
}

# ============================ COMMAND LINE ===================================

MODE=preview      # preview | apply | undo | status | deps
ONLY=both         # both | wifi | audio
AUDIO_WAY=ips3    # ips3 | legacy
INITRAMFS=yes     # yes | no
while [ $# -gt 0 ]; do
  case $1 in
    --apply)  MODE=apply ;;
    --undo)   MODE=undo ;;
    --status) MODE=status ;;
    --deps)   MODE=deps ;;
    --only)   [ $# -ge 2 ] || die "--only needs 'wifi' or 'audio'"
              case $2 in wifi|audio) ONLY=$2 ;; *) die "--only needs 'wifi' or 'audio'" ;; esac
              shift ;;
    --legacy-audio) AUDIO_WAY=legacy ;;
    --no-initramfs) INITRAMFS=no ;;
    -h|--help) awk 'NR>1 && /^#/ {sub(/^# ?/, ""); print; next} NR>1 {exit}' "$0"; exit 0 ;;
    *) die "unknown option: $1  (try --help)" ;;
  esac
  shift
done
do_wifi()  { [ "$ONLY" = both ] || [ "$ONLY" = wifi ]; }
do_audio() { [ "$ONLY" = both ] || [ "$ONLY" = audio ]; }

case $MODE in apply|undo|deps)
  [ "$(id -u)" = 0 ] || die "run with sudo for --$MODE" ;;
esac

LONGNAME=$(card_longname)
UCM_LINK="$UCM_LINK_DIR/$LONGNAME.conf"
if [ "$AUDIO_WAY" = ips3 ]; then UCM_TARGET=$OUR_TARGET; else UCM_TARGET=$LEGACY_TARGET; fi

# Is the sound shortcut one this script (or the older scripts) made?
link_is_ours() {
  [ -L "$UCM_LINK" ] || return 1
  case $(readlink "$UCM_LINK") in
    "$OUR_TARGET"|"$LEGACY_TARGET") return 0 ;;
    *) return 1 ;;
  esac
}

# ============================ WHICH DISTRO? ==================================
# Package manager: used only by --deps, and to suggest commands.
if   have apt-get; then PKG=apt
elif have dnf;     then PKG=dnf
elif have pacman;  then PKG=pacman
elif have zypper;  then PKG=zypper
else                    PKG=unknown
fi

deps_command() {
  case $PKG in
    apt)    echo "apt-get install -y git python3 m4 alsa-utils zstd xz-utils" ;;
    dnf)    echo "dnf install -y git python3 m4 alsa-utils zstd xz" ;;
    pacman) echo "pacman -S --needed --noconfirm git python m4 alsa-utils zstd xz" ;;
    zypper) echo "zypper --non-interactive install git python3 m4 alsa-utils zstd xz" ;;
    *)      echo "" ;;
  esac
}

# Initramfs style: the starter system in /boot that loads drivers before
# the main disk is ready. Each distro family builds it with its own tool:
#   ubuntu   - Ubuntu/Debian: /boot/initrd.img-<ver>, update-initramfs, lsinitramfs
#   dracut   - Fedora/openSUSE/others: /boot/initramfs-<ver>.img or /boot/initrd-<ver>, dracut, lsinitrd
#   mkinitcpio - Arch: /boot/initramfs-linux*.img, mkinitcpio, lsinitcpio
KVER=$(uname -r)
IMG=""; STYLE=unknown
if [ -f "/boot/initrd.img-$KVER" ] && have update-initramfs; then
  STYLE=ubuntu; IMG="/boot/initrd.img-$KVER"
elif have dracut && [ -f "/boot/initramfs-$KVER.img" ]; then
  STYLE=dracut; IMG="/boot/initramfs-$KVER.img"
elif have dracut && [ -f "/boot/initrd-$KVER" ]; then
  STYLE=dracut; IMG="/boot/initrd-$KVER"
elif have mkinitcpio && have lsinitcpio; then
  STYLE=mkinitcpio   # Arch names images by preset, so all of them are checked
fi

# List the files inside one initramfs image (read only).
list_initramfs() {
  case $STYLE in
    ubuntu)     lsinitramfs "$1" 2>/dev/null ;;
    dracut)     lsinitrd "$1" 2>/dev/null ;;
    mkinitcpio) lsinitcpio "$1" 2>/dev/null ;;
  esac
}

# The image(s) to check: one for ubuntu/dracut, every non-fallback one for Arch.
initramfs_images() {
  if [ "$STYLE" = mkinitcpio ]; then
    for i in /boot/initramfs-*.img; do
      case $i in *fallback*) ;; *) [ -f "$i" ] && printf '%s\n' "$i" ;; esac
    done
  elif [ -n "$IMG" ]; then
    printf '%s\n' "$IMG"
  fi
}

# yes / no / unknown: does the initramfs carry its own copy of the Wi-Fi firmware?
initramfs_has_wifi_fw() {
  [ "$STYLE" != unknown ] || { echo unknown; return; }
  images=$(initramfs_images)
  [ -n "$images" ] || { echo unknown; return; }
  for i in $images; do
    if list_initramfs "$i" | grep -q "$WIFI_FW_PATH"; then echo yes; return; fi
  done
  echo no
}

rebuild_command() {
  case $STYLE in
    ubuntu)     echo "update-initramfs -u -k $KVER" ;;
    dracut)     echo "dracut -f --no-hostonly --kver $KVER $IMG" ;;
    mkinitcpio) echo "mkinitcpio -P" ;;
    *)          echo "(your distro's initramfs tool)" ;;
  esac
}

# Rebuild the initramfs so it carries the current firmware. Always keeps a
# backup of each image first, and puts it back if the rebuild fails.
rebuild_initramfs() {
  say "Rebuilding the initramfs ($STYLE style)"
  images=$(initramfs_images)
  for i in $images; do cp -p "$i" "$i$BACKUP_SUFFIX"; info "backup: $i$BACKUP_SUFFIX"; done
  restore() { for i in $images; do cp -p "$i$BACKUP_SUFFIX" "$i"; done; }
  case $STYLE in
    ubuntu)
      update-initramfs -u -k "$KVER" || { restore; die "update-initramfs failed; backup put back."; } ;;
    dracut)
      # --no-hostonly = include ALL drivers, so the disk driver can't be left out.
      dracut -f --no-hostonly --kver "$KVER" "$IMG.new" || { rm -f "$IMG.new"; die "dracut failed; nothing changed."; }
      # Safety: the disk (nvme) driver must be inside, or the laptop can't boot.
      if ! lsinitrd "$IMG.new" | grep -q nvme; then
        rm -f "$IMG.new"; die "new initramfs has no disk (nvme) driver, so it was NOT installed."
      fi
      mv "$IMG.new" "$IMG" ;;
    mkinitcpio)
      mkinitcpio -P || { restore; die "mkinitcpio failed; backup put back."; } ;;
  esac
  info "done. If the laptop won't boot, pick another kernel in the boot menu and"
  info "copy the $BACKUP_SUFFIX file back over the image."
}

# After Wi-Fi firmware changes: rebuild the initramfs if it carries a copy.
handle_initramfs() {
  case $(initramfs_has_wifi_fw) in
    yes)
      if [ "$INITRAMFS" = yes ]; then rebuild_initramfs
      else warn "your initramfs carries Wi-Fi firmware; run:  sudo $(rebuild_command)"; fi ;;
    no)  info "initramfs has no Wi-Fi firmware, so no rebuild needed" ;;
    *)   info "couldn't check the initramfs. If Wi-Fi fails after reboot, run:"
         info "  sudo $(rebuild_command)" ;;
  esac
}

# ============================ --deps =========================================

if [ "$MODE" = deps ]; then
  cmd=$(deps_command)
  [ -n "$cmd" ] || die "unknown package manager. Install by hand: git python3 m4 alsa-utils zstd xz"
  say "Installing tools with $PKG:  $cmd"
  # $cmd is split into words on purpose (it holds a whole command line).
  # shellcheck disable=SC2086
  $cmd
  have alsatplg || warn "alsatplg still missing. On some distros it's in a separate package (e.g. alsa-topology-utils / alsa-utils-topology)."
  say "Done. Next:  ./omisetup-all.sh   (preview)"
  exit 0
fi

# ============================ --status (read only) ===========================

if [ "$MODE" = status ]; then
  say "Wi-Fi"
  if [ -f "$WIFI_OUR_FILE" ]; then info "fixed board-2.bin installed"; else info "fixed board-2.bin NOT installed"; fi
  if ls /sys/class/net/*/wireless >/dev/null 2>&1; then
    info "Wi-Fi device present: $(basename "$(dirname "$(ls -d /sys/class/net/*/wireless | head -1)")")  -> WORKING"
  else
    info "no Wi-Fi device. Details:  sudo dmesg | grep -i ath11k"
  fi
  say "Sound"
  if [ -f "$TPLG_OUR_FILE" ]; then info "wiring diagram installed"; else info "wiring diagram NOT installed"; fi
  if [ -L "$UCM_LINK" ]; then info "recipe shortcut -> $(readlink "$UCM_LINK")"; else info "no recipe shortcut"; fi
  if grep -q x1e80100 /proc/asound/cards 2>/dev/null; then
    info "sound card present -> WORKING (check outputs with: wpctl status)"
  else
    info "no sound card. Details:  sudo dmesg | grep -iE 'tplg|q6apm|snd'"
  fi
  exit 0
fi

# ============================ --undo =========================================

if [ "$MODE" = undo ]; then
  if do_wifi && [ -f "$WIFI_OUR_FILE" ]; then
    rm -f "$WIFI_OUR_FILE"; rmdir -p "$WIFI_OUR_DIR" 2>/dev/null || true
    say "Removed $WIFI_OUR_FILE"
    handle_initramfs
  fi
  if do_audio; then
    if [ -f "$TPLG_OUR_FILE" ]; then
      rm -f "$TPLG_OUR_FILE"; rmdir -p "$TPLG_OUR_DIR" 2>/dev/null || true
      say "Removed $TPLG_OUR_FILE"
    fi
    for f in "$RECIPE_DIR/$OUR_RECIPE" "$RECIPE_DIR/$OUR_RECIPE_HIFI"; do
      if [ -f "$f" ]; then rm -f "$f"; say "Removed $f"; fi
    done
    if link_is_ours; then rm -f "$UCM_LINK"; say "Removed $UCM_LINK"; fi
  fi
  say "Undo finished. Reboot."
  exit 0
fi

# ============================ CHECKS (preview + apply) =======================

say "Checks"
info "kernel: $KVER   package manager: $PKG   initramfs style: $STYLE ${IMG:+($IMG)}"
missing=""
need() { have "$1" || missing="$missing $1"; }
if do_wifi; then need git; need python3; fi
if do_audio && [ "$AUDIO_WAY" = ips3 ]; then need git; need m4; need alsatplg; fi

WIFI_TODO=no
WIFI_ORIGINAL=""
if do_wifi; then
  WIFI_ORIGINAL=$(find_firmware "$WIFI_DISTRO_DIR/board-2.bin") \
    || die "no board-2.bin in $WIFI_DISTRO_DIR. Install your distro's linux-firmware (or linux-firmware-qcom / linux-firmware-atheros) package."
  case $WIFI_ORIGINAL in *.zst) need zstd ;; *.xz) need xz ;; esac
fi
if do_audio; then
  [ -d "$TPLG_DISTRO_DIR" ] || die "$TPLG_DISTRO_DIR not found. Install linux-firmware (Qualcomm parts)."
  [ -d "$UCM_LINK_DIR" ]    || die "$UCM_LINK_DIR not found. Install or update alsa-ucm-conf."
  if { [ -e "$UCM_LINK" ] || [ -L "$UCM_LINK" ]; } && ! link_is_ours; then
    die "$UCM_LINK exists and wasn't made by this script. Look at it before going on."
  fi
fi
if [ -n "$missing" ]; then
  die "missing tools:$missing.  Install them with:  sudo $0 --deps   (or: sudo $(deps_command))"
fi
info "all tools found"

if do_wifi; then
  SIZE=$(read_firmware "$WIFI_ORIGINAL" | wc -c)
  [ "$SIZE" -gt 0 ] || die "couldn't read $WIFI_ORIGINAL (came out empty)"
  if read_firmware "$WIFI_ORIGINAL" | grep -qaF "$WIFI_NEW_NAME"; then
    info "Wi-Fi: your distro already knows this laptop, nothing to do"
    [ ! -f "$WIFI_OUR_FILE" ] || info "  (the old fixed copy can go: sudo $0 --undo --only wifi)"
  else
    WIFI_TODO=yes
    info "Wi-Fi: fix needed ($WIFI_ORIGINAL lacks this laptop's label)"
  fi
fi
if do_audio; then info "Sound: will set up the $AUDIO_WAY way; card name: $LONGNAME"; fi

if [ "$MODE" = preview ]; then
  say "Preview only. Nothing was changed. With --apply this script would:"
  if [ "$WIFI_TODO" = yes ]; then
    info "Wi-Fi: unpack a copy of board-2.bin, add this laptop's label to the"
    info "       generic settings, repack, check, save as $WIFI_OUR_FILE"
    case $(initramfs_has_wifi_fw) in
      yes) if [ "$INITRAMFS" = yes ]; then info "       then rebuild the initramfs (it carries Wi-Fi firmware; backup kept)"
           else info "       (your initramfs needs a rebuild, but --no-initramfs was given)"; fi ;;
      no)  info "       (initramfs has no Wi-Fi firmware, no rebuild needed)" ;;
      *)   info "       (couldn't check the initramfs)" ;;
    esac
  fi
  if do_audio; then
    if [ "$AUDIO_WAY" = ips3 ]; then
      info "Sound: download jglathe's IdeaPad Slim 3 diagram + recipe (pinned),"
      info "       build the diagram, save as $TPLG_OUR_FILE,"
      info "       save the recipe as $RECIPE_DIR/$OUR_RECIPE (+ -HiFi)"
    else
      info "Sound: copy the Surface Laptop 7 diagram to $TPLG_OUR_FILE"
    fi
    info "       and point $UCM_LINK -> $UCM_TARGET"
  fi
  info "Run:  sudo $0 --apply"
  exit 0
fi

# Everything below works in a temporary folder that's deleted at the end.
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT INT TERM

# ============================ WI-FI ==========================================

if [ "$WIFI_TODO" = yes ]; then
  say "Wi-Fi 1/4: get Qualcomm's ath11k-bdencoder (unpacks/repacks board-2.bin)"
  if have ath11k-bdencoder; then
    BDENCODER=$(command -v ath11k-bdencoder)
  else
    git clone --quiet --depth 1 "$QCA_TOOLS_URL" "$WORK/qca" \
      || die "download failed. Check the internet and the clock (sudo timedatectl set-ntp true)."
    BDENCODER="$WORK/qca/tools/scripts/ath11k/ath11k-bdencoder"
  fi

  say "Wi-Fi 2/4: unpack a copy of $WIFI_ORIGINAL"
  read_firmware "$WIFI_ORIGINAL" > "$WORK/original.bin"
  mkdir "$WORK/unpacked"
  ( cd "$WORK/unpacked" && python3 "$BDENCODER" -e "$WORK/original.bin" >/dev/null ) \
    || die "couldn't unpack board-2.bin (see message above)"
  [ -f "$WORK/unpacked/board-2.json" ] || die "unpacking failed (no board-2.json)"

  say "Wi-Fi 3/4: add this laptop's label to the generic settings"
  # board-2.json lists entries like {"names": ["label", ...], "data": "file"}.
  # Find the generic entry and add this laptop's label next to it.
  CHANGED=$(python3 - "$WORK/unpacked/board-2.json" "$WIFI_SOURCE_NAME" "$WIFI_NEW_NAME" <<'PYTHON'
import json, sys
path, source_name, new_name = sys.argv[1], sys.argv[2], sys.argv[3]
with open(path) as f:
    data = json.load(f)
changed = 0
for section in (data if isinstance(data, list) else [data]):
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
    info "generic label not found. Labels for this chip that exist:"
    grep -o 'bus=pci[^"]*qmi-chip-id=18,qmi-board-id=255[^"]*' "$WORK/unpacked/board-2.json" | sort -u | head -20
    die "edit WIFI_SOURCE_NAME at the top of this script to one of those"
  fi

  say "Wi-Fi 4/4: repack, double-check, install"
  ( cd "$WORK/unpacked" && python3 "$BDENCODER" -c board-2.json -o "$WORK/new.bin" >/dev/null ) \
    || die "couldn't repack board-2.bin (see message above)"
  mkdir "$WORK/check"
  ( cd "$WORK/check" && python3 "$BDENCODER" -e "$WORK/new.bin" >/dev/null ) \
    || die "couldn't re-read the new board-2.bin"
  grep -qF "$WIFI_NEW_NAME" "$WORK/check/board-2.json" || die "check failed: label missing"
  mkdir -p "$WIFI_OUR_DIR"
  install -m 644 "$WORK/new.bin" "$WIFI_OUR_FILE"
  info "saved $WIFI_OUR_FILE"

  handle_initramfs
fi

# ============================ SOUND ==========================================

if do_audio; then
  if [ "$AUDIO_WAY" = ips3 ]; then
    say "Sound 1/3: download and build jglathe's wiring diagram (topology)"
    fetch_pinned "$TOPO_URL" "$TOPO_COMMIT" "$WORK/topo"
    m4 -I "$WORK/topo" "$WORK/topo/$TOPO_SOURCE" > "$WORK/tplg.conf"
    alsatplg -c "$WORK/tplg.conf" -o "$WORK/tplg.bin" || die "alsatplg couldn't build the diagram"

    say "Sound 2/3: download jglathe's recipe (UCM) and check it fits"
    fetch_pinned "$UCM_URL" "$UCM_COMMIT" "$WORK/ucm"
    SRC="$WORK/ucm/ucm2/Qualcomm/x1e80100"
    {
      echo "# HP OmniBook 3 14-hz0: copy of LENOVO-Ideapad-Slim3.conf from"
      echo "# jglathe/alsa-ucm-conf commit $UCM_COMMIT, installed by omisetup-all.sh"
      sed 's|/Qualcomm/x1e80100/Ideapad-Slim3-HiFi.conf|/Qualcomm/x1e80100/'"$OUR_RECIPE_HIFI"'|' \
        "$SRC/LENOVO-Ideapad-Slim3.conf"
    } > "$WORK/$OUR_RECIPE"
    {
      echo "# HP OmniBook 3 14-hz0: copy of Ideapad-Slim3-HiFi.conf from"
      echo "# jglathe/alsa-ucm-conf commit $UCM_COMMIT, installed by omisetup-all.sh"
      cat "$SRC/Ideapad-Slim3-HiFi.conf"
    } > "$WORK/$OUR_RECIPE_HIFI"
    grep -q "$OUR_RECIPE_HIFI" "$WORK/$OUR_RECIPE" || die "renaming inside the recipe failed"
    # Every helper file the recipe pulls in must exist in your alsa-ucm-conf.
    bad=0
    for f in $(cat "$WORK/$OUR_RECIPE" "$WORK/$OUR_RECIPE_HIFI" \
               | sed -n 's/.*File "\([^"]*\)".*/\1/p' | grep -v "$OUR_RECIPE_HIFI" | sort -u); do
      [ -f "$UCM_DIR$f" ] || { info "missing: $UCM_DIR$f"; bad=1; }
    done
    [ "$bad" = 0 ] || die "your alsa-ucm-conf is too old (files listed above). Update it, or use --legacy-audio."
  else
    say "Sound 1/3: pick the Surface Laptop 7 wiring diagram (legacy)"
    [ -f "$UCM_LINK_DIR/$LEGACY_TARGET" ] || die "LENOVO-T14s.conf not found; update alsa-ucm-conf."
    src=$(find_firmware "$TPLG_DISTRO_DIR/$LEGACY_TPLG") || die "$LEGACY_TPLG not found in $TPLG_DISTRO_DIR"
    read_firmware "$src" > "$WORK/tplg.bin"
    say "Sound 2/3: (legacy uses your distro's T14s recipe, nothing to download)"
  fi
  [ -s "$WORK/tplg.bin" ] || die "the wiring diagram came out empty"

  say "Sound 3/3: install"
  mkdir -p "$TPLG_OUR_DIR"
  install -m 644 "$WORK/tplg.bin" "$TPLG_OUR_FILE"
  info "saved $TPLG_OUR_FILE"
  if [ "$AUDIO_WAY" = ips3 ]; then
    install -m 644 "$WORK/$OUR_RECIPE" "$RECIPE_DIR/$OUR_RECIPE"
    install -m 644 "$WORK/$OUR_RECIPE_HIFI" "$RECIPE_DIR/$OUR_RECIPE_HIFI"
    info "saved $RECIPE_DIR/$OUR_RECIPE and $OUR_RECIPE_HIFI"
  fi
  ln -sfn "$UCM_TARGET" "$UCM_LINK"
  info "shortcut $UCM_LINK -> $UCM_TARGET"
fi

say "Done. Reboot, then run:  $0 --status"
info "SPEAKER SAFETY: keep speaker volume at about half until you know it sounds clean."
info "To remove everything:  sudo $0 --undo"
