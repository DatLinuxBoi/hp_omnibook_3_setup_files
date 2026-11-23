#!/bin/sh
# =============================================================================
# fix-audio.sh  -  make sound work on the HP OmniBook 3 14-hz0 (Snapdragon X Plus)
# =============================================================================
#
# THE PROBLEM, IN PLAIN WORDS
#   On this laptop, sound goes through a small helper processor (the "audio
#   DSP"). Linux needs two extra files before sound works:
#
#   1. A TOPOLOGY file: a wiring diagram for the DSP that says which inputs
#      and outputs exist (speakers, headphone jack, microphones) and how
#      sound flows between them. Linux looks for it by this laptop's name:
#
#        /lib/firmware/qcom/x1e80100/X1E80100-HP-OMNIBOOK-3-tplg.bin
#
#      No file with that name exists yet, so the sound card never starts.
#
#   2. A UCM PROFILE ("Use Case Manager"): a recipe that tells PipeWire, your
#      desktop's sound system, which switches to flip for "Speakers",
#      "Headphones" and "Microphone". Without it, you get no sound devices
#      or only a "Dummy Output".
#
# THE FIX
#   1. Copy a topology made for a very similar laptop and save it under this
#      laptop's name. By default that's the Microsoft Surface Laptop 7
#      ("Romulus") file, which your old setup used. If you have a topology
#      from a machine where sound already works, pass it with --tplg.
#   2. Add a shortcut (a "symlink") so this laptop uses the ThinkPad T14s
#      sound recipe. The two laptops use the same kind of speaker and
#      headphone chips.
#
# WHERE THINGS GO (why this is safe)
#   Topology  -> /lib/firmware/updates/qcom/x1e80100/   (checked before /lib/firmware,
#                so the distro's own files are never changed)
#   Shortcut  -> /usr/share/alsa/ucm2/conf.d/x1e80100/<your card's name>.conf
#                (a new file; no existing file is edited)
#   --undo removes exactly these two things.
#
# !!  SPEAKER SAFETY  !!
#   The sound recipe is borrowed from another laptop. Speaker amplifiers on
#   these Snapdragon laptops can be driven too hard. Keep speaker volume at
#   about half until you know it sounds clean. Headphones are not a concern.
#
# HOW TO USE
#   ./fix-audio.sh                     Preview only. Changes nothing.
#   sudo ./fix-audio.sh --apply        Do it.
#   sudo ./fix-audio.sh --apply --tplg FILE   Use your own topology file.
#   sudo ./fix-audio.sh --undo         Remove what this script added.
#   Then reboot. If sound devices still don't show, as your normal user (no sudo):
#   systemctl --user restart wireplumber pipewire
#
# WHAT IT NEEDS
#   Your distro's packages: linux-firmware (with the qcom/x1e80100 files),
#   alsa-ucm-conf, pipewire and wireplumber.
#
# OPTIONS FOR TESTING
#   FW_DIR=..., UCM_DIR=..., CARD_LONGNAME=...  override the folders and card name.
# =============================================================================

set -eu   # stop at the first error; treat unset variables as errors

# ---- Settings ---------------------------------------------------------------

# The topology name Linux asks for. It comes from the sound card's model name
# in the device tree ("X1E80100-HP-OMNIBOOK-3") plus "-tplg.bin".
TPLG_NAME="X1E80100-HP-OMNIBOOK-3-tplg.bin"
# The topology we copy from if you don't give one (Surface Laptop 7).
DEFAULT_TPLG="X1E80100-Romulus-tplg.bin"
# The sound recipe we borrow (ThinkPad T14s).
UCM_PROFILE="LENOVO-T14s.conf"
# This laptop's sound card "long name". Used only if the card isn't running
# yet, so the script can't read the name itself.
DEFAULT_LONGNAME="HP-HPOmniBook3Laptop14_hz0xxx-ConfigID-8EF1"

if [ -z "${FW_DIR:-}" ]; then
  if [ -d /lib/firmware ]; then FW_DIR=/lib/firmware; else FW_DIR=/usr/lib/firmware; fi
fi
UCM_DIR=${UCM_DIR:-/usr/share/alsa/ucm2}

DISTRO_TPLG_DIR="$FW_DIR/qcom/x1e80100"           # distro's files (read only)
OUR_TPLG_DIR="$FW_DIR/updates/qcom/x1e80100"      # where our copy goes
OUR_TPLG="$OUR_TPLG_DIR/$TPLG_NAME"
UCM_LINK_DIR="$UCM_DIR/conf.d/x1e80100"
UCM_TARGET="../../Qualcomm/x1e80100/$UCM_PROFILE"  # where the shortcut points

# ---- Small helpers ------------------------------------------------------------

say()  { printf '==> %s\n' "$*"; }
info() { printf '    %s\n' "$*"; }
die()  { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

# Print a file's contents, unpacking it if compressed (.zst or .xz).
read_firmware() {
  case $1 in
    *.zst) zstd -dc "$1" ;;
    *.xz)  xz -dc "$1" ;;
    *)     cat "$1" ;;
  esac
}

# Find a firmware file whether the distro ships it plain, .zst or .xz.
find_firmware() {
  for f in "$1" "$1.zst" "$1.xz"; do
    if [ -f "$f" ]; then printf '%s\n' "$f"; return 0; fi
  done
  return 1
}

