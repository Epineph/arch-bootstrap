# Arch bootstrap from an existing Linux host

This creates a reusable Arch x86_64 userspace on an existing mounted Linux
filesystem, then opens a root Bash shell inside it. It works independently
of the host distribution's userspace, including Alpine's musl/BusyBox
environment once the listed host tools are installed. The running kernel
and hardware remain the host's. This is a bootstrap tool environment, not
a bootable installation or a virtual machine.

## Run it

On Alpine, install the host tools listed below; on other distributions,
install their equivalents. The script itself never changes host packages.

```sh
apk add --no-cache bash curl gnupg ca-certificates tar zstd coreutils \
  mount umount findmnt flock util-linux-misc
```

Alpine splits util-linux into command packages: `mount`, `findmnt`, and
`flock` are separate packages; `util-linux-misc` supplies `unshare`.
The empty `util-linux` parent package alone is insufficient. Package
contents can vary by Alpine release; the script checks required commands.

Choose a NEW directory under a root-owned path, for example:

```bash
sudo bash /home/heini/arch-bootstrap/arch-bootstrap.sh /srv/arch-bootstrap
```

When already root in Alpine, omit `sudo`. Use the path where you copied the
script; `/home/heini/...` is its location on the system where it was prepared.

The script discovers a versioned release in the official mirror's `latest/`
index once, then uses that release's fixed URLs for all downloads. To select
a particular release explicitly:

```bash
sudo bash /home/heini/arch-bootstrap/arch-bootstrap.sh \
  --release 2026.10.01 /srv/arch-bootstrap
```

Inside the shell, initialize/update the system before adding packages:

```bash
pacman -Syu
```

Use a full upgrade; `pacman -Sy` followed by installing selected packages
creates an unsupported partial upgrade. The script has already configured
an HTTPS mirror and initialized/populated the package signing keyring.

Exit the shell to return to the host. To reopen the retained bootstrap:

```bash
sudo bash /home/heini/arch-bootstrap/arch-bootstrap.sh --enter /srv/arch-bootstrap
```

The directory and its `/var/cache/pacman/pkg` survive exit/reboot when they
are on persistent storage. Temporary mounts and `/run`/`/tmp` do not.

## Host requirements

- x86_64 Linux with a kernel capable of running current Arch userspace.
  The CPU must support the instructions required by Arch. No emulation for
  ARM/macOS/Windows hosts is included.
- Real root privileges, including `CAP_SYS_ADMIN`, and enabled mount/PID
  namespaces. Restricted containers can deny these even to UID 0. The
  script checks namespace availability before downloading or extracting.
- Bash; HTTPS-capable curl and CA certificates; GnuPG; zstd; GNU tar;
  GNU coreutils; util-linux mount, findmnt, flock, and unshare.
- Internet access, working host DNS, and a correct clock for HTTPS/signatures.
- At least 1 GiB free for initial creation; allow several GiB for upgrades,
  added packages, caches, and future work. Free-space checks cannot guarantee
  that a later upgrade or concurrent workload will fit.

The destination's parent must already exist on a writable filesystem with
Unix permissions, symlinks, and executable files. ext4, XFS, and Btrfs are
typical choices. NTFS, FAT/exFAT, ISO9660, read-only mounts, and `noexec`
mounts are rejected. RAM-backed filesystems work but do not preserve the
bootstrap over reboot and consume RAM for the full extracted system.

The parent and its ancestors must be root-owned and not writable by other
users; root-owned sticky directories such as `/tmp` are allowed. This
prevents another user replacing a path during root extraction. A desktop
automount path under `/run/media/yourname` may therefore be rejected. Mount
the intended Linux data partition at a root-owned location such as
`/mnt/work` instead; do not change unrelated home-directory ownership.

## What the script verifies and mounts

The archive and detached signature are fetched over HTTPS. The public key
is checked against the pinned full primary fingerprint:

```text
3E80CA1A8B89F69CBA57D98A76A5EF9054449A5C
```

That fingerprint is independently published by Arch for Pierre Schmitz.
Verification uses an isolated temporary keyring, checks the signature's
signer, and rejects bad/expired/revoked signatures. An unrelated downloaded
key cannot establish trust. A future signer/key change stops the script;
review Arch's official announcements/profile before updating the pin.
The script does not provide an independent freshness/rollback guarantee
against a compromised release index or an explicitly selected old release.

Only after verification does GNU tar inspect and extract the archive with
numeric ownership. Extraction happens in a private staging directory on
the destination filesystem. The finished directory is moved into place
without overwriting an existing destination. Failure before publication
removes the staging directory; no incomplete destination is published.
Failure after publication retains the complete root for `--enter`.

The session runs inside new mount and PID namespaces with private mount
propagation:

| Path inside Arch | Session setup |
|---|---|
| `/` | Self bind of the extracted root |
| `/proc` | Fresh procfs for the session's PID namespace |
| `/dev` | Recursive bind, including `/dev/pts`; slave propagation |
| `/sys` | Recursive bind, including existing submounts; slave propagation |
| `/run` | Fresh tmpfs |
| `/tmp` | Fresh tmpfs with mode 1777 |
| `/etc/resolv.conf` | Read-only bind of a dereferenced copy of host DNS config |

After the shell exits, namespace processes are terminated and the temporary
mount namespace is released. An exclusive lock prevents simultaneous
sessions opened through this script against the same bootstrap.

A chroot is **not a security boundary**. This session has root privileges
and access to host devices and the host network. Commands you run inside
can change disks or firmware. The mount namespace protects the host's
mount topology; it does not isolate writes to underlying files/devices.

