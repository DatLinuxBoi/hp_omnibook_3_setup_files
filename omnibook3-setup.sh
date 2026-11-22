#!/bin/sh
# omnibook3-setup.sh
#
# Reproduces the setup that got Wi-Fi and audio working on the
# HP OmniBook 3 14-hz0xxx (Snapdragon X Plus X1P42100, OLED) under a
# self-built 7.3.y kernel from the jglathe/linux_ms_dev_kit tree.
# Plain POSIX sh: meant to run on Fedora, Gentoo, Debian, Arch, ...
#
# Stages:
#   wifi    add the board-data alias for HP 103c:8d9a to ath11k's board-2.bin
#   audio   install the sound topology file + the UCM profile link
#   kernel  (explicit only) install Image / DTB / modules, build a
#           --no-hostonly initramfs, add a boot entry
#   export  (run on the working machine) collect the known-good files into a
#           bundle directory that the other stages can use elsewhere
#
# Examples:
#   ./omnibook3-setup.sh export --bundle ~/bundle --kernel-dir ~/kernel-out
#   sudo ./omnibook3-setup.sh --dry-run all
#   sudo ./omnibook3-setup.sh --bundle ~/bundle all kernel
#
# Not covered: extracting firmware from Windows. Nothing in the working setup
# needed it (the DSP firmware came from the distro's linux-firmware).

set -eu

# ---------------------------------------------------------------- tunables
FW_DIR=${FW_DIR:-}
UCM_DIR=${UCM_DIR:-/usr/share/alsa/ucm2}
# Name the driver asks for (copy from `dmesg | grep ath11k` if yours differs):
WIFI_NAME_NEW=${WIFI_NAME_NEW:-bus=pci,vendor=17cb,device=1103,subsystem-vendor=103c,subsystem-device=8d9a,qmi-chip-id=18,qmi-board-id=255}
# Generic NFA765a entry that Windows' INF also uses for this HP ID:
WIFI_NAME_SRC=${WIFI_NAME_SRC:-bus=pci,vendor=17cb,device=1103,subsystem-vendor=105b,subsystem-device=e105,qmi-chip-id=18,qmi-board-id=255}
TPLG_NAME=${TPLG_NAME:-X1E80100-HP-OMNIBOOK-3-tplg.bin}
TPLG_DEFAULT_SRC=${TPLG_DEFAULT_SRC:-X1E80100-Romulus-tplg.bin}
UCM_PROFILE=${UCM_PROFILE:-LENOVO-T14s.conf}
UCM_LONGNAME_DEFAULT=${UCM_LONGNAME_DEFAULT:-HP-HPOmniBook3Laptop14_hz0xxx-ConfigID-8EF1}
QSAK_URL=${QSAK_URL:-https://github.com/qca/qca-swiss-army-knife.git}

DRY=0 FORCE=0 INSTALL_DEPS=0 NO_BOOTLOADER=0
BUNDLE="" KERNEL_DIR="" BOARD_BIN="" TPLG="" BDENCODER=""
STAGES=""
WORK=""

# ------------------------------------------------------------------ helpers
say()  { printf '==> %s\n' "$*"; }
note() { printf '    %s\n' "$*"; }
warn() { printf 'WARNING: %s\n' "$*" >&2; }
die()  { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
have() { command -v "$1" >/dev/null 2>&1; }
run()  { if [ "$DRY" = 1 ]; then printf '    [dry-run] %s\n' "$*"; else "$@"; fi; }
cleanup() { [ -n "$WORK" ] && rm -rf "$WORK"; return 0; }

usage() {
  sed -n '2,/^set -eu/p' "$0" | sed '$d' | sed 's/^# \{0,1\}//'
  cat <<'EOF'

Options:
  --bundle DIR       bundle made by `export` (supplies board-2.bin, topology, kernel files)
  --kernel-dir DIR   directory with Image, *omnibook-3-oled*.dtb, modules.tar.gz
  --board-bin FILE   install this prebuilt board-2.bin instead of building one
  --tplg FILE        topology file to install as the OmniBook 3 topology
  --bdencoder PATH   use this ath11k-bdencoder instead of cloning qca-swiss-army-knife
  --install-deps     install the helper tools with the distro package manager
  --no-bootloader    kernel stage: install files, but do not touch the bootloader
  --force            replace things that already exist
  --dry-run          show what would change on the system
  -h, --help         this text
EOF
}

# Print the existing variant (plain, .xz or .zst) of a firmware path.
find_fw() {
  for _s in "" .xz .zst; do
    if [ -e "$1$_s" ]; then printf '%s\n' "$1$_s"; return 0; fi
  done
  return 1
}

fw_cat() {
  case $1 in
    *.xz)  xz -dc "$1" ;;
    *.zst) zstd -dc "$1" ;;
    *)     cat "$1" ;;
  esac
}

