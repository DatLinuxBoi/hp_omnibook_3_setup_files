# The old script, explained (`omnibook3-setup.sh`)

The old script does everything in one file. It's split into **stages** you
pick on the command line, for example `sudo ./omnibook3-setup.sh all`
(`all` = wifi + audio). `--dry-run` previews without changing anything.

## Settings at the top (lines 27–38)

Names the script uses later. Any of them can be overridden from the command line.

- `WIFI_NAME_NEW` – this laptop's Wi-Fi label (HP, `103c:8d9a`).
- `WIFI_NAME_SRC` – the generic label whose settings get reused.
- `TPLG_NAME` / `TPLG_DEFAULT_SRC` – the topology name Linux wants, and the
  Surface Laptop 7 file copied to make it.
- `UCM_PROFILE` / `UCM_LONGNAME_DEFAULT` – the borrowed ThinkPad T14s sound
  recipe, and this laptop's sound card name.

## Helpers (lines 45–99)

Small tools used by the stages: printing messages, checking whether a program
is installed, `run` (which only prints the command in `--dry-run` mode),
reading compressed firmware, and `--install-deps` (installs git, python3, xz,
zstd, kmod and dracut with your package manager).

## Stage `wifi` (lines 101–203)

Same idea as `fix-wifi.sh`: unpack `board-2.bin`, add HP's label to the
generic entry, repack, check. **Difference:** it **replaces your distro's
`board-2.bin` in place** (after saving a backup named
`board-2.bin.orig-omnibook3`), so a `linux-firmware` update can undo it.
`fix-wifi.sh` puts its copy in `/lib/firmware/updates/` instead.

## Stage `audio` (lines 205–257)

Same idea as `fix-audio.sh`: install the topology under the OmniBook name and
link the T14s UCM recipe. **Difference:** the topology goes next to your
distro's files, and old copies with the same name are deleted first.

## Stage `kernel` (lines 259–359) – only when you ask for it

For a new install: it unpacks a self-built Linux kernel (from the
`jglathe/linux_ms_dev_kit` source) and its modules, copies the device tree,
builds an initramfs with `dracut --no-hostonly`, and adds a boot-menu entry
(using grubby, a GRUB file named `/etc/grub.d/42_omnibook3`, or printed
instructions for systemd-boot).

What the terms mean:
- *kernel*: the core of Linux.
- *modules*: driver add-ons for the kernel.
- *initramfs*: a small starter system that loads drivers before your real disk is mounted.
- *`--no-hostonly`*: include all drivers, not just ones detected right now. Without it, the boot hung because the disk driver was missing.

The new files don't replace this stage. It's only for setting up the kernel.

## Stage `export` (lines 361–408)

Run it on a laptop where everything works. It copies the working
`board-2.bin`, the topology file, kernel info and (optionally) kernel files
into a folder, so another install can use the exact same files with `--bundle`.

## Main part (lines 410–467)

Reads the options, checks it's running as root, then runs each stage you asked for.

## `qcom-firmware-extract` (separate file)

Looks at the device tree for firmware the laptop needs, finds any that are
missing, and copies them from a Windows partition's driver store
(`Windows/System32/DriverStore/FileRepository`) into
`/usr/lib/firmware/updates`. It's written for Omarchy (an Arch-based setup).
Your old script's notes say it wasn't needed, because the firmware came from
your distro's `linux-firmware`.
