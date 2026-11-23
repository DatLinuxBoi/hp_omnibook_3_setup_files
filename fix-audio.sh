#!/bin/sh
# =============================================================================
# fix-audio.sh  -  make sound work on the HP OmniBook 3 14-hz0 (Snapdragon X Plus)
# =============================================================================
#
# THE PROBLEM, IN PLAIN WORDS
#   On this laptop, sound goes through a small helper processor (the "audio
#   DSP"). Linux needs two extra pieces before sound works:
#
#   1. A TOPOLOGY file: a wiring diagram for the DSP that says which outputs
#      and inputs exist (speakers, headphones, mics, display outputs) and how
#      sound flows between them. Linux looks for it by this laptop's name:
#        /lib/firmware/qcom/x1e80100/X1E80100-HP-OMNIBOOK-3-tplg.bin
#      No file with that name exists, so the sound card can't start.
#
#   2. A UCM RECIPE ("Use Case Manager"): tells PipeWire, your desktop's
#      sound system, which switches to flip for Speakers, Headphones and
#      Microphone, and which stream goes where.
#
# THE FIX (default)
#   Use the wiring diagram and recipe that Jens Glathe (jglathe) made for the
#   Lenovo IdeaPad Slim 3 15Q8X10. It has the same chip and the same layout:
#   2 speakers, headphones, 2 mics, display outputs. His diagram gives every
#   output its OWN path. Older borrowed diagrams share paths, and then one
#   output can fail to open because another isn't ready, which PipeWire
#   doesn't recover from ("sound worked, then stopped").
#
#   The script:
#     1. downloads exactly the versions of his files that were reviewed
#        (pinned by commit ID, see PINNED VERSIONS below)
#     2. builds the wiring diagram: m4 turns the source into a text config,
#        then alsatplg turns that into the .bin file Linux loads
#     3. saves it under this laptop's name in /lib/firmware/updates/
#        (checked before /lib/firmware, so the distro's files are untouched)
#     4. copies his recipe under NEW names of our own (HP-OmniBook3*.conf),
#        so nothing clashes with Ubuntu's files
#     5. adds a shortcut (symlink) so this laptop's sound card uses that recipe
#
#   Known difference: this laptop's device tree lists 3 display-audio outputs
#   (DisplayPort 0, 1, 2); the IdeaPad diagram has 0 and 2. Sound over that
#   one extra display output won't work. Speakers, headphones and mics should.
#
# THE OLD WAY (--legacy)
#   Copies the Surface Laptop 7 ("Romulus") diagram and points to the
#   ThinkPad T14s recipe, as the first version of this script did.
#
# !!  SPEAKER SAFETY  !!
#   Speaker amplifiers on these Snapdragon laptops can be driven too hard.
#   Keep speaker volume at about half until you know it sounds clean.
#
# HOW TO USE
#   ./fix-audio.sh                    Preview only. Changes nothing.
#   sudo ./fix-audio.sh --apply       Do it (the IdeaPad Slim 3 way).
#   sudo ./fix-audio.sh --apply --legacy [--tplg FILE]   The old way.
#   sudo ./fix-audio.sh --undo        Remove everything either way added.
#   Then reboot.
#
# WHAT IT NEEDS (Ubuntu package names)
#   git, m4, alsa-utils (has alsatplg), alsa-ucm-conf, pipewire, wireplumber:
#     sudo apt install git m4 alsa-utils
#
# OPTIONS FOR TESTING
#   FW_DIR=..., UCM_DIR=..., CARD_LONGNAME=...  override folders and card name.
# =============================================================================

set -eu   # stop at the first error; treat unset variables as errors

# ---- PINNED VERSIONS ------------------------------------------------------------
# A commit ID names one exact version of a git repository. Pinning means the
# script always installs the same files that were reviewed, even if the
# branches change later.
TOPO_URL="https://github.com/jglathe/audioreach-topology.git"
TOPO_COMMIT="a737c27fcd1339698efa72e77c6cd4682d69d9e1"   # "add topology for Lenovo IdeaPad Slim 3 15Q8X10"
TOPO_SOURCE="X1E80100-LENOVO-Ideapad-3.m4"
UCM_URL="https://github.com/jglathe/alsa-ucm-conf.git"
UCM_COMMIT="6e1a6d7aafb431b055c3af8596e170e4f06afe52"    # "ips3x: add the disables of conflicting devices"