install_deps() {
  say "Installing helper tools"
  if   have dnf;     then run dnf -y install git python3 xz zstd kmod dracut
  elif have apt-get; then run apt-get install -y git python3 xz-utils zstd kmod dracut
  elif have pacman;  then run pacman -S --needed --noconfirm git python xz zstd kmod dracut
  elif have emerge;  then run emerge --noreplace dev-vcs/git dev-lang/python app-arch/xz-utils app-arch/zstd sys-apps/kmod sys-kernel/dracut
  elif have zypper;  then run zypper -n install git python3 xz zstd kmod dracut
  else warn "no known package manager found; install git, python3, xz, zstd, kmod, dracut yourself"
  fi
  note "Also make sure these are installed (names vary by distro):"
  note "  linux-firmware (with ath11k + qcom/x1e80100), alsa-ucm-conf, pipewire + wireplumber"
}

# ------------------------------------------------------------------- Wi-Fi
find_bdencoder() {
  if [ -n "$BDENCODER" ]; then
    [ -f "$BDENCODER" ] || die "--bdencoder file not found: $BDENCODER"
    printf '%s\n' "$BDENCODER"; return 0
  fi
  if have ath11k-bdencoder; then command -v ath11k-bdencoder; return 0; fi
  have git || die "git is needed to fetch qca-swiss-army-knife (or pass --bdencoder / --board-bin)"
  say "Cloning qca-swiss-army-knife (needs network; a wrong system clock breaks HTTPS)" >&2
  git clone --depth 1 "$QSAK_URL" "$WORK/qsak" >&2 \
    || die "clone failed - check the network and the date (timedatectl set-ntp true)"
  printf '%s\n' "$WORK/qsak/tools/scripts/ath11k/ath11k-bdencoder"
}

write_alias_py() {
  cat > "$WORK/alias.py" <<'PY'
import json, sys
path, src, new = sys.argv[1:4]
data = json.load(open(path))
added = present = 0
def walk(o):
    global added, present
    if isinstance(o, dict):
        names = o.get("names")
        if isinstance(names, list):
            if new in names:
                present += 1
            elif src in names:
                names.append(new)
                added += 1
        for v in o.values():
            walk(v)
    elif isinstance(o, list):
        for v in o:
            walk(v)
walk(data)
json.dump(data, open(path, "w"), indent=2)
print(added, present)
PY
}

