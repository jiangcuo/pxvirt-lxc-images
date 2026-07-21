#!/usr/bin/env bash

# Shared helpers for LXC rootfs builders. This file is sourced by build scripts.

build_die() {
    local status=$?
    printf 'ERROR: %s\n' "$*" >&2
    exit "$status"
}

run() {
    "$@" || build_die "command failed: $*"
}

write_file() {
    local path=$1
    mkdir -p "$(dirname "$path")" || build_die "cannot create parent directory for $path"
    cat > "$path" || build_die "cannot write $path"
}

append_file() {
    local path=$1
    mkdir -p "$(dirname "$path")" || build_die "cannot create parent directory for $path"
    cat >> "$path" || build_die "cannot append $path"
}

copy_resolv_conf() {
    local rootfs=$1
    run install -Dm644 /etc/resolv.conf "$rootfs/etc/resolv.conf"
}

clean_rootfs_devices() {
    local rootfs=$1
    run mkdir -p "$rootfs/dev"
    run find "$rootfs/dev" -mindepth 1 -maxdepth 1 -exec rm -rf -- {} +
}

clean_rpm_cache() {
    local rootfs=$1
    run rm -rf -- "$rootfs/var/cache/dnf" "$rootfs/var/cache/yum"
}

clean_apt_cache() {
    local rootfs=$1
    run rm -rf -- "$rootfs/var/cache/apt/archives" "$rootfs/var/lib/apt/lists"
}