# ---- Settings ---------------------------------------------------------------

TPLG_NAME="X1E80100-HP-OMNIBOOK-3-tplg.bin"   # the name Linux asks for
LEGACY_TPLG="X1E80100-Romulus-tplg.bin"       # --legacy: Surface Laptop 7 diagram
LEGACY_TARGET="../../Qualcomm/x1e80100/LENOVO-T14s.conf"   # --legacy: T14s recipe
OUR_RECIPE="HP-OmniBook3.conf"                # our copy of jglathe's main recipe
OUR_RECIPE_HIFI="HP-OmniBook3-HiFi.conf"      # our copy of his detailed recipe
OUR_TARGET="../../Qualcomm/x1e80100/$OUR_RECIPE"
DEFAULT_LONGNAME="HP-HPOmniBook3Laptop14_hz0xxx-ConfigID-8EF1"

if [ -z "${FW_DIR:-}" ]; then
  if [ -d /lib/firmware ]; then FW_DIR=/lib/firmware; else FW_DIR=/usr/lib/firmware; fi
fi
UCM_DIR=${UCM_DIR:-/usr/share/alsa/ucm2}

DISTRO_TPLG_DIR="$FW_DIR/qcom/x1e80100"           # distro's files (read only)
OUR_TPLG_DIR="$FW_DIR/updates/qcom/x1e80100"      # where our diagram goes
OUR_TPLG="$OUR_TPLG_DIR/$TPLG_NAME"
RECIPE_DIR="$UCM_DIR/Qualcomm/x1e80100"           # where our recipe copies go
UCM_LINK_DIR="$UCM_DIR/conf.d/x1e80100"           # where the shortcut goes

# ---- Small helpers ------------------------------------------------------------

say()  { printf '==> %s\n' "$*"; }
info() { printf '    %s\n' "$*"; }
die()  { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
have() { command -v "$1" >/dev/null 2>&1; }

# Print a file's contents, unpacking it if compressed (.zst or .xz).
# The "<" feeds the contents in, so Ubuntu's shortcut (symlink) files work.
read_firmware() {
  case $1 in
    *.zst) zstd -dc < "$1" ;;
    *.xz)  xz -dc < "$1" ;;
    *)     cat "$1" ;;
  esac
}

find_firmware() {
  for f in "$1" "$1.zst" "$1.xz"; do
    if [ -f "$f" ]; then printf '%s\n' "$f"; return 0; fi
  done
  return 1
}

# The sound card's long name, from /proc/asound/cards (line after "x1e80100 - ").
card_longname() {
  if [ -n "${CARD_LONGNAME:-}" ]; then printf '%s\n' "$CARD_LONGNAME"; return; fi
  name=""
  if [ -r /proc/asound/cards ]; then
    name=$(awk '/x1e80100 - /{getline; gsub(/^[ \t]+|[ \t]+$/, ""); print; exit}' /proc/asound/cards)
  fi
  [ -n "$name" ] || name=$DEFAULT_LONGNAME
  printf '%s\n' "$name"
}

# Download one exact version (commit) of a git repository into a folder.
fetch_pinned() {  # $1 = url, $2 = commit, $3 = folder
  git init -q "$3"
  git -C "$3" fetch -q --depth 1 "$1" "$2" \
    || die "download of $1 failed. Check the internet connection and the clock."
  git -C "$3" checkout -q FETCH_HEAD
}

# ---- Read the command line ------------------------------------------------------