stage_wifi() {
  say "Wi-Fi: board data for HP subsystem 103c:8d9a"
  fwd=$FW_DIR/ath11k/WCN6855/hw2.1
  [ -d "$fwd" ] || die "$fwd not found - install your distro's linux-firmware first"
  dest=$fwd/board-2.bin
  bak=$fwd/board-2.bin.orig-omnibook3

  if [ -f "$dest" ] && grep -qaF -- "$WIFI_NAME_NEW" "$dest" && [ "$FORCE" != 1 ]; then
    note "already installed: $dest contains the alias (use --force to rebuild)"
    return 0
  fi

  if [ -n "$BOARD_BIN" ]; then
    [ -f "$BOARD_BIN" ] || die "board file not found: $BOARD_BIN"
    note "using prebuilt $BOARD_BIN"
    if [ -f "$dest" ] && [ ! -e "$bak" ]; then run cp -p "$dest" "$bak"; fi
    run install -m 644 "$BOARD_BIN" "$dest"
    note "reboot (do not modprobe -r/modprobe ath11k_pci; that crashed the firmware before)"
    return 0
  fi

  have python3 || die "python3 is required (or pass --board-bin)"
  if   [ -f "$bak" ]; then srcf=$bak
  elif srcf=$(find_fw "$dest"); then :
  else die "no board-2.bin found in $fwd"
  fi
  note "source: $srcf"

  if [ "$DRY" = 1 ] && [ -z "$BDENCODER" ] && ! have ath11k-bdencoder; then
    note "[dry-run] would clone $QSAK_URL, extract, alias, rebuild and install $dest"
    return 0
  fi

  fw_cat "$srcf" > "$WORK/board-2.bin"
  bde=$(find_bdencoder)
  mkdir -p "$WORK/x"
  ( cd "$WORK/x" && python3 "$bde" -e "$WORK/board-2.bin" >/dev/null )
  [ -f "$WORK/x/board-2.json" ] || die "ath11k-bdencoder -e did not produce board-2.json"

  write_alias_py
  res=$(python3 "$WORK/alias.py" "$WORK/x/board-2.json" "$WIFI_NAME_SRC" "$WIFI_NAME_NEW")
  added=${res% *}; present=${res#* }
  if [ "$added" = 0 ] && [ "$present" = 0 ]; then
    warn "the generic entry was not found in this linux-firmware's board-2.bin."
    warn "Entries for chip 18 / board 255 that exist:"
    grep -o 'bus=pci[^"]*qmi-chip-id=18,qmi-board-id=255[^"]*' "$WORK/x/board-2.json" | sort -u | head -20 >&2 || true
    die "set WIFI_NAME_SRC to one of those (the generic NFA765a one) and retry"
  fi
  note "entries updated: $added, already present: $present"

  ( cd "$WORK/x" && python3 "$bde" -c board-2.json -o "$WORK/board-2-new.bin" >/dev/null )
  [ -s "$WORK/board-2-new.bin" ] || die "rebuilt board-2.bin is empty"
  mkdir -p "$WORK/v"
  ( cd "$WORK/v" && python3 "$bde" -e "$WORK/board-2-new.bin" >/dev/null )
  grep -qF "$WIFI_NAME_NEW" "$WORK/v/board-2.json" || die "verification failed: alias missing from rebuilt file"

  if [ -f "$dest" ] && [ ! -e "$bak" ]; then run cp -p "$dest" "$bak"; fi
  run install -m 644 "$WORK/board-2-new.bin" "$dest"
  note "installed $dest (a plain original, if there was one, is saved as board-2.bin.orig-omnibook3)"
  note "A linux-firmware update can overwrite this: re-run this stage afterwards."
  note "Reboot to test; do not modprobe -r/modprobe ath11k_pci."
}

# ------------------------------------------------------------------- Audio
card_longname() {
  n=""
  if [ -r /proc/asound/cards ]; then
    n=$(awk '/x1e80100 - /{getline; gsub(/^[ \t]+|[ \t]+$/,""); print; exit}' /proc/asound/cards)
  fi
  [ -n "$n" ] || warn "no x1e80100 sound card is up yet; using the default long name"
  printf '%s\n' "${n:-$UCM_LONGNAME_DEFAULT}"
}

stage_audio() {
  say "Audio: topology file"
  tdir=$FW_DIR/qcom/x1e80100
  [ -d "$tdir" ] || die "$tdir not found - install linux-firmware (needs the x1e80100 DSP firmware)"

  if cur=$(find_fw "$tdir/$TPLG_NAME") && [ "$FORCE" != 1 ]; then
    note "already present: $cur"
  else
    if [ -n "$TPLG" ]; then
      src=$TPLG
      [ -f "$src" ] || die "topology file not found: $src"
    else
      src=$(find_fw "$tdir/$TPLG_DEFAULT_SRC") \
        || die "$TPLG_DEFAULT_SRC not in $tdir - pass --tplg FILE or use --bundle"
      warn "no topology supplied; copying $TPLG_DEFAULT_SRC under the OmniBook 3 name."
      warn "That is a guess based on file sizes. Prefer --bundle from the working machine."
    fi
    ext=""
    case $src in *.xz) ext=.xz ;; *.zst) ext=.zst ;; esac
    for s in "" .xz .zst; do run rm -f "$tdir/$TPLG_NAME$s"; done
    run install -m 644 "$src" "$tdir/$TPLG_NAME$ext"
  fi

  say "Audio: UCM profile"
  confd=$UCM_DIR/conf.d/x1e80100
  prof=$UCM_DIR/Qualcomm/x1e80100/$UCM_PROFILE
  [ -d "$confd" ] || die "$confd missing - alsa-ucm-conf is not installed or too old"
  [ -f "$prof" ]  || die "$prof missing - alsa-ucm-conf is too old"
  longname=$(card_longname)
  link=$confd/$longname.conf
  if [ -e "$link" ] || [ -L "$link" ]; then
    if [ "$FORCE" = 1 ]; then run rm -f "$link"; fi
  fi
  if [ -e "$link" ] || [ -L "$link" ]; then
    note "already present: $link"
  else
    run ln -s "../../Qualcomm/x1e80100/$UCM_PROFILE" "$link"
    note "linked $link -> $UCM_PROFILE"
  fi
  note "This profile is borrowed from another laptop. Keep speaker volume moderate"
  note "until someone confirms the amplifier setup upstream."
  note "After a reboot, as your normal user: systemctl --user restart wireplumber pipewire"
}