# The sound card's long name, read from /proc/asound/cards. The line after
# the "x1e80100 - ..." line holds it. Falls back to the default above.
card_longname() {
  if [ -n "${CARD_LONGNAME:-}" ]; then printf '%s\n' "$CARD_LONGNAME"; return; fi
  name=""
  if [ -r /proc/asound/cards ]; then
    name=$(awk '/x1e80100 - /{getline; gsub(/^[ \t]+|[ \t]+$/, ""); print; exit}' /proc/asound/cards)
  fi
  if [ -z "$name" ]; then
    info "(sound card not running yet, so using the usual name for this model)" >&2
    name=$DEFAULT_LONGNAME
  fi
  printf '%s\n' "$name"
}

# ---- Read the command line ------------------------------------------------------

MODE=preview
TPLG=""
while [ $# -gt 0 ]; do
  case $1 in
    --apply) MODE=apply ;;
    --undo)  MODE=undo ;;
    --tplg)  [ $# -ge 2 ] || die "--tplg needs a file"; TPLG=$2; shift ;;
    # Print the comment block at the top of this file (every line starting
    # with "#", stopping at the first line that doesn't).
    -h|--help) awk 'NR>1 && /^#/ {sub(/^# ?/, ""); print; next} NR>1 {exit}' "$0"; exit 0 ;;
    *) die "unknown option: $1  (try --help)" ;;
  esac
  shift
done

if [ "$MODE" != preview ] && [ "$(id -u)" != 0 ]; then
  die "run with sudo for --apply or --undo"
fi

LONGNAME=$(card_longname)
UCM_LINK="$UCM_LINK_DIR/$LONGNAME.conf"

# ---- Undo -----------------------------------------------------------------------

if [ "$MODE" = undo ]; then
  if [ -f "$OUR_TPLG" ]; then
    rm -f "$OUR_TPLG"; rmdir -p "$OUR_TPLG_DIR" 2>/dev/null || true
    say "Removed $OUR_TPLG"
  else
    say "No topology copy to remove."
  fi
  # Only remove the shortcut if it is OUR shortcut (points at the T14s recipe).
  if [ -L "$UCM_LINK" ] && [ "$(readlink "$UCM_LINK")" = "$UCM_TARGET" ]; then
    rm -f "$UCM_LINK"
    say "Removed $UCM_LINK"
  else
    say "No sound-recipe shortcut of ours to remove."
  fi
  say "Reboot to finish."
  exit 0
fi

# ---- Step 1: topology file ------------------------------------------------------

say "Step 1: topology (the audio DSP's wiring diagram)"
[ -d "$DISTRO_TPLG_DIR" ] || die "$DISTRO_TPLG_DIR not found. Install linux-firmware first."

if existing=$(find_firmware "$DISTRO_TPLG_DIR/$TPLG_NAME"); then
  info "your distro already ships $existing, so no copy needed"
  TPLG_TODO=no
elif [ -f "$OUR_TPLG" ] && [ -z "$TPLG" ]; then
  info "already installed: $OUR_TPLG"
  TPLG_TODO=no
else
  if [ -n "$TPLG" ]; then
    [ -f "$TPLG" ] || die "file not found: $TPLG"
    SOURCE=$TPLG
  else
    SOURCE=$(find_firmware "$DISTRO_TPLG_DIR/$DEFAULT_TPLG") \
      || die "$DEFAULT_TPLG not found in $DISTRO_TPLG_DIR. Use --tplg FILE."
    info "no topology given, so using the Surface Laptop 7 one: $SOURCE"
  fi
  TPLG_TODO=yes
  info "will save it as $OUR_TPLG"
fi

# ---- Step 2: sound recipe shortcut ------------------------------------------------

say "Step 2: sound recipe (UCM) shortcut"
[ -d "$UCM_LINK_DIR" ] || die "$UCM_LINK_DIR not found. Install or update alsa-ucm-conf."
[ -f "$UCM_LINK_DIR/$UCM_TARGET" ] || die "$UCM_PROFILE not found. Your alsa-ucm-conf is too old; update it."
info "sound card name: $LONGNAME"
if [ -e "$UCM_LINK" ] || [ -L "$UCM_LINK" ]; then
  info "already present: $UCM_LINK -> $(readlink "$UCM_LINK" 2>/dev/null || echo 'a real file')"
  UCM_TODO=no
else
  info "will create $UCM_LINK -> $UCM_TARGET"
  UCM_TODO=yes
fi

if [ "$MODE" = preview ]; then
  say "Preview only. Nothing was changed. Run with sudo and --apply to do it."
  exit 0
fi

# ---- Step 3: make the changes -----------------------------------------------------------

say "Step 3: making the changes"
if [ "$TPLG_TODO" = yes ]; then
  mkdir -p "$OUR_TPLG_DIR"
  # Save it uncompressed, so it loads whatever compression your kernel supports.
  read_firmware "$SOURCE" > "$OUR_TPLG.tmp"
  chmod 644 "$OUR_TPLG.tmp"
  mv "$OUR_TPLG.tmp" "$OUR_TPLG"
  info "saved $OUR_TPLG"
fi
if [ "$UCM_TODO" = yes ]; then
  ln -s "$UCM_TARGET" "$UCM_LINK"
  info "created $UCM_LINK"
fi

say "Done. Reboot, then check with:  wpctl status"
info "SPEAKER SAFETY: keep speaker volume at about half until you know it sounds clean."
info "If there's still no sound:  sudo dmesg | grep -iE 'tplg|q6apm|snd'"