The script accepts directory paths only. It does not select a block device,
partition/format a drive, import a pool, install a kernel/bootloader, or
convert this bootstrap into a bootable Arch installation.

## Put the bootstrap and cache on extra USB storage

See [Alpine USB storage](alpine-usb-storage.md) for the distinction between
the raw-written ISO and a writable data filesystem. After the intended
Linux data partition has been mounted at `/mnt/work`, verify the mount:

```bash
findmnt --mountpoint /mnt/work -o TARGET,SOURCE,FSTYPE,OPTIONS
df -h /mnt/work
```

Then use its directory as the destination:

```bash
bash ./arch-bootstrap.sh /mnt/work/arch-bootstrap
```

The temporary release downloads/staging are created alongside the target,
so they use this filesystem instead of Alpine's RAM-backed `/tmp`.
Downloads are removed after use. The extracted system and its pacman cache
remain on the data filesystem. On a later boot, mount that same filesystem
and run `--enter /mnt/work/arch-bootstrap`.

## Why a mount is busy or read-only

`umount: target is busy` means something still holds a reference: a shell's
working directory, an open/mapped file, a process root (a chroot), or a
mount below the target. Merely opening a shell in `/mnt/work` can be enough.
Moving that shell elsewhere with `cd /` releases its working-directory
reference, but other processes or child mounts may remain.

Inspect before changing anything. Use an actual mountpoint for `-R`/`-M`:

```bash
findmnt -T /mnt/work -o TARGET,SOURCE,FSTYPE,VFS-OPTIONS,FS-OPTIONS,PROPAGATION
findmnt -R /mnt/work
sudo fuser -vmM /mnt/work
lsblk -o NAME,PATH,FSTYPE,RO,TYPE,MOUNTPOINTS
sudo dmesg | tail -n 80
```

On systemd hosts, `journalctl -k -b` is another source of kernel messages.
`fuser` is normally supplied by `psmisc`; it is diagnostic, not a script
dependency. It can miss holders in other mount namespaces.

Close/stop identified users cleanly, exit chroots, and release child mounts
in reverse order. Retry a normal unmount. `sync` flushes pending writes but
does not close files or release process working directories. Avoid routine
`fuser -k`, forced unmounts, or lazy unmounts. A lazy unmount hides the mount
while existing users may still access it; it is not a safe-removal signal.

Read-only state has several sources: mount flags, a filesystem-wide
read-only state, a read-only block device, a read-only format such as
ISO9660, or driver integrity checks. A writable remount only works when
the underlying filesystem/device supports it and permits the transition.
It does not grant Unix permissions or bypass a Windows hibernation lock.

`mount -t ntfs-3g` selects a userspace FUSE driver. `ntfs3` is a different
kernel driver; `-t` is not a conversion or a way to switch drivers on an
existing mount. NTFS-3G does not support remounting in place. Close users,
unmount normally, then mount again with the desired options if the volume
state permits it. A hibernated/Fast-Startup Windows volume should be
resumed and fully shut down from Windows, with Fast Startup disabled,
before Linux writes. `remove_hiberfile` discards the saved Windows session;
`ntfsfix` is not a general substitute for Windows filesystem checking.

If ext4 switches to read-only after errors, inspect the kernel messages
and preserve/recover data before deciding on repair. Do not run filesystem
repair on a mounted filesystem. Also, ext4 `ro` alone can replay a journal;
`ro,noload` avoids replay writes for inspection, but the filesystem may
present an inconsistent state. For failing/irreplaceable media, work from
a suitable image/clone rather than experimenting with the only copy.

The same principle explains live persistence across distros: a read-only
base plus a writable overlay is general. Boot-time discovery differs.
Debian's `/ union`, Ubuntu-family volume labels, ArchISO's boot options,
and Alpine's `.apkovl`/APK cache conventions are separate interfaces.
Alpine's `.apkovl` saves selected configuration; it is not an automatic
full-root persistent writable overlay.

## Validation and limits

Local verification includes Bash syntax, ShellCheck, unprivileged path and
mount-plan tests, real cryptographic positive/negative fixtures, and the
current official release's signature/archive-layout check. The tests never
mount host filesystems or enter the chroot. No privileged live-session or
Alpine VM smoke test has been performed; namespace teardown and package
initialization still need that integration test before unattended use.

```bash
bash -n arch-bootstrap.sh
shellcheck arch-bootstrap.sh
python3 test_arch_bootstrap.py -v
```

Tests require Python 3 and GnuPG with permission to start a temporary
test-only signing agent. They do not read or alter the user's GnuPG keyring.

## References

- [Arch Downloads](https://archlinux.org/download/)
- [Arch developer signing fingerprint](https://archlinux.org/people/developers/#pierre)
- [Install Arch Linux from existing Linux](https://wiki.archlinux.org/title/Install_Arch_Linux_from_existing_Linux)
- [util-linux mount](https://man7.org/linux/man-pages/man8/mount.8.html)
- [Linux mount namespaces](https://man7.org/linux/man-pages/man7/mount_namespaces.7.html)
- [util-linux unshare](https://man7.org/linux/man-pages/man1/unshare.1.html)
- [NTFS-3G manual](https://github.com/tuxera/ntfs-3g/wiki/Manual)
- [Linux ext4 documentation](https://docs.kernel.org/admin-guide/ext4.html)
- [Alpine util-linux command packages](https://pkgs.alpinelinux.org/package/edge/main/x86_64/util-linux-misc)