MODE=preview
WAY=ips3
TPLG=""
while [ $# -gt 0 ]; do
  case $1 in
    --apply)  MODE=apply ;;
    --undo)   MODE=undo ;;
    --legacy) WAY=legacy ;;
    --tplg)   [ $# -ge 2 ] || die "--tplg needs a file"; TPLG=$2; shift ;;
    # Print the comment block at the top of this file.
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
if [ "$WAY" = ips3 ]; then TARGET=$OUR_TARGET; else TARGET=$LEGACY_TARGET; fi

# Is the shortcut one this script (or the old omnibook3-setup.sh) made?
link_is_ours() {
  [ -L "$UCM_LINK" ] || return 1
  case $(readlink "$UCM_LINK") in
    "$OUR_TARGET"|"$LEGACY_TARGET") return 0 ;;
    *) return 1 ;;
  esac
}

# ---- Undo -----------------------------------------------------------------------

if [ "$MODE" = undo ]; then
  if [ -f "$OUR_TPLG" ]; then
    rm -f "$OUR_TPLG"; rmdir -p "$OUR_TPLG_DIR" 2>/dev/null || true
    say "Removed $OUR_TPLG"
  fi
  for f in "$RECIPE_DIR/$OUR_RECIPE" "$RECIPE_DIR/$OUR_RECIPE_HIFI"; do
    if [ -f "$f" ]; then rm -f "$f"; say "Removed $f"; fi
  done
  if link_is_ours; then rm -f "$UCM_LINK"; say "Removed $UCM_LINK"; fi
  say "Undo finished. Reboot to go back to how sound was before."
  exit 0
fi

# ---- Step 1: checks (read only) ------------------------------------------------------

say "Step 1: checks"
info "way: $WAY   sound card name: $LONGNAME"
[ -d "$DISTRO_TPLG_DIR" ] || die "$DISTRO_TPLG_DIR not found. Install linux-firmware first."
[ -d "$UCM_LINK_DIR" ]    || die "$UCM_LINK_DIR not found. Install or update alsa-ucm-conf."
if [ "$WAY" = ips3 ]; then
  missing=""
  for t in git m4 alsatplg; do have "$t" || missing="$missing $t"; done
  [ -z "$missing" ] || die "missing tools:$missing. Install with: sudo apt install git m4 alsa-utils"
  info "tools git, m4, alsatplg: found"
else
  [ -f "$UCM_LINK_DIR/$LEGACY_TARGET" ] || die "LENOVO-T14s.conf not found. Update alsa-ucm-conf."
fi

# The shortcut: fine if missing or ours; stop if something else is there.
if { [ -e "$UCM_LINK" ] || [ -L "$UCM_LINK" ]; } && ! link_is_ours; then
  die "$UCM_LINK already exists and wasn't made by this script. Look at it before going on."
fi
if link_is_ours; then info "existing shortcut will be pointed at the new recipe"; fi

if [ "$MODE" = preview ]; then
  say "Preview only. With --apply this script would:"
  if [ "$WAY" = ips3 ]; then
    info "1. download jglathe's diagram and recipe (pinned versions) to a temp folder"
    info "2. build the diagram with m4 + alsatplg"
    info "3. save it as $OUR_TPLG"
    info "4. check Ubuntu has every helper file his recipe needs"
    info "5. save the recipe as $RECIPE_DIR/$OUR_RECIPE (+ $OUR_RECIPE_HIFI)"
  else
    info "1. copy the Surface Laptop 7 diagram to $OUR_TPLG"
  fi
  info "6. make $UCM_LINK -> $TARGET"
  exit 0
fi

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT INT TERM

# ---- Step 2: get the wiring diagram -------------------------------------------------------

if [ "$WAY" = ips3 ]; then
  say "Step 2: download and build jglathe's wiring diagram"
  fetch_pinned "$TOPO_URL" "$TOPO_COMMIT" "$WORK/topo"
  # m4 fills in the template; -I tells it where its include files are.
  m4 -I "$WORK/topo" "$WORK/topo/$TOPO_SOURCE" > "$WORK/tplg.conf"
  # alsatplg compiles the text config into the binary file Linux loads.
  alsatplg -c "$WORK/tplg.conf" -o "$WORK/tplg.bin" \
    || die "alsatplg couldn't build the diagram (see the message above)"
  [ -s "$WORK/tplg.bin" ] || die "the built diagram is empty"
  info "built ($(wc -c < "$WORK/tplg.bin") bytes)"
