#!/bin/bash

# 捕获 Ctrl+C (SIGINT)，使整个脚本退出而不是继续下一个任务
trap 'echo "Interrupted by user"; exit 1' INT

SCRIPT_DIR=$(realpath $(dirname "$0"))
rootfs_date=$(date +%Y%m%d)

# 版本和架构定义
versions=("22.03-LTS" "24.03-LTS")
arch="loongarch64"

# 镜像源基础 URL
mirror_base="https://mirror.nju.edu.cn/openeuler"

# 创建输出目录
mkdir -p "$SCRIPT_DIR/lxcs/openeuler"

# 计算总任务数
total=${#versions[@]}
echo "Total builds: $total"

current=0
for version in "${versions[@]}"; do
    ((current++)) || true
    
    output_file="$SCRIPT_DIR/lxcs/openeuler/openeuler-${version}-${rootfs_date}_${arch}.tar.xz"
    
    # 检查文件是否已存在
    if [ -f "$output_file" ] && [ -s "$output_file" ]; then
        echo "[$current/$total] Skipped (exists): openeuler $version $arch"
        continue
    fi
    
    echo "[$current/$total] Building: openeuler $version $arch"
    
    # 创建临时目录
    temp_dir=$(mktemp -d)
    rootfs="$temp_dir/rootfs"
    
    # 初始化 rpm 数据库
    mkdir -p "$rootfs/var/lib/rpm"
    rpm --root "$rootfs" --initdb
    
    # 安装 openEuler-release RPM（获取仓库配置）
    if [[ "$version" == "22.03-LTS" ]]; then
        release_url="${mirror_base}/openEuler-22.03-LTS/OS/loongarch64/Packages/openEuler-release-22.03LTS-54.oe2203.loongarch64.rpm"
    elif [[ "$version" == "24.03-LTS" ]]; then
        release_url="${mirror_base}/openEuler-24.03-LTS/OS/loongarch64/Packages/openEuler-release-24.03LTS-55.oe2403.loongarch64.rpm"
    fi
    
    echo "[$current/$total] Installing openEuler-release..."
    # 使用 --ignorearch --force 强制安装不同架构的 release 包（仅获取仓库配置）
    if ! rpm -ivh --ignorearch --force --nodeps --root "$rootfs" "$release_url" 2>/dev/null; then
        echo "[$current/$total] Failed: cannot install openEuler-release for $version"
        rm -rf "$temp_dir"
        continue
    fi
    
    # 配置 DNS（用于 dnf 下载）
    mkdir -p "$rootfs/etc"
    cp /etc/resolv.conf "$rootfs/etc/" 2>/dev/null || true
    
    # 创建临时仓库配置（禁用 debuginfo）
    mkdir -p "$rootfs/etc/yum.repos.d"
    cat > "$rootfs/etc/yum.repos.d/openeuler.repo" <<EOF
[OS]
name=OS
baseurl=${mirror_base}/openEuler-${version}/OS/\$basearch/
gpgcheck=0
enabled=1

[everything]
name=everything
baseurl=${mirror_base}/openEuler-${version}/everything/\$basearch/
gpgcheck=0
enabled=1

[EPOL]
name=EPOL
baseurl=${mirror_base}/openEuler-${version}/EPOL/main/\$basearch/
gpgcheck=0
enabled=1
EOF
    
    # 安装基础系统（强制 loongarch64 架构）
    echo "[$current/$total] Installing base system..."
    
    # 第一步：安装核心包（最小系统）
    if ! dnf --installroot="$rootfs" --forcearch=loongarch64 install -y --nogpgcheck --allowerasing \
        glibc gcc yum 2>/dev/null; then
        echo "[$current/$total] Warning: core packages install had issues, continuing..."
    fi
    
    # 第二步：安装系统工具
    if ! dnf --installroot="$rootfs" --forcearch=loongarch64 install -y --nogpgcheck --allowerasing \
        systemd systemd-pam net-tools iproute iputils hostname 2>/dev/null; then
        echo "[$current/$total] Warning: system tools install had issues, continuing..."
    fi
    
    # 第三步：安装网络和 SSH 相关
    if ! dnf --installroot="$rootfs" --forcearch=loongarch64 install -y --nogpgcheck --allowerasing \
        openssh-server openssh-clients curl passwd 2>/dev/null; then
        echo "[$current/$total] Warning: network/ssh install had issues, continuing..."
    fi
    
    # 第四步：安装其他工具
    if ! dnf --installroot="$rootfs" --forcearch=loongarch64 install -y --nogpgcheck --allowerasing \
        fontconfig nano glibc-locale-source 2>/dev/null; then
        echo "[$current/$total] Warning: extra tools install had issues, continuing..."
    fi
    
    # 生成 locale
    chroot "$rootfs" localedef -c -f UTF-8 -i en_US en_US.UTF-8 2>/dev/null || true
    
    # 配置系统
    echo "[$current/$total] Configuring system..."
    chroot "$rootfs" bash -c '
        # 设置主机名
        echo "localhost" > /etc/hostname
        
        # 配置 locale
        echo "LANG=en_US.UTF-8" > /etc/locale.conf
        
        # 配置网络
        echo "auto lo" > /etc/network/interfaces 2>/dev/null || true
        echo "iface lo inet loopback" >> /etc/network/interfaces 2>/dev/null || true
        
        # 配置 SSH
        mkdir -p /etc/ssh
        echo "PermitRootLogin yes" >> /etc/ssh/sshd_config 2>/dev/null || true
        echo "PasswordAuthentication yes" >> /etc/ssh/sshd_config 2>/dev/null || true
        
        # 生成 SSH 主机密钥
        ssh-keygen -A 2>/dev/null || true
        
        # 设置 root 密码（空密码，首次登录设置）
        passwd -d root 2>/dev/null || true
        
        # 清理 /dev 目录（容器设备由宿主机创建）
        rm -rf /dev/* 2>/dev/null || true
        
        # 清理缓存
        dnf clean all 2>/dev/null || true
        rm -rf /var/cache/dnf/* 2>/dev/null || true
        
        # 创建 appliance.info
        cat > /etc/appliance.info <<APPLIANCE_EOF
Name: openeuler
Version: 
OS: openeuler
Section: system
Maintainer: Lierfang <itsupport@lierfang.com>
APPLIANCE_EOF
    ' 2>/dev/null || true
    
    # 打包为 tar.xz
    echo "[$current/$total] Packaging: openeuler $version $arch"
    tar -C "$rootfs" -cJf "$output_file" .
    
    # 清理临时目录
    rm -rf "$temp_dir"
    
    if [ -f "$output_file" ] && [ -s "$output_file" ]; then
        echo "[$current/$total] Success: openeuler $version $arch -> $(basename "$output_file")"
    else
        echo "[$current/$total] Failed: packaging failed for openeuler $version $arch"
    fi
done

echo "Build complete."
