#!/usr/bin/env bash

# Build openEuler LXC rootfs images for loongarch64.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lxc-build-common.sh
source "$SCRIPT_DIR/lxc-build-common.sh"

versions=(22.03-LTS 24.03-LTS)
arch="loongarch64"
mirror_base="https://mirror.nju.edu.cn/openeuler"
rootfs_date="$(date +%Y%m%d)"
output_dir="$SCRIPT_DIR/lxcs/openeuler"
failures=0

trap 'printf "Interrupted by user\n" >&2; exit 130' INT TERM
run mkdir -p "$output_dir"

build_image() (
    local version=$1 output_file=$2 temp_dir rootfs repo_prefix
    temp_dir="$(mktemp -d)" || exit 1
    trap 'rm -rf -- "$temp_dir"' EXIT
    rootfs="$temp_dir/rootfs"
    repo_prefix="$mirror_base/openEuler-$version"

    run mkdir -p "$rootfs/var/lib/rpm" "$rootfs/etc/yum.repos.d"
    run rpm --root "$rootfs" --initdb
    copy_resolv_conf "$rootfs"
    write_file "$rootfs/etc/yum.repos.d/openeuler-build.repo" <<EOF
[openeuler-os]
name=openEuler ${version} OS
baseurl=${repo_prefix}/OS/\$basearch/
enabled=1
gpgcheck=0

[openeuler-everything]
name=openEuler ${version} Everything
baseurl=${repo_prefix}/everything/\$basearch/
enabled=1
gpgcheck=0

[openeuler-epol]
name=openEuler ${version} EPOL
baseurl=${repo_prefix}/EPOL/main/\$basearch/
enabled=1
gpgcheck=0
EOF

    run dnf --installroot="$rootfs" --forcearch="$arch" --releasever="$version" \
        --disablerepo='*' --enablerepo=openeuler-os,openeuler-everything,openeuler-epol \
        install -y --nogpgcheck --allowerasing \
        glibc gcc yum systemd systemd-pam net-tools iproute iputils hostname \
        openssh-server openssh-clients curl passwd fontconfig nano glibc-locale-source

    run chroot "$rootfs" localedef -c -f UTF-8 -i en_US en_US.UTF-8
    write_file "$rootfs/etc/hostname" <<'EOF'
localhost
EOF
    write_file "$rootfs/etc/locale.conf" <<'EOF'
LANG=en_US.UTF-8
EOF
    write_file "$rootfs/etc/network/interfaces" <<'EOF'
auto lo
iface lo inet loopback
EOF
    append_file "$rootfs/etc/ssh/sshd_config" <<'EOF'
PermitRootLogin yes
PasswordAuthentication yes
EOF
    write_file "$rootfs/etc/resolv.conf" <<'EOF'
nameserver 8.8.8.8
nameserver 114.114.114.114
EOF
    write_file "$rootfs/etc/appliance.info" <<EOF
Name: openeuler
Version: ${version}
OS: openeuler
Section: system
Maintainer: Lierfang <itsupport@lierfang.com>
EOF

    run chroot "$rootfs" ssh-keygen -A
    run chroot "$rootfs" passwd -d root
    clean_rootfs_devices "$rootfs"
    clean_rpm_cache "$rootfs"
    run tar -C "$rootfs" -cJf "$output_file" .
)

echo "Total builds: ${#versions[@]}"
current=0
for version in "${versions[@]}"; do
    current=$((current + 1))
    output_file="$output_dir/openeuler-${version}-${rootfs_date}_${arch}.tar.xz"
    if [[ -s "$output_file" ]]; then
        echo "[$current/${#versions[@]}] Skipped (exists): openeuler $version $arch"
        continue
    fi
    echo "[$current/${#versions[@]}] Building: openeuler $version $arch"
    if build_image "$version" "$output_file"; then
        echo "[$current/${#versions[@]}] Success: $(basename "$output_file")"
    else
        echo "[$current/${#versions[@]}] Failed: openeuler $version $arch" >&2
        failures=$((failures + 1))
    fi
done

if (( failures > 0 )); then
    echo "Build completed with $failures failure(s)." >&2
    exit 1
fi
echo "Build complete."