# ------------------------------------------------------------------ Kernel
stage_kernel() {
  say "Kernel: install Image, DTB and modules"
  kd=${KERNEL_DIR:-$BUNDLE}
  [ -n "$kd" ] && [ -d "$kd" ] || die "give --kernel-dir (or --bundle) with Image, a .dtb and modules.tar.gz"
  img=$kd/Image
  mods=$kd/modules.tar.gz
  dtb=$(ls "$kd"/*omnibook-3-oled*.dtb 2>/dev/null | head -n 1 || true)
  [ -f "$img" ]  || die "missing $img"
  [ -f "$mods" ] || die "missing $mods"
  [ -n "$dtb" ]  || die "no *omnibook-3-oled*.dtb in $kd"
  dtbname=$(basename "$dtb")

  nko=$(tar tzf "$mods" | grep -c '\.ko' || true)
  [ "$nko" -gt 500 ] || die "$mods contains only $nko modules. A kernel needs thousands; rebuild it with: make modules_install INSTALL_MOD_PATH=\$PWD/out"
  kver=$(tar tzf "$mods" | sed -n 's|^lib/modules/\([^/]*\)/.*|\1|p' | head -n 1)
  [ -n "$kver" ] || die "cannot read the kernel version from $mods"
  note "kernel $kver, $nko modules, dtb $dtbname"

  have depmod || die "depmod (kmod) is required"
  have dracut || die "dracut is required to build the initramfs (use --install-deps, or emerge sys-kernel/dracut)"

  run mkdir -p /lib/modules
  run rm -rf "/lib/modules/$kver"
  run tar xzf "$mods" --strip-components=2 -C /lib/modules
  run rm -f "/lib/modules/$kver/build" "/lib/modules/$kver/source"
  run depmod -a "$kver"

  run install -m 644 "$img" "/boot/vmlinuz-$kver"
  run mkdir -p "/boot/dtb-$kver/qcom"
  run install -m 644 "$dtb" "/boot/dtb-$kver/qcom/$dtbname"

  # --no-hostonly matters: a host-only initramfs left out the PCIe/NVMe/clock
  # drivers and the boot hung waiting for the root disk.
  run dracut -f --no-hostonly --kver "$kver" "/boot/initramfs-$kver.img"
  if [ "$DRY" != 1 ]; then
    if have lsinitrd; then
      c=$(lsinitrd "/boot/initramfs-$kver.img" | grep -c 'nvme' || true)
      [ "$c" -gt 0 ] || die "initramfs has no nvme module; it would not find the root disk"
      note "initramfs check passed ($c nvme entries)"
    else
      warn "lsinitrd not found; could not verify the initramfs contents"
    fi
  fi

  [ "$NO_BOOTLOADER" = 1 ] && { note "skipping bootloader (--no-bootloader)"; return 0; }
  boot_entry "$kver" "$dtbname"
}

boot_entry() {
  kver=$1; dtbname=$2
  title="OmniBook 3 Linux $kver"
  say "Bootloader entry: $title"
  if have grubby; then
    if ! run grubby --add-kernel="/boot/vmlinuz-$kver" --initrd="/boot/initramfs-$kver.img" \
         --title="$title" --copy-default --devicetree="/boot/dtb-$kver/qcom/$dtbname"; then
      warn "grubby failed; add the entry by hand (kernel, initrd, devicetree)"
    fi
    return 0
  fi
  if have grub2-mkconfig || have grub-mkconfig; then
    have findmnt || die "findmnt (util-linux) is required to write a GRUB entry"
    root_uuid=${ROOT_UUID:-$(findmnt -no UUID /)}
    boot_uuid=${BOOT_UUID:-$(findmnt -no UUID --target /boot)}
    [ -n "$root_uuid" ] && [ -n "$boot_uuid" ] || die "could not read UUIDs; set ROOT_UUID and BOOT_UUID"
    if [ "$(findmnt -no TARGET --target /boot)" = "/boot" ]; then prefix=""; else prefix="/boot"; fi
    rflags=${ROOT_FLAGS:-}
    if [ -z "$rflags" ] && [ "$(findmnt -no FSTYPE /)" = btrfs ]; then
      fsroot=$(findmnt -no FSROOT /)
      rflags="rootflags=subvol=${fsroot#/}"
    fi
    f=/etc/grub.d/42_omnibook3
    if [ "$DRY" = 1 ]; then
      note "[dry-run] would write $f and regenerate grub.cfg"
    else
      {
        printf '#!/bin/sh\nexec tail -n +3 $0\n'
        printf '# Generated by omnibook3-setup.sh\n'
        printf 'menuentry "%s" {\n' "$title"
        printf '    search --no-floppy --fs-uuid --set=root %s\n' "$boot_uuid"
        printf '    devicetree %s/dtb-%s/qcom/%s\n' "$prefix" "$kver" "$dtbname"
        printf '    linux %s/vmlinuz-%s root=UUID=%s ro %s\n' "$prefix" "$kver" "$root_uuid" "$rflags"
        printf '    initrd %s/initramfs-%s.img\n' "$prefix" "$kver"
        printf '}\n'
      } > "$f"
      chmod 755 "$f"
      if [ -d /boot/grub2 ]; then cfg=/boot/grub2/grub.cfg; else cfg=/boot/grub/grub.cfg; fi
      if have grub2-mkconfig; then grub2-mkconfig -o "$cfg"; else grub-mkconfig -o "$cfg"; fi
    fi
    return 0
  fi
  warn "no grubby or GRUB found. For systemd-boot, create an entry like:"
  cat <<EOF
      title      $title
      linux      /vmlinuz-$kver
      initrd     /initramfs-$kver.img
      devicetree /dtb-$kver/qcom/$dtbname
      options    root=UUID=<your root UUID> rw
  (the files above must be on the EFI system partition)
EOF
}

# ------------------------------------------------------------------ Export
stage_export() {
  [ -n "$BUNDLE" ] || BUNDLE=./omnibook3-bundle
  say "Export: collecting known-good files into $BUNDLE"
  mkdir -p "$BUNDLE"

  fwd=$FW_DIR/ath11k/WCN6855/hw2.1
  if [ -f "$fwd/board-2.bin" ]; then
    cp -p "$fwd/board-2.bin" "$BUNDLE/board-2.bin"; note "wifi: board-2.bin"
  else
    warn "no plain $fwd/board-2.bin installed; run the wifi stage here first"
  fi

  if t=$(find_fw "$FW_DIR/qcom/x1e80100/$TPLG_NAME"); then
    cp -p "$t" "$BUNDLE/"; note "audio: $(basename "$t")"
  else
    warn "no $TPLG_NAME installed on this machine"
  fi

  {
    echo "exported:   $(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo "kernel:     $(uname -r)"
    if [ -r /proc/device-tree/model ]; then
      echo "dt model:   $(tr -d '\0' < /proc/device-tree/model)"
    else
      echo "dt model:   unknown"
    fi
    echo "cmdline:    $(cat /proc/cmdline 2>/dev/null || echo unknown)"
    echo "ucm card:   $(card_longname 2>/dev/null)"
    echo "ucm link:   $UCM_PROFILE"
  } > "$BUNDLE/INFO.txt"
  note "wrote INFO.txt"

  if [ -r /proc/config.gz ]; then cp /proc/config.gz "$BUNDLE/config.gz"
  elif [ -r "/boot/config-$(uname -r)" ]; then cp "/boot/config-$(uname -r)" "$BUNDLE/config"
  fi

  if [ -n "$KERNEL_DIR" ]; then
    [ -d "$KERNEL_DIR" ] || die "--kernel-dir is not a directory: $KERNEL_DIR"
    for f in Image modules.tar.gz config; do
      [ -f "$KERNEL_DIR/$f" ] && cp -p "$KERNEL_DIR/$f" "$BUNDLE/$f" && note "kernel: $f"
    done
    for f in "$KERNEL_DIR"/*omnibook-3-oled*.dtb; do
      [ -f "$f" ] && cp -p "$f" "$BUNDLE/" && note "kernel: $(basename "$f")"
    done
  fi
  say "Bundle ready: copy $BUNDLE to the other machine."
}

# -------------------------------------------------------------------- main
need_arg() { [ "$2" -ge 2 ] || die "$1 needs a value"; }

while [ $# -gt 0 ]; do
  case $1 in
    --bundle)       need_arg "$1" $#; BUNDLE=$2; shift ;;
    --kernel-dir)   need_arg "$1" $#; KERNEL_DIR=$2; shift ;;
    --board-bin)    need_arg "$1" $#; BOARD_BIN=$2; shift ;;
    --tplg)         need_arg "$1" $#; TPLG=$2; shift ;;
    --bdencoder)    need_arg "$1" $#; BDENCODER=$2; shift ;;
    --install-deps) INSTALL_DEPS=1 ;;
    --no-bootloader) NO_BOOTLOADER=1 ;;
    --force)        FORCE=1 ;;
    --dry-run)      DRY=1 ;;
    -h|--help)      usage; exit 0 ;;
    all)            STAGES="$STAGES wifi audio" ;;
    wifi|audio|kernel|export) STAGES="$STAGES $1" ;;
    *)              die "unknown argument: $1 (try --help)" ;;
  esac
  shift
done
[ -n "$STAGES" ] || { usage; exit 1; }

if [ -z "$FW_DIR" ]; then
  if [ -d /lib/firmware ]; then FW_DIR=/lib/firmware; else FW_DIR=/usr/lib/firmware; fi
fi

WORK=$(mktemp -d)
trap cleanup EXIT INT TERM

# Use the bundle for anything not given explicitly.
if [ -n "$BUNDLE" ] && [ -d "$BUNDLE" ]; then
  if [ -z "$BOARD_BIN" ] && [ -f "$BUNDLE/board-2.bin" ]; then BOARD_BIN=$BUNDLE/board-2.bin; fi
  if [ -z "$TPLG" ]; then
    for t in "$BUNDLE/$TPLG_NAME" "$BUNDLE/$TPLG_NAME.xz" "$BUNDLE/$TPLG_NAME.zst"; do
      if [ -f "$t" ]; then TPLG=$t; break; fi
    done
  fi
fi

case " $STAGES " in
  *" export "*) : ;;
  *) if [ "$DRY" != 1 ] && [ "$(id -u)" != 0 ]; then die "run as root (or use --dry-run)"; fi ;;
esac

[ "$INSTALL_DEPS" = 1 ] && install_deps

for s in $STAGES; do
  case $s in
    wifi)   stage_wifi ;;
    audio)  stage_audio ;;
    kernel) stage_kernel ;;
    export) stage_export ;;
  esac
done

say "Done. Reboot, then check:"
note "dmesg | grep -iE 'ath11k|tplg'   nmcli device wifi list   wpctl status"
