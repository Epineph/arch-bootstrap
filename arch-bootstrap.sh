#!/usr/bin/env bash
# Create and enter the official Arch x86_64 bootstrap on an existing filesystem.
# Sources and operating limits are documented in README.md beside this script.
set -Eeuo pipefail
umask 077

RELEASE_FINGERPRINT=3E80CA1A8B89F69CBA57D98A76A5EF9054449A5C
MIRROR=https://geo.mirror.pkgbuild.com/iso
WORK=''

die() { printf 'arch-bootstrap: %s\n' "$*" >&2; exit 1; }
say() { printf 'arch-bootstrap: %s\n' "$*" >&2; }

usage() {
    cat <<'EOF'
Usage:
  sudo bash arch-bootstrap.sh [--release YYYY.MM.DD] /absolute/new-directory
  sudo bash arch-bootstrap.sh --enter /absolute/existing-bootstrap

Downloads the official x86_64 bootstrap, verifies its pinned release signature,
extracts into a NEW directory, mounts API filesystems privately, initializes
the Arch package keyring, and opens a root Bash shell. Exit to release mounts.
--enter reuses a directory successfully created by this script.

Requires an x86_64 Linux host, root with mount/PID namespace privileges, GNU tar,
zstd, GnuPG, curl with HTTPS, GNU coreutils/findutils, and util-linux tools.
The destination parent must exist on a writable, executable Linux filesystem.
For root extraction, its ancestors must be root-owned and not writable by
other users (root-owned sticky directories such as /tmp are allowed).

No partitioning, formatting, bootloader installation, or host package changes.
The chroot shares the host kernel, network, and devices; it is NOT a sandbox.
EOF
}

need() {
    local cmd
    for cmd in "$@"; do
        command -v "$cmd" >/dev/null 2>&1 || die "Required command missing: $cmd"
    done
}

