# omisetup-all.sh: HP OmniBook 3 (14-hz0) Wi-Fi and Sound Setup

`omisetup-all.sh` gets Wi-Fi and sound working in Linux on the HP OmniBook 3 Laptop 14-hz0xxx (Qualcomm Snapdragon X Plus, X1P42100). It runs on Ubuntu/Debian, Fedora, Arch, openSUSE and their relatives. It assumes Linux already **boots** on the laptop.

## Quick start

From the `setup` folder:

```sh
./omisetup-all.sh                # 1. preview: checks everything, changes nothing
sudo ./omisetup-all.sh --deps    # 2. install the tools it needs (only if step 1 says some are missing)
sudo ./omisetup-all.sh --apply   # 3. fix Wi-Fi and sound
sudo reboot
./omisetup-all.sh --status       # 4. after the reboot: is it working?
```

| Mode | Needs `sudo`? | What it does |
| --- | --- | --- |
| *(none)*, preview | No | Checks your system and prints what `--apply` would do. Changes nothing. |
| `--deps` | Yes | Installs `git`, `python3`, `m4`, `alsa-utils`, `zstd` and `xz` with your package manager. |
| `--apply` | Yes | Makes the Wi-Fi and sound changes. |
| `--status` | No | After a reboot, says whether Wi-Fi and sound work. Read only. |
| `--undo` | Yes | Removes everything the script added. |

| Extra option | What it does |
| --- | --- |
| `--only wifi` / `--only audio` | Do just one part. |
| `--legacy-audio` | Use the older borrowed sound setup (Surface Laptop 7 diagram + ThinkPad T14s recipe). |
| `--no-initramfs` | Don't rebuild the starter system in `/boot`. The script prints the command to run yourself instead. |

**Speaker safety:** keep speaker volume at about half until you know it sounds clean. These speaker amplifiers can be driven too hard.

## Which distros it works on

The script works out your distro family from 2 things: its package manager (the tool that installs software) and its starter-kit (initramfs) tool. Nothing else about your distro matters.

| Distro family | Package manager | Starter-kit file | Starter-kit tool | Tested? |
| --- | --- | --- | --- | --- |
| Ubuntu, Debian, Mint, Pop!\_OS | `apt` | `/boot/initrd.img-<version>` | `update-initramfs` | **Yes**: Ubuntu Concept for Snapdragon |
| Fedora, RHEL-likes | `dnf` | `/boot/initramfs-<version>.img` | `dracut` | No |
| openSUSE | `zypper` | `/boot/initrd-<version>` | `dracut` | No |
| Arch, EndeavourOS, Manjaro | `pacman` | `/boot/initramfs-linux*.img` | `mkinitcpio` | No |

If your distro isn't listed, the script still works as long as the tools below are installed. It just can't rebuild the starter kit itself. It prints what to do instead.

### What it needs