else
  say "Step 2: pick the wiring diagram (legacy)"
  if [ -n "$TPLG" ]; then
    [ -f "$TPLG" ] || die "file not found: $TPLG"; SOURCE=$TPLG
  else
    SOURCE=$(find_firmware "$DISTRO_TPLG_DIR/$LEGACY_TPLG") \
      || die "$LEGACY_TPLG not found in $DISTRO_TPLG_DIR. Use --tplg FILE."
  fi
  read_firmware "$SOURCE" > "$WORK/tplg.bin"
  [ -s "$WORK/tplg.bin" ] || die "couldn't read $SOURCE (it came out empty). Is zstd/xz installed?"
  info "using $SOURCE"
fi

# ---- Step 3: get the recipe (ips3 way only) ------------------------------------------------

if [ "$WAY" = ips3 ]; then
  say "Step 3: download jglathe's recipe and check it fits your system"
  fetch_pinned "$UCM_URL" "$UCM_COMMIT" "$WORK/ucm"
  SRC="$WORK/ucm/ucm2/Qualcomm/x1e80100"
  # Our copies, renamed. The main recipe points at the detailed one by
  # name, so that one line gets the new name too (sed = find and replace).
  {
    echo "# HP OmniBook 3 14-hz0: copy of LENOVO-Ideapad-Slim3.conf from"
    echo "# jglathe/alsa-ucm-conf commit $UCM_COMMIT, installed by fix-audio.sh"
    sed 's|/Qualcomm/x1e80100/Ideapad-Slim3-HiFi.conf|/Qualcomm/x1e80100/'"$OUR_RECIPE_HIFI"'|' \
      "$SRC/LENOVO-Ideapad-Slim3.conf"
  } > "$WORK/$OUR_RECIPE"
  {
    echo "# HP OmniBook 3 14-hz0: copy of Ideapad-Slim3-HiFi.conf from"
    echo "# jglathe/alsa-ucm-conf commit $UCM_COMMIT, installed by fix-audio.sh"
    cat "$SRC/Ideapad-Slim3-HiFi.conf"
  } > "$WORK/$OUR_RECIPE_HIFI"
  grep -q "$OUR_RECIPE_HIFI" "$WORK/$OUR_RECIPE" || die "renaming inside the recipe failed"

  # Every helper file the recipe pulls in (lines like  File "/codecs/...")
  # must already exist in Ubuntu's alsa-ucm-conf. Check before installing.
  missing=0
  for f in $(cat "$WORK/$OUR_RECIPE" "$WORK/$OUR_RECIPE_HIFI" \
             | sed -n 's/.*File "\([^"]*\)".*/\1/p' | grep -v "$OUR_RECIPE_HIFI" | sort -u); do
    if [ ! -f "$UCM_DIR$f" ]; then info "missing: $UCM_DIR$f"; missing=1; fi
  done
  [ "$missing" = 0 ] || die "your alsa-ucm-conf is missing files the recipe needs (listed above). Nothing was changed."
  info "all helper files found"
fi

# ---- Step 4: install -------------------------------------------------------------------------

say "Step 4: install"
mkdir -p "$OUR_TPLG_DIR"
install -m 644 "$WORK/tplg.bin" "$OUR_TPLG"
info "saved $OUR_TPLG"
if [ "$WAY" = ips3 ]; then
  install -m 644 "$WORK/$OUR_RECIPE" "$RECIPE_DIR/$OUR_RECIPE"
  install -m 644 "$WORK/$OUR_RECIPE_HIFI" "$RECIPE_DIR/$OUR_RECIPE_HIFI"
  info "saved $RECIPE_DIR/$OUR_RECIPE and $OUR_RECIPE_HIFI"
fi
# -f replaces our own old shortcut (already checked it's ours, or absent).
ln -sfn "$TARGET" "$UCM_LINK"
info "shortcut $UCM_LINK -> $TARGET"

say "Done. Reboot, then check with:  wpctl status"
info "SPEAKER SAFETY: keep speaker volume at about half until you know it sounds clean."
info "If there's no sound:  sudo dmesg | grep -iE 'tplg|q6apm|snd'"
info "To go back:  sudo $0 --undo"
