#!/usr/bin/env bash

# Build Anolis OS 23.4 LXC rootfs images.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lxc-build-common.sh
source "$SCRIPT_DIR/lxc-build-common.sh"

version="23.4"
architectures=(x86_64 aarch64 riscv64 loongarch64)
mirror_base="https://mirror.nju.edu.cn/anolis"
rootfs_date="$(date +%Y%m%d)"
output_dir="$SCRIPT_DIR/lxcs/anolis"
failures=0

trap 'printf "Interrupted by user\n" >&2; exit 130' INT TERM
run mkdir -p "$output_dir"

build_image() (
    local arch=$1 repo_url=$2 output_file=$3 temp_dir rootfs
    temp_dir="$(mktemp -d)" || exit 1
    trap 'rm -rf -- "$temp_dir"' EXIT
    rootfs="$temp_dir/rootfs"

    run mkdir -p "$rootfs/var/lib/rpm" "$rootfs/etc/yum.repos.d"
    run rpm --root "$rootfs" --initdb
    copy_resolv_conf "$rootfs"
    write_file "$rootfs/etc/yum.repos.d/anolis-build.repo" <<EOF
[anolis-build]
name=AnolisOS ${version} BaseOS
baseurl=${repo_url}
enabled=1
gpgcheck=0
EOF

    run dnf --installroot="$rootfs" --forcearch="$arch" --releasever="$version" \
        --disablerepo='*' --enablerepo=anolis-build \
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

echo "Total builds: ${#architectures[@]}"
current=0
for arch in "${architectures[@]}"; do
    current=$((current + 1))
    repo_url="$mirror_base/$version/os/$arch/os"
    output_file="$output_dir/anolis-${version}-${rootfs_date}_${arch}.tar.xz"

    if [[ -s "$output_file" ]]; then
        echo "[$current/${#architectures[@]}] Skipped (exists): anolis $version $arch"
        continue
    fi

    echo "[$current/${#architectures[@]}] Building: anolis $version $arch"
    if build_image "$arch" "$repo_url" "$output_file"; then
        echo "[$current/${#architectures[@]}] Success: $(basename "$output_file")"
    else
        echo "[$current/${#architectures[@]}] Failed: anolis $version $arch" >&2
        failures=$((failures + 1))
    fi
done

if (( failures > 0 )); then
    echo "Build completed with $failures failure(s)." >&2
    exit 1
fi
echo "Build complete."