- **To run the script:** `git` (downloads the helper files), `python3` (runs Qualcomm's Wi-Fi tool), `m4` and `alsatplg` (build the sound wiring diagram), and `zstd` or `xz` (unpack compressed firmware).
- **Your distro's own packages:** `linux-firmware` (the Qualcomm parts), `alsa-ucm-conf`, `pipewire` and `wireplumber`.

`--deps` installs the tools for you. `alsatplg` is part of `alsa-utils` on Ubuntu and Arch. On some distros it's a separate package. The script warns you if it's still missing.

The Wi-Fi and sound parts download from GitHub, so you need a working internet connection. If you don't have Wi-Fi yet, use a USB Ethernet adapter, or phone tethering over USB. A wrong system clock makes downloads fail; fix it with `sudo timedatectl set-ntp true`.

## The Wi-Fi part

**The problem:** the Wi-Fi chip (Qualcomm WCN6855, driver `ath11k`) won't turn on until it loads a small settings file called "board data". Linux keeps the settings for hundreds of laptops in one file, `board-2.bin`, like a phone book with one entry per laptop. The driver looks up this laptop's entry:

```
bus=pci,vendor=17cb,device=1103,subsystem-vendor=103c,subsystem-device=8d9a,qmi-chip-id=18,qmi-board-id=255
```

(`103c` means HP.) That entry isn't in the phone book, so `dmesg` shows `failed to fetch board data` and there's no Wi-Fi.

**The fix:** add this laptop's name to the chip's generic entry, the same settings Windows uses on this laptop. No settings are made up. The same settings just get a second name tag.

The steps `--apply` takes:

1. **Check:** find your distro's `board-2.bin` (it may be compressed as `.zst` or `.xz`, or be a shortcut, as on Ubuntu). If it already has this laptop's name, a newer `linux-firmware` has fixed it, and the script skips the Wi-Fi part.
2. **Get the tool:** download Qualcomm's free `ath11k-bdencoder` tool from `qca/qca-swiss-army-knife` on GitHub, into a temporary folder.
3. **Unpack a copy:** turn the copy into a list of names (`board-2.json`) plus one small file per set of settings.
4. **Add the name:** a 10-line Python program adds this laptop's name next to the generic entry.
5. **Repack and double-check:** pack it back into one file, unpack it again, and confirm the name is really there.
6. **Install:** save it as `/lib/firmware/updates/ath11k/WCN6855/hw2.1/board-2.bin`. Linux checks `/lib/firmware/updates/` before `/lib/firmware/`, so this copy wins, and your distro's file is never touched.
7. **Starter kit:** rebuild the initramfs if it carries its own copy of the old phone book (see below).

Don't reload the Wi-Fi driver by hand with `modprobe` to test it. On this laptop, that has crashed the Wi-Fi chip. Reboot instead.

## The sound part

**The problem:** sound runs through a small helper processor, the audio DSP. Linux needs 2 extra pieces for it:

| Piece | What it is | Why it's missing |
| --- | --- | --- |
| **Topology** (wiring diagram) | Tells the DSP which outputs and inputs exist (speakers, headphones, mics, display outputs) and how sound flows between them. Linux asks for `qcom/x1e80100/X1E80100-HP-OMNIBOOK-3-tplg.bin`. | No file with that name ships yet, so the sound card can't start. |
| **UCM recipe** | Tells PipeWire, your desktop's sound system, which switches to flip for Speakers, Headphones and Microphone. | Without the right one, you get no sound devices, or sound that stops working. |

**The fix:** use the wiring diagram and recipe Jens Glathe (jglathe) made for the Lenovo IdeaPad Slim 3 15Q8X10. It has the same chip and the same layout: 2 speakers, headphones, 2 mics, display outputs.

His diagram gives each output its **own path**. Older borrowed diagrams share paths between outputs. Then one output can fail to open because another isn't ready, and PipeWire doesn't recover, so sound works and then stops. This is the setup that fixed sound on the tested laptop.

The steps `--apply` takes:

1. **Download** exact, pinned versions of his 2 repositories, so the script always installs the same files that were tested:
   - `jglathe/audioreach-topology`, commit `a737c27`
   - `jglathe/alsa-ucm-conf`, commit `6e1a6d7`
2. **Build the diagram:** `m4` fills in the template, then `alsatplg` compiles it into the `.bin` file Linux loads.
3. **Prepare the recipe:** copy his 2 recipe files under **new names of our own** (`HP-OmniBook3.conf`, `HP-OmniBook3-HiFi.conf`), so they never clash with your distro's files.
4. **Check it fits:** the recipe uses about 20 small helper files from your distro's `alsa-ucm-conf`. If any is missing, the script stops before changing anything and tells you to update `alsa-ucm-conf`.
5. **Install:** save the diagram as `/lib/firmware/updates/qcom/x1e80100/X1E80100-HP-OMNIBOOK-3-tplg.bin` and the recipe in `/usr/share/alsa/ucm2/Qualcomm/x1e80100/`. Then add a shortcut named after your sound card in `/usr/share/alsa/ucm2/conf.d/x1e80100/` that points to the recipe.

**Known limit:** this laptop has 3 display-audio outputs; the IdeaPad diagram covers 2 of them. Sound over one of the display connections may not work. Speakers, headphones and mics do.

## The starter kit (initramfs)

The initramfs is a small starter system in `/boot`. It loads drivers before your main disk is ready. Some distros pack a copy of the Wi-Fi firmware into it. Then the Wi-Fi driver starts early, reads the **old** phone book from the starter kit, and never sees the fixed copy on disk. On the tested Ubuntu laptop, this is why Wi-Fi still failed until the starter kit was rebuilt.

So after installing the Wi-Fi fix, the script:

1. **Looks inside** the starter kit with your distro's read-only listing tool (`lsinitramfs`, `lsinitrd` or `lsinitcpio`).
2. **If it carries Wi-Fi firmware,** saves a backup of each starter-kit file (ending in `.before-omisetup`), then rebuilds it with your distro's own tool:

| Style | Rebuild command | Extra safety |
| --- | --- | --- |
| Ubuntu/Debian | `update-initramfs -u -k <version>` | Puts the backup back if the command fails. |
| dracut (Fedora, openSUSE) | `dracut -f --no-hostonly --kver <version>` | Builds a new file first. Only swaps it in if the disk driver (`nvme`) is inside, so the laptop can still find its disk at boot. |
| Arch (mkinitcpio) | `mkinitcpio -P` | Puts the backups back if the command fails. |

3. **If it doesn't carry Wi-Fi firmware,** nothing needs doing.
4. **If it can't tell** (an unusual distro), it prints the command to run yourself.

`--no-initramfs` skips the rebuild and prints the command instead. `--undo` rebuilds it again, so the starter kit goes back to the original phone book too.

If the laptop won't boot after a rebuild, pick an older kernel in the boot menu. Then copy the `.before-omisetup` backup over the starter-kit file.

## What it changes, undo, and troubleshooting

The complete list of what `--apply` adds. Nothing else on your system changes:

| Part | File |
| --- | --- |
| Wi-Fi | `/lib/firmware/updates/ath11k/WCN6855/hw2.1/board-2.bin` |
| Sound | `/lib/firmware/updates/qcom/x1e80100/X1E80100-HP-OMNIBOOK-3-tplg.bin` |
| Sound | `/usr/share/alsa/ucm2/Qualcomm/x1e80100/HP-OmniBook3.conf` and `HP-OmniBook3-HiFi.conf` |
| Sound | `/usr/share/alsa/ucm2/conf.d/x1e80100/<sound card name>.conf`, a shortcut |
| Starter kit | the initramfs in `/boot`, only if it carries Wi-Fi firmware (backup kept) |

**Undo:** `sudo ./omisetup-all.sh --undo` removes all of the above, rebuilds the starter kit if needed, and then you reboot. It only removes a sound shortcut if this script (or the older `fix-audio.sh` / `omnibook3-setup.sh`) made it. If a shortcut made by something else is in the way, `--apply` stops instead of replacing it.

**After a distro update:** the fixes live in folders updates don't touch, so they keep working. If a future `linux-firmware` already knows this laptop, the preview says so. Then remove the Wi-Fi copy with `sudo ./omisetup-all.sh --undo --only wifi`.

### Troubleshooting

| What you see | What to do |
| --- | --- |
| `missing tools: ...` | Run `sudo ./omisetup-all.sh --deps`. |
| A download fails | Check the internet connection and the clock: `sudo timedatectl set-ntp true`. |
| No Wi-Fi after reboot | `sudo dmesg \| grep -i ath11k`. If it still says `failed to fetch board data`, the starter kit wasn't rebuilt. Run the rebuild command the script printed. If the name it asks for differs from the one above, change `WIFI_NEW_NAME` at the top of the script. |
| No sound card | `sudo dmesg \| grep -iE 'tplg\|q6apm\|snd'`. |
| Sound card, but no outputs or "Dummy Output" | As your normal user: `systemctl --user restart wireplumber pipewire`. |
| `your alsa-ucm-conf is too old` | Update your system, or use `--legacy-audio`. |

## Credits and words used here

- **Sound wiring diagram and recipe:** Jens Glathe, [audioreach-topology](https://github.com/jglathe/audioreach-topology/tree/jg/x1-lenovo-ideapad-slim3) and [alsa-ucm-conf](https://github.com/jglathe/alsa-ucm-conf/tree/jg/x1-lenovo-ideapad-slim3), branch `jg/x1-lenovo-ideapad-slim3`.
- **Wi-Fi tool:** Qualcomm, [qca-swiss-army-knife](https://github.com/qca/qca-swiss-army-knife) (`ath11k-bdencoder`).

| Word | Meaning |
| --- | --- |
| Firmware | Small programs or settings files that hardware loads to start working. Kept in `/lib/firmware`. |
| `/lib/firmware/updates` | A folder Linux checks before `/lib/firmware`. Files here override the distro's without changing them. |
| Driver | The part of Linux that talks to one piece of hardware (for Wi-Fi: `ath11k`). |
| Board data / `board-2.bin` | Per-laptop Wi-Fi settings, bundled into one file with a name label for each laptop. |
| DSP | A small helper processor. The audio DSP handles sound. |
| Topology | A wiring diagram telling the audio DSP which inputs and outputs exist. |
| UCM recipe | Tells the sound system which switches to flip for speakers, headphones and mic. |
| Initramfs | The small starter system in `/boot` that loads drivers early in boot. |
| Symlink | A shortcut: a file that points to another file. |
| Commit (pinned) | One exact saved version of a git repository, named by an ID like `a737c27`. |
| `sudo` | Run a command as administrator. Needed to change system folders. |
