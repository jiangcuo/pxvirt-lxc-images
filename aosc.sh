#!/bin/bash
#
# AOSC OS LXC Image Build Script
# Supports: x86_64, loongarch64, riscv64, aarch64
#

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Version
VERSION="meow"

# Architectures to build
ARCHES=("amd64" "loongarch64" "riscv64" "arm64" "ppc64el")

# AOSCBootstrap binary path
AOSCBOOTSTRAP="${AOSCBOOTSTRAP:-aoscbootstrap}"

# Get date
rootfs_date=$(date +%Y%m%d)

# Output directory (following lxcs/<distro>/ pattern)
OUTPUT_BASE="$SCRIPT_DIR/lxcs/aosc"
mkdir -p "$OUTPUT_BASE"

# Create temporary config directory
CONFIG_DIR=$(mktemp -d)
trap "rm -rf $CONFIG_DIR" EXIT

# Create aosc-mainline.toml
cat > "$CONFIG_DIR/aosc-mainline.toml" << 'EOF'
stub-packages = [
  "aosc-aaa",
  "apt",
  "gcc-runtime",
  "tar",
  "xz",
  "gnupg",
  "grep",
  "ca-certs",
  "iptables",
  "shadow",
  "systemd",
  "keyutils"
]
base-packages = [
  "bash-completion",
  "bash-startup",
  "iana-etc",
  "libidn",
  "tzdata"
]
EOF

build_arch() {
    local arch=$1
    local temp_dir=$(mktemp -d)
    local rootfs="$temp_dir/rootfs"
    local output_file="$OUTPUT_BASE/aosc-${VERSION}-${rootfs_date}_${arch}.tar.xz"
    
    echo "========================================"
    echo "Building AOSC OS for architecture: $arch"
    echo "========================================"
    
    # Check if file already exists
    if [ -f "$output_file" ] && [ -s "$output_file" ]; then
        echo "Skipped (exists): $(basename "$output_file")"
        rm -rf "$temp_dir"
        return 0
    fi
    
    # Run aoscbootstrap
    echo "Running aoscbootstrap..."
    $AOSCBOOTSTRAP \
        --target "$rootfs" \
        --arch "$arch" \
        --config "$CONFIG_DIR/aosc-mainline.toml" \
        --include "network-base systemd-base"
    
    echo "Post-processing..."
    
    # Post-processing: Comment out uncommented lines in limits.conf (no spaces)
    local limits_file="$rootfs/etc/security/limits.conf"
    if [ -f "$limits_file" ]; then
        echo "Processing limits.conf..."
        # Comment out lines that are not empty, not commented, and contain no spaces
        sed -i '/^[^#[:space:]]\+[^[:space:]]*$/s/^/# /' "$limits_file"
    fi
    
    # Clean up /dev directory
    echo "Cleaning /dev directory..."
    rm -rf "$rootfs/dev/"* 2>/dev/null || true
    
    # Clean up APT cache
    rm -rf "$rootfs/var/cache/apt/archives/"*.deb 2>/dev/null || true
    
    # Package rootfs
    echo "Packaging: $(basename "$output_file")"
    tar -cJf "$output_file" -C "$rootfs" .
    
    if [ $? -eq 0 ]; then
        echo "Success: $(basename "$output_file")"
    else
        echo "Failed: $(basename "$output_file")"
        rm -f "$output_file"
    fi
    
    # Cleanup
    rm -rf "$temp_dir"
    
    echo "========================================"
}

# Build for all architectures
for arch in "${ARCHES[@]}"; do
    build_arch "$arch"
done

echo ""
echo "All builds complete! Output files:"
for arch in "${ARCHES[@]}"; do
    echo "  aosc-${VERSION}-${rootfs_date}_${arch}.tar.xz"
done
echo "Location: $OUTPUT_BASE/"
