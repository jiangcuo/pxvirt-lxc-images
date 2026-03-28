#!/bin/bash

# Loongnix Server LXC Image Build Script
# Version: 23.1
# Architecture: loongarch64

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Ctrl+C 信号处理
trap 'echo "Interrupted by user"; exit 130' SIGINT

# 配置
version="23.1"
arch="loongarch64"
mirror_base="https://pkg.loongnix.cn/loongnix-server"
release_rpm="loongnix-release-23.1-11.lns23.loongarch64.rpm"
release_url="${mirror_base}/${version}/os/loongarch64/Packages/${release_rpm}"
repo_url="${mirror_base}/${version}/os/loongarch64"
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

# 创建临时目录
temp_dir=$(mktemp -d)
rootfs="$temp_dir/rootfs"

# 初始化 rpm 数据库
mkdir -p "$rootfs/var/lib/rpm"
rpm --root "$rootfs" --initdb

# 安装 loongnix-release RPM（获取仓库配置）
echo "Installing loongnix-release..."
if ! rpm -ivh --ignorearch --force --nodeps --root "$rootfs" "$release_url" 2>/dev/null; then
    echo "Failed: cannot install loongnix-release"
    rm -rf "$temp_dir"
    exit 1
fi

# 配置 DNS（用于 dnf 下载）
mkdir -p "$rootfs/etc"
cp /etc/resolv.conf "$rootfs/etc/" 2>/dev/null || true

# 创建 yum 仓库配置目录和文件
mkdir -p "$rootfs/etc/yum.repos.d"
cat > "$rootfs/etc/yum.repos.d/loongnix.repo" <<EOF
[loongnix-base]
name=Loongnix Server ${version} Base
baseurl=${repo_url}
gpgcheck=0
enabled=1
EOF

# 安装基础系统（强制目标架构）
echo "Installing base system..."

# 第一步：安装核心包（最小系统）
if ! dnf --installroot="$rootfs" --forcearch="$arch" install -y --nogpgcheck --allowerasing \
    glibc gcc yum 2>/dev/null; then
    echo "Warning: core packages install had issues, continuing..."
fi

# 第二步：安装系统工具
if ! dnf --installroot="$rootfs" --forcearch="$arch" install -y --nogpgcheck --allowerasing \
    systemd systemd-pam net-tools iproute iputils hostname 2>/dev/null; then
    echo "Warning: system tools install had issues, continuing..."
fi

# 第三步：安装网络和 SSH 相关
if ! dnf --installroot="$rootfs" --forcearch="$arch" install -y --nogpgcheck --allowerasing \
    openssh-server openssh-clients curl passwd 2>/dev/null; then
    echo "Warning: network/ssh install had issues, continuing..."
fi

# 第四步：安装其他工具
if ! dnf --installroot="$rootfs" --forcearch="$arch" install -y --nogpgcheck --allowerasing \
    fontconfig nano glibc-locale-source 2>/dev/null; then
    echo "Warning: extra tools install had issues, continuing..."
fi

# 生成 locale
chroot "$rootfs" localedef -c -f UTF-8 -i en_US en_US.UTF-8 2>/dev/null || true

# 配置系统
echo "Configuring system..."
chroot "$rootfs" bash -c '
    # 设置主机名
    echo "localhost" > /etc/hostname
    
    # 配置网络
    cat > /etc/sysconfig/network <<EOF2
NETWORKING=yes
HOSTNAME=localhost
EOF2
    
    # 配置 SSH
    mkdir -p /etc/ssh
    ssh-keygen -A 2>/dev/null || true
    
    # 启用 SSH 服务
    systemctl enable sshd 2>/dev/null || true
    
    # 设置 root 密码为空（首次登录设置）
    passwd -d root 2>/dev/null || true
    
    # 配置 locale
    echo "LANG=en_US.UTF-8" > /etc/locale.conf
    
    # 配置 DNS
    echo "nameserver 8.8.8.8" > /etc/resolv.conf
    echo "nameserver 114.114.114.114" >> /etc/resolv.conf
'

# 清理 /dev/* 目录
echo "Cleaning /dev directory..."
rm -rf "$rootfs/dev/"* 2>/dev/null || true

# 清理缓存
rm -rf "$rootfs/var/cache/dnf/"*
rm -rf "$rootfs/var/cache/yum/"*

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
