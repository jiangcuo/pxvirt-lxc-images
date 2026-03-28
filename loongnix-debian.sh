#!/bin/bash

# Loongnix OS (Debian系) LXC Image Build Script
# Version: 25 (loongnix-stable)
# Architecture: loong64

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Ctrl+C 信号处理
trap 'echo "Interrupted by user"; exit 130' SIGINT

# 配置
version="25"
arch="loong64"
suite="loongnix-stable"
mirror="https://pkg.loongnix.cn/loongnix/${version}"
rootfs_date=$(date +%Y%m%d)

# 确保输出目录存在
mkdir -p "$SCRIPT_DIR/lxcs/loongnix"

output_file="$SCRIPT_DIR/lxcs/loongnix/loongnix-${version}-${rootfs_date}_${arch}.tar.xz"

# 检查文件是否已存在
if [ -f "$output_file" ] && [ -s "$output_file" ]; then
    echo "Skipped (exists): loongnix $version $arch"
    exit 0
fi

echo "Building: loongnix $version $arch"

# 创建临时目录（使用 /var/tmp 避免 noexec 问题）
temp_dir=$(mktemp -d -p /var/tmp)
rootfs="$temp_dir/rootfs"

# 运行 debootstrap（loong64 需要忽略 GPG 验证）
echo "Running debootstrap..."
if ! debootstrap --foreign --arch="$arch" --variant=minbase \
    --include=openssh-server,iproute2,ifupdown,chrony,locales \
    --exclude=systemd-timesyncd \
    --no-check-gpg \
    "$suite" "$rootfs" "$mirror" 2>/dev/null; then
    echo "Failed: debootstrap failed for loongnix $version $arch"
    rm -rf "$temp_dir"
    exit 1
fi

# 配置 DNS
mkdir -p "$rootfs/etc"
cp /etc/resolv.conf "$rootfs/etc/" 2>/dev/null || true

# 创建必要的设备节点（chroot 需要）
mkdir -p "$rootfs/dev"
[ -e "$rootfs/dev/null" ] || mknod -m 666 "$rootfs/dev/null" c 1 3 2>/dev/null || true
[ -e "$rootfs/dev/zero" ] || mknod -m 666 "$rootfs/dev/zero" c 1 5 2>/dev/null || true
[ -e "$rootfs/dev/random" ] || mknod -m 666 "$rootfs/dev/random" c 1 8 2>/dev/null || true
[ -e "$rootfs/dev/urandom" ] || mknod -m 666 "$rootfs/dev/urandom" c 1 9 2>/dev/null || true
[ -e "$rootfs/dev/tty" ] || mknod -m 666 "$rootfs/dev/tty" c 5 0 2>/dev/null || true

# 完成 debootstrap 第二阶段
echo "Completing debootstrap second stage..."
chroot "$rootfs" /debootstrap/debootstrap --second-stage 2>/dev/null || true

# 配置系统
echo "Configuring system..."
chroot "$rootfs" bash -c '
    # 配置 apt 源
    cat > /etc/apt/sources.list <<EOF2
deb https://pkg.loongnix.cn/loongnix/25 loongnix-stable main contrib non-free non-free-firmware
deb https://pkg.loongnix.cn/loongnix/25 loongnix-updates main contrib non-free non-free-firmware
deb https://pkg.loongnix.cn/loongnix/25 loongnix-backports main contrib non-free non-free-firmware
EOF2
    
    # 更新 apt
    apt-get update 2>/dev/null || true
    
    # 设置主机名
    echo "localhost" > /etc/hostname
    
    # 配置网络
    cat > /etc/network/interfaces <<EOF2
auto lo
iface lo inet loopback

auto eth0
iface eth0 inet dhcp
EOF2
    
    # 配置 SSH
    mkdir -p /etc/ssh
    ssh-keygen -A 2>/dev/null || true
    
    # 启用 SSH 服务
    systemctl enable ssh 2>/dev/null || true
    
    # 配置 locale
    echo "en_US.UTF-8 UTF-8" > /etc/locale.gen
    locale-gen 2>/dev/null || true
    echo "LANG=en_US.UTF-8" > /etc/default/locale
    
    # 配置时区
    ln -sf /usr/share/zoneinfo/UTC /etc/localtime
    
    # 配置 DNS
    echo "nameserver 8.8.8.8" > /etc/resolv.conf
    echo "nameserver 114.114.114.114" >> /etc/resolv.conf
'

# 清理 /dev/* 目录
echo "Cleaning /dev directory..."
rm -rf "$rootfs/dev/"* 2>/dev/null || true

# 清理缓存
rm -rf "$rootfs/var/cache/apt/archives/"*.deb 2>/dev/null || true
rm -rf "$rootfs/var/lib/apt/lists/"* 2>/dev/null || true

# 清理 debootstrap 临时文件
rm -f "$rootfs/debootstrap/"*

# 打包 rootfs
echo "Packaging: loongnix $version $arch"
mkdir -p "$(dirname "$output_file")"

tar -cJf "$output_file" -C "$rootfs" .

if [ $? -eq 0 ]; then
    echo "Success: loongnix $version $arch -> $(basename "$output_file")"
else
    echo "Failed: loongnix $version $arch"
fi

# 清理临时目录
rm -rf "$temp_dir"

echo "Build complete."
