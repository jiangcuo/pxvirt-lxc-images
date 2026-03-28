#!/bin/bash

# 捕获 Ctrl+C (SIGINT)，使整个脚本退出而不是继续下一个任务
trap 'echo "Interrupted by user"; exit 1' INT

SCRIPT_DIR=$(realpath $(dirname "$0"))
rootfs_date=$(date +%Y%m%d)

# 镜像源映射 - 龙芯架构使用龙芯镜像
declare -A loongson_mirrors=(
    ["trixie"]="https://jp.mirrors.lierfang.com/debian-ports/trixie"
    ["bookworm"]="https://jp.mirrors.lierfang.com/debian-ports/bookworm"
    ["sid"]="https://mirror.nju.edu.cn/debian-ports"
)

# 其他架构使用南大镜像
declare -A other_mirrors=(
    ["bookworm"]="https://mirror.nju.edu.cn/debian"
    ["trixie"]="https://mirror.nju.edu.cn/debian"
    ["forky"]="https://mirror.nju.edu.cn/debian"
    ["sid"]="https://mirror.nju.edu.cn/debian"
)

# 架构支持映射（只有 trixie 和 bookworm 支持 loong64）
# ppc64el 和 s390x 在标准 Debian 中支持更好，可以使用官方镜像
declare -A arch_versions=(
    ["loong64"]="trixie bookworm sid"
    ["ppc64el"]="bookworm trixie forky sid"
    ["s390x"]="bookworm trixie forky sid"
)

mkdir -p "$SCRIPT_DIR/lxcs/debian"

# 计算总任务数
total=0
for arch in "${!arch_versions[@]}"; do
    for version in ${arch_versions[$arch]}; do
        ((total++)) || true
    done
done

echo "Total builds: $total"

