#!/bin/bash
set -e

rootfs_date=`date +%Y%m%d`
path=`pwd`

# 并发数（默认4线程，可通过 JOBS 环境变量设置）
MAX_JOBS=${JOBS:-4}

# 解析命令行参数
# 用法: bash build.sh [发行版] [版本] [架构]
# 示例:
#   bash build.sh                    # 构建全部，4线程
#   JOBS=8 bash build.sh             # 构建全部，8线程
#   bash build.sh debian             # 只构建 debian
#   bash build.sh debian bookworm    # 只构建 debian bookworm
#   bash build.sh debian bookworm amd64  # 只构建 debian bookworm amd64
#   bash build.sh --scan             # 扫描本地目录生成 aplinfo.dat

CLI_DIST=${1:-""}
CLI_VERSION=${2:-""}
CLI_ARCH=${3:-""}

# 扫描模式：扫描本地已有镜像生成 aplinfo.dat
if [ "$CLI_DIST" = "--scan" ]; then
    echo "Scanning local directories for existing images..."
    rm $path/aplinfo.dat 2>/dev/null || true
    
    # 扫描 lxcs/ 目录下的所有发行版
    for dist_dir in $path/lxcs/*/; do
        [ -d "$dist_dir" ] || continue
        dist=$(basename "$dist_dir")
        
        # 扫描该目录下的所有 tar.xz 文件
        for image_file in "${dist_dir}"*.tar.xz; do
            [ -f "$image_file" ] || continue
            
            filename=$(basename "$image_file")
            # 解析文件名格式: distro-version-date_arch.tar.xz 或 distro-version-date_arch-variant.tar.xz
            # 例如: debian-bookworm-20260328_amd64.tar.xz, gentoo-current-20260328_amd64-openrc.tar.xz
            
            # 提取信息
            md5=`md5sum "$image_file"|awk '{print $1}'`
            sha512=`sha512sum "$image_file"|awk '{print $1}'`
            
            # 尝试解析文件名
            if [[ "$filename" =~ ^([^-]+)-([^-]+)-([0-9]+)_([^.]+)(-[^.]+)?\.tar\.xz$ ]]; then
                dist_name="${BASH_REMATCH[1]}"
                codename="${BASH_REMATCH[2]}"
                arch="${BASH_REMATCH[4]}"
                variant="${BASH_REMATCH[5]}"
                variant="${variant#-}"  # 移除开头的 -
                
                # 计算版本号
                version=$(get_version "$codename" 2>/dev/null || echo "$codename")
                
                pkg_name="${dist_name}-${codename}-${arch}"
                [ -n "$variant" ] && pkg_name="${pkg_name}-${variant}"
                
                cat >> $path/aplinfo.dat <<EOF
Package: $pkg_name
Version: $version
Type: lxc
OS: $dist_name
Section: system
Certified: no
Maintainer: Lierfang <itsupport@lierfang.com>
Location: lxcs/$dist/$filename
Infopage: https://linuxcontainers.org
ManageUrl: https://mirrors.lierfang.com/pxcloud/pxvirt/lxcs/build.sh
md5sum: $md5
sha512sum: $sha512
Description: $pkg_name-$rootfs_date
  Lierfang ${variant:-default} image for $dist_name $arch.

EOF
                echo "Scanned: $filename"
            else
                echo "Skipped: $filename (unrecognized format)"
            fi
        done
    done
    
    # 签名
    if [ -f "$path/aplinfo.dat" ]; then
        echo "Scan complete. Generating index..."
        if gpg --list-secret-keys >/dev/null 2>&1; then
            rm -f aplinfo.dat.gz 2>/dev/null || true
            gpg --batch --yes --detach-sign -a aplinfo.dat
            gzip aplinfo.dat
            echo "Done. Files signed and compressed."
        else
            rm -f aplinfo.dat.gz 2>/dev/null || true
            gzip aplinfo.dat
            echo "Done (unsigned - no GPG key configured)."
        fi
    else
        echo "No images found."
    fi
    exit 0
fi

# 环境变量也支持（优先级低于命令行参数）
TARGET_DIST=${CLI_DIST:-${DIST:-""}}
TARGET_VERSION=${CLI_VERSION:-${VERSION:-""}}
TARGET_ARCH=${CLI_ARCH:-${ARCH:-""}}

rm $path/aplinfo.dat 2>/dev/null || true
rm -f /tmp/lxc-build-*.tmp 2>/dev/null || true

# 生成临时任务列表
task_file="/tmp/lxc-build-tasks_$rootfs_date.tmp"
> "$task_file"

# 收集所有下载任务
if [ -n "$TARGET_DIST" ]; then
    dists="$TARGET_DIST"
else
    dists=`jq 'keys|.[]' config.json|sed "s/\"//g"`
fi

for dist in $dists; do
    mkdir -p $path/lxcs/$dist
    
    if [ -n "$TARGET_VERSION" ]; then
        versions="$TARGET_VERSION"
    else
        versions=`jq ".$dist|keys|.[]" config.json|sed "s/\"//g"`
    fi
    
    for codename in $versions; do
        if [ -n "$TARGET_ARCH" ]; then
            architectures="$TARGET_ARCH"
        else
            architectures=`jq ".$dist.\"$codename\".architectures|.[]" config.json|sed "s/\"//g"`
        fi
        
        has_variants=`jq -r ".$dist.\"$codename\".variants? | if type == \"array\" then \"yes\" else \"no\" end" config.json`
        if [ "$has_variants" = "yes" ]; then
            variants=`jq ".$dist.\"$codename\".variants|.[]" config.json|sed "s/\"//g"`
        else
            variants="default"
        fi
        
        for arch in $architectures; do
            for variant in $variants; do
                echo "$dist|$codename|$arch|$variant" >> "$task_file"
            done
        done
    done
done

total_tasks=`wc -l < "$task_file"`
if [ "$total_tasks" -eq 0 ]; then
    echo "No tasks to download."
    rm -f "$task_file"
    exit 0
fi

echo "Total tasks: $total_tasks, Concurrent jobs: $MAX_JOBS"

# 解析版本号的函数
get_version() {
    local codename=$1
    case $codename in
        trixie) echo "13" ;;
        bookworm) echo "12" ;;
        bullseye) echo "11" ;;
        forky) echo "14" ;;
        sid) echo "$rootfs_date" ;;
        jammy) echo "22.04" ;;
        noble) echo "24.04" ;;
        plucky) echo "25.04" ;;
        questing) echo "26.04" ;;
        edge) echo "$rootfs_date" ;;
        current) echo "$rootfs_date" ;;
        tumbleweed) echo "$rootfs_date" ;;
        snapshot) echo "$rootfs_date" ;;
        *) echo "$codename" ;;
    esac
}

# 下载单个任务的函数
download_task() {
    local task_line=$1
    local task_num=$2
    
    IFS='|' read -r dist codename arch variant <<< "$task_line"
    
    # 特殊处理：gentoo 使用 systemd 作为默认 variant
    if [ "$dist" = "gentoo" ] && [ "$variant" = "default" ]; then
        variant="systemd"
    fi
    
    # 镜像源：images.linuxcontainers.org
    local base_url="https://mirror.nju.edu.cn/lxc-images/images/${dist}/${codename}/${arch}/${variant}"
    
    # 获取最新日期目录（支持 %3A URL 编码的冒号，兼容多种格式）
    local latest_date=$(curl -L -s "${base_url}/" 2>/dev/null | grep -oE 'href="[^"]*[0-9]{8}_[0-9]{2}(%3A|:)[0-9]{2}[^"]*"' | grep -oE '[0-9]{8}_[0-9]{2}(%3A|:)[0-9]{2}' | sed 's/%3A/:/g' | sort | tail -1)
    
    if [ -z "$latest_date" ]; then
        echo "[$task_num/$total_tasks] Failed: Cannot find latest date for $dist $codename $arch ($variant)" >&2
        echo "FAILED" > "/tmp/lxc-build-${task_num}.tmp"
        return
    fi
    
    local download_url="${base_url}/${latest_date}/rootfs.tar.xz"
    local output_file="$path/lxcs/$dist/$dist-$codename-"$rootfs_date"_$arch"
    [ "$variant" != "default" ] && output_file="${output_file}-$variant"
    output_file="${output_file}.tar.xz"
    local tmp_info="/tmp/lxc-build-${task_num}.tmp"
    
    # 如果文件已存在且大小不为0，跳过下载
    if [ -f "$output_file" ] && [ -s "$output_file" ]; then
        echo "[$task_num/$total_tasks] Skipped (exists): $dist $codename $arch ($variant)"
        local md5=`md5sum "$output_file"|awk '{print $1}'`
        local sha512=`sha512sum "$output_file"|awk '{print $1}'`
        local version=$(get_version "$codename")
        local pkg_name="$dist-$codename-$arch"
        [ "$variant" != "default" ] && pkg_name="${pkg_name}-$variant"
        
        cat > "$tmp_info" <<EOF
Package: $pkg_name
Version: $version
Type: lxc
OS: $dist
Section: system
Certified: no
Maintainer: Lierfang <itsupport@lierfang.com>
Location: lxcs/$dist/$(basename "$output_file")
Infopage: https://linuxcontainers.org
ManageUrl: https://mirrors.lierfang.com/pxcloud/pxvirt/lxcs/build.sh
md5sum: $md5
sha512sum: $sha512
Description: $pkg_name-$rootfs_date
  Lierfang ${variant:-default} image for $dist $arch.

EOF
        return
    fi
    
    echo "[$task_num/$total_tasks] Downloading: $dist $codename $arch ($variant) - ${latest_date}"
    
    # 重试机制（最多3次）
    local retry_count=0
    local max_retries=3
    local success=0
    
    while [ $retry_count -lt $max_retries ]; do
        if curl -L -f -o "$output_file" "$download_url" 2>/dev/null; then
            success=1
            break
        else
            retry_count=$((retry_count + 1))
            if [ $retry_count -lt $max_retries ]; then
                echo "[$task_num/$total_tasks] Retry $retry_count/$max_retries: $dist $codename $arch ($variant)"
                sleep 2
            fi
        fi
    done
    
    if [ $success -eq 1 ]; then
        local md5=`md5sum "$output_file"|awk '{print $1}'`
        local sha512=`sha512sum "$output_file"|awk '{print $1}'`
        local version=$(get_version "$codename")
        local pkg_name="$dist-$codename-$arch"
        [ "$variant" != "default" ] && pkg_name="${pkg_name}-$variant"
        
        cat > "$tmp_info" <<EOF
Package: $pkg_name
Version: $version
Type: lxc
OS: $dist
Section: system
Certified: no
Maintainer: Linuxcontainers.org <https://lists.linuxcontainers.org/listinfo/lxc-devel>
Location: lxcs/$dist/$(basename "$output_file")
Infopage: https://linuxcontainers.org
ManageUrl: https://mirrors.lierfang.com/pxcloud/pxvirt/lxcs/build.sh
md5sum: $md5
sha512sum: $sha512
Description: $pkg_name-$rootfs_date
  LXC $variant image for $dist $arch.

EOF
        echo "[$task_num/$total_tasks] Success: $dist $codename $arch"
    else
        echo "[$task_num/$total_tasks] Failed after $max_retries retries: $dist $codename $arch ($variant)" >&2
        echo "FAILED" > "$tmp_info"
        rm -f "$output_file" 2>/dev/null || true
    fi
}

# 并发下载控制
job_count=0
task_num=0

while IFS= read -r task_line; do
    task_num=$((task_num + 1))
    
    # 启动后台下载
    download_task "$task_line" "$task_num" &
    
    job_count=$((job_count + 1))
    
    # 达到最大并发数时等待
    if [ $job_count -ge $MAX_JOBS ]; then
        wait -n 2>/dev/null || wait
        job_count=$((job_count - 1))
    fi
done < "$task_file"

# 等待所有后台任务完成
wait

# 合并所有临时文件到 aplinfo.dat
for tmp_file in /tmp/lxc-build-*.tmp; do
    if [ -f "$tmp_file" ]; then
        if [ "$(cat "$tmp_file")" != "FAILED" ]; then
            cat "$tmp_file" >> $path/aplinfo.dat
        fi
        rm -f "$tmp_file"
    fi
done

rm -f "$task_file"
rm -f /tmp/lxc-build-*.tmp 2>/dev/null || true

# 签名（如果配置了 GPG 私钥文件）
if [ -f "$path/aplinfo.dat" ]; then
    echo "Download complete. Generating index..."
    
    # 检查是否已有密钥或 /etc/gpg.key 存在
    has_key=0
    if gpg --list-secret-keys >/dev/null 2>&1; then
        has_key=1
    fi
    
    if [ -f "/etc/gpg.key" ] && [ $has_key -eq 0 ]; then
        # 导入私钥（非交互式）
        gpg --batch --yes --passphrase-file /etc/gpg.key --pinentry-mode loopback --import /etc/gpg.key 2>/dev/null || true
        if gpg --list-secret-keys >/dev/null 2>&1; then
            has_key=1
        fi
    fi
    
    if [ $has_key -eq 1 ]; then
        rm -f aplinfo.dat.gz 2>/dev/null || true
        if gpg --batch --yes --passphrase-file /etc/gpg.key --pinentry-mode loopback --detach-sign -a aplinfo.dat 2>/dev/null || \
           gpg --batch --yes --detach-sign -a aplinfo.dat 2>/dev/null; then
            gzip aplinfo.dat
            echo "Done. Files signed and compressed."
        else
            gzip aplinfo.dat
            echo "Done (unsigned - sign failed)."
        fi
    else
        rm -f aplinfo.dat.gz 2>/dev/null || true
        gzip aplinfo.dat
        echo "Done (unsigned - no GPG key configured)."
    fi
else
    echo "No images were downloaded."
fi
