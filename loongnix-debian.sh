#!/usr/bin/env bash

# Build a Loongnix 25 (Debian based) LXC rootfs image.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lxc-build-common.sh
source "$SCRIPT_DIR/lxc-build-common.sh"

version="25"
arch="loong64"
suite="loongnix-stable"
mirror="https://pkg.loongnix.cn/loongnix/${version}"
rootfs_date="$(date +%Y%m%d)"
output_dir="$SCRIPT_DIR/lxcs/loongnix"
output_file="$output_dir/loongnix-${version}-${rootfs_date}_${arch}.tar.xz"

trap 'printf "Interrupted by user\n" >&2; exit 130' INT TERM
run mkdir -p "$output_dir"

if [[ -s "$output_file" ]]; then
    echo "Skipped (exists): loongnix $version $arch"
    exit 0
fi

build_image() (
    local temp_dir rootfs
    temp_dir="$(mktemp -d -p /var/tmp)" || exit 1
    trap 'rm -rf -- "$temp_dir"' EXIT
    rootfs="$temp_dir/rootfs"

    run debootstrap --foreign --arch="$arch" --variant=minbase --no-check-gpg \
        --include=openssh-server,iproute2,ifupdown,chrony,locales \
        --exclude=systemd-timesyncd "$suite" "$rootfs" "$mirror"
    copy_resolv_conf "$rootfs"
    run chroot "$rootfs" /debootstrap/debootstrap --second-stage

    write_file "$rootfs/etc/apt/sources.list" <<EOF
deb ${mirror} loongnix-stable main contrib non-free non-free-firmware
deb ${mirror} loongnix-updates main contrib non-free non-free-firmware
deb ${mirror} loongnix-backports main contrib non-free non-free-firmware
EOF
    run chroot "$rootfs" apt-get update
    write_file "$rootfs/etc/hostname" <<'EOF'
localhost
EOF
    write_file "$rootfs/etc/network/interfaces" <<'EOF'
auto lo
iface lo inet loopback

auto eth0
iface eth0 inet dhcp
EOF
    write_file "$rootfs/etc/locale.gen" <<'EOF'
en_US.UTF-8 UTF-8
EOF
    write_file "$rootfs/etc/default/locale" <<'EOF'
LANG=en_US.UTF-8
EOF
    write_file "$rootfs/etc/resolv.conf" <<'EOF'
nameserver 8.8.8.8
nameserver 114.114.114.114
EOF
    run ln -sfn /usr/share/zoneinfo/UTC "$rootfs/etc/localtime"

    run chroot "$rootfs" locale-gen
    run chroot "$rootfs" ssh-keygen -A
    run systemctl --root="$rootfs" enable ssh
    clean_rootfs_devices "$rootfs"
    clean_apt_cache "$rootfs"
    run rm -rf -- "$rootfs/debootstrap"
    run tar -C "$rootfs" -cJf "$output_file" .
)

echo "Building: loongnix $version $arch"
if build_image; then
    echo "Success: $(basename "$output_file")"
else
    echo "Failed: loongnix $version $arch" >&2
    exit 1
fi