current=0
for arch in "${!arch_versions[@]}"; do
    for version in ${arch_versions[$arch]}; do
        ((current++)) || true
        
        output_file="$SCRIPT_DIR/lxcs/debian/debian-${version}-${rootfs_date}_${arch}.tar.xz"
        
        # 检查文件是否已存在
        if [ -f "$output_file" ] && [ -s "$output_file" ]; then
            echo "[$current/$total] Skipped (exists): debian $version $arch"
            continue
        fi
        
        # 选择镜像源：龙芯用龙芯镜像，其他用南大镜像
        if [ "$arch" = "loong64" ]; then
            mirror="${loongson_mirrors[$version]}"
            # 龙芯镜像虽然显示为 trixie/bookworm，但实际 codename 还是 sid
            debootstrap_suite="sid"
        else
            mirror="${other_mirrors[$version]}"
            debootstrap_suite="$version"
        fi
        
        echo "[$current/$total] Building: debian $version $arch (from $mirror, suite=$debootstrap_suite)"
        
        # 创建临时目录
        temp_dir=$(mktemp -d)
        
        # 运行 debootstrap（loong64 需要忽略 GPG 验证）
        if [ "$arch" = "loong64" ]; then
            debootstrap_opts="--no-check-gpg"
        else
            debootstrap_opts=""
        fi
        
        if ! debootstrap --foreign --arch="$arch" --variant=minbase \
            --include=openssh-server,iproute2,ifupdown,chrony,locales \
            --exclude=systemd-timesyncd \
            $debootstrap_opts \
            "$debootstrap_suite" "$temp_dir/rootfs" "$mirror" 2>/dev/null; then
            echo "[$current/$total] Failed: debootstrap failed for debian $version $arch"
            rm -rf "$temp_dir"
            continue
        fi
        
        # 配置语言和时区、网络、系统设置
        chroot "$temp_dir/rootfs" bash -c '
            # 配置 locale
            echo "en_US.UTF-8 UTF-8" > /etc/locale.gen
            locale-gen en_US.UTF-8
            update-locale LANG=en_US.UTF-8
            
            # 设置时区
            ln -sf /usr/share/zoneinfo/UTC /etc/localtime
            
            # 配置 SSH
            mkdir -p /etc/ssh
            echo "PermitRootLogin yes" >> /etc/ssh/sshd_config 2>/dev/null || true
            
            # 配置网络 - 启用环回接口
            echo "auto lo" > /etc/network/interfaces
            echo "iface lo inet loopback" >> /etc/network/interfaces
            
            # 启动环回接口（如果命令存在）
            if [ -x /sbin/ip ]; then
                ip link set lo up 2>/dev/null || true
            elif [ -x /sbin/ifconfig ]; then
                ifconfig lo up 2>/dev/null || true
            fi
            
            # 完成包配置（如 debootstrap 使用了 --foreign）
            if [ -x /usr/bin/dpkg ]; then
                dpkg --force-confold --skip-same-version --configure -a 2>/dev/null || true
            fi
            
            # 清理不必要的 getty
            if [ -d /etc/event.d ]; then
                rm -f /etc/event.d/tty[23456] 2>/dev/null || true
            fi
            if [ -f /etc/inittab ]; then
                sed -i -e "/getty.*38400.*tty[23456]/d" /etc/inittab 2>/dev/null || true
            fi
            
            # Link /etc/mtab to /proc/mounts
            rm -f /etc/mtab
            ln -sf /proc/mounts /etc/mtab
            
            # 锁定 root 密码（容器通常不需要密码登录）
            if [ -x /usr/sbin/usermod ]; then
                usermod -L root 2>/dev/null || true
            fi
            
            # 禁用硬件时钟访问（容器中没有硬件时钟）
            if [ -f /etc/default/rcS ]; then
                echo "HWCLOCKACCESS=no" >> /etc/default/rcS
            fi
            
            # 禁用 hald（如果存在）
            if [ -x /usr/sbin/hald ]; then
                dpkg-divert --add --divert /usr/sbin/hald.distrib --rename /usr/sbin/hald 2>/dev/null || true
            fi
            
            # 禁用一些内核相关的 sysctl（容器中无效）
            if [ -f /etc/sysctl.conf ]; then
                sed -i -e "s/^kernel\.printk/#kernel.printk/" \
                       -e "s/^kernel\.maps_protect/#kernel.maps_protect/" \
                       -e "s/^fs\.inotify\.max_user_watches/#fs.inotify.max_user_watches/" \
                       -e "s/^vm\.mmap_min_addr/#vm.mmap_min_addr/" \
                       /etc/sysctl.conf 2>/dev/null || true
            fi
            if [ -d /etc/sysctl.d ]; then
                find /etc/sysctl.d -name "*.conf" -exec sed -i \
                    -e "s/^kernel\.printk/#kernel.printk/" \
                    -e "s/^kernel\.maps_protect/#kernel.maps_protect/" \
                    -e "s/^fs\.inotify\.max_user_watches/#fs.inotify.max_user_watches/" \
                    -e "s/^vm\.mmap_min_addr/#vm.mmap_min_addr/" {} \; 2>/dev/null || true
            fi
            
            # 创建 appliance.info（与 dab 兼容）
            mkdir -p /etc
            cat > /etc/appliance.info <<APPLIANCE_EOF
Name: debian
Version: 
OS: debian
Section: system
Maintainer: Lierfang <itsupport@lierfang.com>
APPLIANCE_EOF
            
            # 清理 /dev 目录下的所有文件（容器设备由宿主机动态创建）
            rm -rf /dev/* 2>/dev/null || true
            
            # 清理
            apt-get clean 2>/dev/null || true
            rm -rf /var/lib/apt/lists/* 2>/dev/null || true
        ' 2>/dev/null || true
        
        # 打包为 tar.xz
        echo "[$current/$total] Packaging: debian $version $arch"
        tar -C "$temp_dir/rootfs" -cJf "$output_file" .
        
        # 清理临时目录
        rm -rf "$temp_dir"
        
        if [ -f "$output_file" ] && [ -s "$output_file" ]; then
            echo "[$current/$total] Success: debian $version $arch -> $(basename "$output_file")"
        else
            echo "[$current/$total] Failed: packaging failed for debian $version $arch"
        fi
    done
done

echo "Build complete."