#!/usr/bin/env bash

# Build a Loongnix Server 23.1 LXC rootfs image.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lxc-build-common.sh
source "$SCRIPT_DIR/lxc-build-common.sh"

version="23.1"
arch="loongarch64"
repo_url="https://pkg.loongnix.cn/loongnix-server/${version}/os/${arch}"
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
    temp_dir="$(mktemp -d)" || exit 1
    trap 'rm -rf -- "$temp_dir"' EXIT
    rootfs="$temp_dir/rootfs"

    run mkdir -p "$rootfs/var/lib/rpm" "$rootfs/etc/yum.repos.d"
    run rpm --root "$rootfs" --initdb
    copy_resolv_conf "$rootfs"
    write_file "$rootfs/etc/yum.repos.d/loongnix-build.repo" <<EOF
[loongnix-build]
name=Loongnix Server ${version} Base
baseurl=${repo_url}
enabled=1
gpgcheck=0
EOF

    run dnf --installroot="$rootfs" --forcearch="$arch" --releasever="$version" \
        --disablerepo='*' --enablerepo=loongnix-build \
        install -y --nogpgcheck --allowerasing \
        glibc gcc yum systemd systemd-pam net-tools iproute iputils hostname \
        openssh-server openssh-clients curl passwd fontconfig nano glibc-locale-source

    run chroot "$rootfs" localedef -c -f UTF-8 -i en_US en_US.UTF-8
    write_file "$rootfs/etc/hostname" <<'EOF'
localhost
EOF
    write_file "$rootfs/etc/sysconfig/network" <<'EOF'
NETWORKING=yes
HOSTNAME=localhost
EOF
    write_file "$rootfs/etc/locale.conf" <<'EOF'
LANG=en_US.UTF-8
EOF
    write_file "$rootfs/etc/resolv.conf" <<'EOF'
nameserver 8.8.8.8
nameserver 114.114.114.114
EOF

    run chroot "$rootfs" ssh-keygen -A
    run systemctl --root="$rootfs" enable sshd
    run chroot "$rootfs" passwd -d root
    clean_rootfs_devices "$rootfs"
    clean_rpm_cache "$rootfs"
    run tar -C "$rootfs" -cJf "$output_file" .
)

echo "Building: loongnix $version $arch"
if build_image; then
    echo "Success: $(basename "$output_file")"
else
    echo "Failed: loongnix $version $arch" >&2
    exit 1
fi
