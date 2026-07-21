#!/usr/bin/env bash

# Build Debian LXC rootfs images for architectures not covered by the main builder.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lxc-build-common.sh
source "$SCRIPT_DIR/lxc-build-common.sh"

rootfs_date="$(date +%Y%m%d)"
output_dir="$SCRIPT_DIR/lxcs/debian"
builds=(
    "loong64:trixie"
    "loong64:bookworm"
    "loong64:sid"
    "ppc64el:bookworm"
    "ppc64el:trixie"
    "ppc64el:forky"
    "ppc64el:sid"
    "s390x:bookworm"
    "s390x:trixie"
    "s390x:forky"
    "s390x:sid"
)
failures=0

trap 'printf "Interrupted by user\n" >&2; exit 130' INT TERM
run mkdir -p "$output_dir"

mirror_for() {
    local arch=$1 version=$2
    if [[ "$arch" == loong64 ]]; then
        case "$version" in
            trixie) printf '%s\n' 'https://jp.mirrors.lierfang.com/debian-ports/trixie' ;;
            bookworm) printf '%s\n' 'https://jp.mirrors.lierfang.com/debian-ports/bookworm' ;;
            sid) printf '%s\n' 'https://mirror.nju.edu.cn/debian-ports' ;;
        esac
    else
        printf '%s\n' 'https://mirror.nju.edu.cn/debian'
    fi
}

build_image() (
    local arch=$1 version=$2 mirror=$3 output_file=$4 suite temp_dir rootfs
    temp_dir="$(mktemp -d)" || exit 1
    trap 'rm -rf -- "$temp_dir"' EXIT
    rootfs="$temp_dir/rootfs"
    suite="$version"
    [[ "$arch" == loong64 ]] && suite=sid

    if [[ "$arch" == loong64 ]]; then
        run debootstrap --foreign --arch="$arch" --variant=minbase --no-check-gpg \
            --include=openssh-server,iproute2,ifupdown,chrony,locales \
            --exclude=systemd-timesyncd "$suite" "$rootfs" "$mirror"
    else
        run debootstrap --foreign --arch="$arch" --variant=minbase \
            --include=openssh-server,iproute2,ifupdown,chrony,locales \
            --exclude=systemd-timesyncd "$suite" "$rootfs" "$mirror"
    fi
    copy_resolv_conf "$rootfs"
    run chroot "$rootfs" /debootstrap/debootstrap --second-stage

    write_file "$rootfs/etc/locale.gen" <<'EOF'
en_US.UTF-8 UTF-8
EOF
    write_file "$rootfs/etc/default/locale" <<'EOF'
LANG=en_US.UTF-8
EOF
    write_file "$rootfs/etc/network/interfaces" <<'EOF'
auto lo
iface lo inet loopback
EOF
    append_file "$rootfs/etc/ssh/sshd_config" <<'EOF'
PermitRootLogin yes
EOF
    write_file "$rootfs/etc/appliance.info" <<EOF
Name: debian
Version: ${version}
OS: debian
Section: system
Maintainer: Lierfang <itsupport@lierfang.com>
EOF
    run ln -sfn /usr/share/zoneinfo/UTC "$rootfs/etc/localtime"
    run rm -f -- "$rootfs/etc/mtab"
    run ln -s /proc/mounts "$rootfs/etc/mtab"

    run chroot "$rootfs" locale-gen en_US.UTF-8
    run chroot "$rootfs" dpkg --force-confold --skip-same-version --configure -a
    run chroot "$rootfs" usermod -L root
    run chroot "$rootfs" apt-get clean
    clean_rootfs_devices "$rootfs"
    clean_apt_cache "$rootfs"
    run tar -C "$rootfs" -cJf "$output_file" .
)

echo "Total builds: ${#builds[@]}"
current=0
for build in "${builds[@]}"; do
    current=$((current + 1))
    arch=${build%%:*}
    version=${build#*:}
    mirror="$(mirror_for "$arch" "$version")"
    output_file="$output_dir/debian-${version}-${rootfs_date}_${arch}.tar.xz"

    if [[ -s "$output_file" ]]; then
        echo "[$current/${#builds[@]}] Skipped (exists): debian $version $arch"
        continue
    fi
    echo "[$current/${#builds[@]}] Building: debian $version $arch (from $mirror)"
    if build_image "$arch" "$version" "$mirror" "$output_file"; then
        echo "[$current/${#builds[@]}] Success: $(basename "$output_file")"
    else
        echo "[$current/${#builds[@]}] Failed: debian $version $arch" >&2
        failures=$((failures + 1))
    fi
done

if (( failures > 0 )); then
    echo "Build completed with $failures failure(s)." >&2
    exit 1
fi
echo "Build complete."