parse_args() {
    MODE=create RELEASE='' DESTINATION=''
    while (($#)); do
        case $1 in
            --help|-h) usage; exit 0 ;;
            --enter) [[ $MODE == create ]] || die 'Repeated --enter'; MODE=enter ;;
            --release)
                (($# >= 2)) || die '--release requires YYYY.MM.DD'
                RELEASE=$2; shift
                [[ $RELEASE =~ ^[0-9]{4}\.[0-9]{2}\.[0-9]{2}$ ]] || die 'Invalid release date'
                ;;
            --*) die "Unknown option: $1" ;;
            *) [[ -z $DESTINATION ]] || die 'Supply exactly one destination'; DESTINATION=$1 ;;
        esac
        shift
    done
    [[ -n $DESTINATION && $DESTINATION == /* ]] || die 'Supply an absolute destination path'
    [[ $DESTINATION != *$'\n'* && $DESTINATION != *$'\t'* ]] || die 'Control characters in path'
    [[ $MODE != enter || -z $RELEASE ]] || die '--release cannot be combined with --enter'
}

check_ancestors() {
    local path=$1 owner permissions mode
    while :; do
        read -r owner permissions < <(stat -c '%u %a' -- "$path")
        [[ $owner == 0 ]] || die "Ancestor must be root-owned: $path"
        mode=$((8#$permissions))
        if (( (mode & 0022) && !(mode & 01000) )); then
            die "Ancestor is writable by other users: $path"
        fi
        [[ $path != / ]] || break
        path=${path%/*}
        [[ -n $path ]] || path=/
    done
}

check_destination() {
    local parent leaf fstype options
    parent=$(realpath -e -- "$(dirname -- "$DESTINATION")")
    [[ -d $parent ]] || die 'Destination parent must be a directory'
    leaf=$(basename -- "$DESTINATION")
    [[ $leaf != . && $leaf != .. && $leaf != / ]] || die 'Invalid destination name'
    ROOT=${parent%/}/$leaf
    check_ancestors "$parent"
    if [[ $MODE == create ]]; then
        [[ ! -e $ROOT && ! -L $ROOT ]] || die "Destination already exists; choose a new directory: $ROOT"
    else
        [[ -d $ROOT && ! -L $ROOT ]] || die 'Bootstrap must be a real directory'
        check_ancestors "$ROOT"
        [[ -f $ROOT/var/lib/arch-bootstrap/source ]] || die 'Not a bootstrap created by this script'
    fi
    fstype=$(findmnt -n -o FSTYPE -T "$parent")
    case $fstype in
        vfat|msdos|exfat|ntfs|ntfs3|fuseblk|iso9660|udf|squashfs)
            die "Use a Linux filesystem with Unix permissions and symlinks, not $fstype" ;;
    esac
    options=$(findmnt -n -o OPTIONS -T "$parent")
    case ,$options, in *,ro,*|*,noexec,*) die 'Destination filesystem is read-only or noexec' ;; esac
    PARENT=$parent
}

fetch() {
    curl --fail --location --show-error --silent --retry 3 --connect-timeout 20 \
        --proto '=https' --proto-redir '=https' --output "$2" "$1"
}

discover_release() {
    local listing=$1 line
    local pattern='href="archlinux-bootstrap-([0-9]{4}\.[0-9]{2}\.[0-9]{2})-x86_64\.tar\.zst"'
    while IFS= read -r line; do
        if [[ $line =~ $pattern ]]; then
            printf '%s\n' "${BASH_REMATCH[1]}"
            return 0
        fi
    done < "$listing"
    die 'Could not find a versioned bootstrap in the official mirror index; use --release'
}

verify_signature() {
    local key=$1 signature=$2 archive=$3 keyhome=$4 expected=$5 actual
    mkdir -m 700 -- "$keyhome"
    local -a gpg_cmd=(gpg --no-options --batch --no-autostart --homedir "$keyhome")
    "${gpg_cmd[@]}" --with-colons --show-keys "$key" > "$keyhome/key-info"
    actual=$(awk -F: '$1=="pub" {primary=1; next} primary && $1=="fpr" {print $10; primary=0}' "$keyhome/key-info")
    [[ $actual == "$expected" ]] || die 'Release key primary fingerprint does not match the pinned fingerprint'
    "${gpg_cmd[@]}" --import-options import-minimal --import "$key"
    "${gpg_cmd[@]}" --status-fd 1 --verify "$signature" "$archive" > "$keyhome/status"
    awk -v expected="$expected" '
        $2 ~ /^(BADSIG|ERRSIG|EXPSIG|EXPKEYSIG|REVKEYSIG|NO_PUBKEY|NODATA|FAILURE|ERROR)$/ {bad=1}
        $2=="VALIDSIG" && ($3==expected || $NF==expected) {valid=1}
        END {exit (!valid || bad)}
    ' "$keyhome/status" || die 'No valid, current signature from the pinned release key'
}

check_archive_layout() {
    local archive=$1 listing=$2 member has_root=false
    tar --zstd --list --file "$archive" > "$listing"
    [[ -s $listing ]] || die 'Archive is empty'
    while IFS= read -r member; do
        case $member in
            root.x86_64/) has_root=true ;;
            root.x86_64/*|pkglist.x86_64.txt|version) ;;
            *) die "Unexpected archive member: $member" ;;
        esac
        case /$member/ in */../*) die 'Parent traversal in archive' ;; esac
    done < "$listing"
    [[ $has_root == true ]] || die 'Archive is missing root.x86_64/'
}

create_bootstrap() {
    local archive available staged=$WORK/root
    available=$(df -Pm -- "$PARENT" | awk 'END {print $4}')
    if [[ ! $available =~ ^[0-9]+$ ]] || ((available < 1024)); then
        die 'At least 1 GiB of free space is required; more is recommended'
    fi
    if [[ -z $RELEASE ]]; then
        fetch "$MIRROR/latest/" "$WORK/index.html"
        RELEASE=$(discover_release "$WORK/index.html")
    fi
    archive=archlinux-bootstrap-${RELEASE}-x86_64.tar.zst
    say "Downloading $archive"
    fetch "$MIRROR/$RELEASE/$archive" "$WORK/$archive"
    fetch "https://archlinux.org/iso/$RELEASE/$archive.sig" "$WORK/$archive.sig"
    fetch "https://keyserver.ubuntu.com/pks/lookup?op=get&search=0x$RELEASE_FINGERPRINT" "$WORK/release-key.asc"
    verify_signature "$WORK/release-key.asc" "$WORK/$archive.sig" "$WORK/$archive" \
        "$WORK/gnupg" "$RELEASE_FINGERPRINT"
    check_archive_layout "$WORK/$archive" "$WORK/members"
    say "Verified release signature; extracting into $ROOT"
    # Build privately on the same filesystem; a failed extraction publishes no root.
    mkdir -m 700 -- "$staged"
    tar --zstd --extract --file "$WORK/$archive" --directory "$staged" \
        --strip-components=1 --numeric-owner --same-owner --same-permissions --acls --xattrs \
        -- root.x86_64/
    [[ -x $staged/usr/bin/bash && -d $staged/etc && ! -L $staged/etc ]] || die 'Extracted root is incomplete'
    # Use the bootstrap's dedicated resolver file as a temporary bind-mount target.
    rm -f -- "$staged/etc/resolv.conf"
    install -m 644 /dev/null "$staged/etc/resolv.conf"
    # pacman expands these placeholders when selecting a repository.
    # shellcheck disable=SC2016
    printf '%s\n' 'Server = https://geo.mirror.pkgbuild.com/$repo/os/$arch' > "$staged/etc/pacman.d/mirrorlist"
    install -d -m 700 -- "$staged/var/lib/arch-bootstrap"
    printf 'release=%s\narchive=%s\nsigner=%s\n' "$RELEASE" "$archive" "$RELEASE_FINGERPRINT" \
        > "$staged/var/lib/arch-bootstrap/source"
    # GNU mv -nT never merges or overwrites a destination created concurrently.
    mv --no-clobber --no-target-directory -- "$staged" "$ROOT"
    [[ ! -d $staged ]] || die 'Destination appeared during download; it was left untouched'
}

enter_session() {
    local root=$1 resolver=$2 entry
    # The caller already unshared mounts and made propagation recursively private.
    # A separate PID namespace prevents background chroot processes retaining mounts.
    mount --bind "$root" "$root"
    for entry in dev proc sys run tmp; do
        [[ -d $root/$entry && ! -L $root/$entry ]] || die "Unsafe/missing mount target: $entry"
    done
    mount -t proc -o nosuid,nodev,noexec proc "$root/proc"
    mount --rbind /dev "$root/dev"
    mount --make-rslave "$root/dev"
    mount --rbind /sys "$root/sys"
    mount --make-rslave "$root/sys"
    mount -t tmpfs -o nosuid,nodev,mode=755 tmpfs "$root/run"
    mount -t tmpfs -o nosuid,nodev,mode=1777 tmpfs "$root/tmp"
    [[ -f $root/etc/resolv.conf && ! -L $root/etc/resolv.conf ]] || die 'Expected a regular bootstrap /etc/resolv.conf'
    mount --bind "$resolver" "$root/etc/resolv.conf"
    mount -o remount,bind,ro "$root/etc/resolv.conf"
    say 'Entering Arch. Run pacman -Syu before installing packages. Exit to return to the host.'
    chroot "$root" /usr/bin/env -i HOME=/root USER=root LOGNAME=root \
        TERM="${TERM:-linux}" PATH=/usr/local/sbin:/usr/local/bin:/usr/bin \
        /bin/bash -c '
            set -e
            if [[ ! -f /var/lib/arch-bootstrap/keyring-ready ]]; then
                pacman-key --init
                pacman-key --populate archlinux
                : > /var/lib/arch-bootstrap/keyring-ready
            fi
            cd /root
            exec /bin/bash --login
        '
    # Returning destroys the namespace; Linux kills any remaining namespace PIDs.
}

cleanup_work() {
    # WORK only contains our downloads/resolver/keyring, never chroot mounts.
    if [[ -n $WORK && -d $WORK ]]; then rm -rf -- "$WORK"; fi
}

main() {
    parse_args "$@"
    ((EUID == 0)) || die 'Run with sudo or as root'
    [[ $(uname -s) == Linux && $(uname -m) == x86_64 ]] || die 'Requires an x86_64 Linux host'
    need awk basename bash cat chmod chroot cp df dirname findmnt flock install \
        mkdir mktemp mount mv realpath rm stat uname unshare
    check_destination
    # Fail before downloads/extraction if this container or host forbids namespaces.
    unshare --mount --pid --fork --kill-child --propagation private true \
        || die 'Mount/PID namespaces unavailable; run on a host with CAP_SYS_ADMIN'
    if [[ $MODE == create ]]; then
        need curl gpg tar zstd
        [[ $(tar --version) == *'GNU tar'* ]] || die 'GNU tar is required (install tar on Alpine)'
    fi
    WORK=$(mktemp -d "$PARENT/.arch-bootstrap-work.XXXXXXXX")
    trap cleanup_work EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM
    [[ $MODE != create ]] || create_bootstrap
    exec 9> "$ROOT/var/lib/arch-bootstrap/session.lock"
    flock --nonblock 9 || die 'This bootstrap already has an active session'
    cp -L -- /etc/resolv.conf "$WORK/resolv.conf"
    say "Bootstrap retained at $ROOT; temporary mounts exist only in this session"
    export -f enter_session die say
    # Positional parameters are expanded by Bash inside the new namespace.
    # shellcheck disable=SC2016
    unshare --mount --pid --fork --kill-child --propagation private -- \
        bash -c 'set -Eeuo pipefail; enter_session "$1" "$2"' \
        arch-bootstrap-session "$ROOT" "$WORK/resolv.conf"
}

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then
    main "$@"
fi
