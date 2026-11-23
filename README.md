# HP OmniBook 3 (14-hz0) – Linux setup files

Files for getting **Wi-Fi** and **sound** working in Linux on the
HP OmniBook 3 Laptop 14-hz0xxx (Qualcomm Snapdragon X Plus, X1P42100, OLED).

## Quick start

Always preview first. Preview mode only reads files and prints what it would do.

```sh
./fix-wifi.sh                 # preview
sudo ./fix-wifi.sh --apply    # do it

./fix-audio.sh                # preview
sudo ./fix-audio.sh --apply   # do it

sudo reboot
```

Undo either fix with `sudo ./fix-wifi.sh --undo` or `sudo ./fix-audio.sh --undo`.

> **Status:** both scripts pass a syntax check, but they haven't been run on a
> real laptop yet. Run the preview first and read what it says.

> **Speaker safety:** the sound settings are borrowed from another laptop.
> Keep speaker volume at about half until you know it sounds clean.

## What's wrong, in one paragraph each

**Wi-Fi.** The Wi-Fi chip needs a "board data" settings file before it turns on.
Linux keeps these in one bundle, `board-2.bin`, labelled per laptop. This laptop's
label (`subsystem-vendor=103c,subsystem-device=8d9a`) isn't in it. `fix-wifi.sh`
makes a copy of the bundle, adds this laptop's label to the chip's generic
settings (the same ones Windows uses), and saves the copy in
`/lib/firmware/updates/`. Linux checks that folder first, so your distro's
original file is never changed.

**Sound.** Sound runs through a helper processor (the audio DSP). It needs a
"topology" file, a wiring diagram named after this laptop, and a UCM profile,
a recipe for PipeWire. `fix-audio.sh` copies the Surface Laptop 7 topology under
this laptop's name (or uses one you give it with `--tplg`), and adds a shortcut
so the laptop uses the ThinkPad T14s sound recipe.

## Files

| File | What it is |
| --- | --- |
| `fix-wifi.sh` | Wi-Fi fix. Commented line by line. Preview / `--apply` / `--undo`. |
| `fix-audio.sh` | Sound fix. Commented line by line. Preview / `--apply` / `--undo`. |
| `docs/old-script-explained.md` | Plain-language walkthrough of the old `omnibook3-setup.sh`. |
| `tools/dtb_firmware.py` | Read-only helper: lists the firmware files a `.dtb` asks for. |
| `tools/make-fake-folder.sh` | Builds a fake firmware folder for testing the scripts safely. |
| `x1p42100-hp-omnibook-3-oled.dtb` | Device tree: the hardware map Linux reads when it starts. |
| `omnibook3-setup.sh` | The old all-in-one script (wifi, audio, kernel, export). Kept for reference. |
| `qcom-firmware-extract` | Copies Qualcomm firmware from a Windows partition. Not needed for this setup, because the firmware comes from your distro's `linux-firmware`. |

## What each fix changes on your system

| Fix | Adds | Never touches |
| --- | --- | --- |
| Wi-Fi | `/lib/firmware/updates/ath11k/WCN6855/hw2.1/board-2.bin` | `/lib/firmware/ath11k/...` (distro's file) |
| Sound | `/lib/firmware/updates/qcom/x1e80100/X1E80100-HP-OMNIBOOK-3-tplg.bin` and the shortcut `/usr/share/alsa/ucm2/conf.d/x1e80100/<card name>.conf` | Any existing file |

## Needs

`linux-firmware` (with `ath11k` and `qcom/x1e80100`), `alsa-ucm-conf`,
`pipewire`, `wireplumber`, `python3`, and `git` (the Wi-Fi fix downloads
Qualcomm's free `ath11k-bdencoder` tool from GitHub).

## If it doesn't work

- Wi-Fi: `sudo dmesg | grep -i ath11k`. If the label it asks for differs from
  the one in `fix-wifi.sh`, change `NEW_NAME` at the top of the script.
- Wi-Fi: **the most common cause is the initramfs** (the starter system in
  `/boot`). If it carries its own copy of the Wi-Fi firmware, the driver reads
  that old copy. `fix-wifi.sh` checks this and tells you. Run
  `sudo ./fix-wifi.sh --apply --rebuild-initramfs` to rebuild it. It works with
  both Ubuntu (`/boot/initrd.img-*`, rebuilt with `update-initramfs`) and dracut
  (`/boot/initramfs-*.img`), and keeps a backup ending in `.before-fix-wifi`.
- Sound: `sudo dmesg | grep -iE 'tplg|q6apm|snd'`, then
  `systemctl --user restart wireplumber pipewire` as your normal user.
