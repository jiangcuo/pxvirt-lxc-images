#!/bin/bash

SCRIPT_DIR=$(realpath $(dirname "$0"))
rootfs_date=$(date +%Y%m%d)

# 定义架构和版本映射（短版本号 -> 完整版本号）
declare -A version_map=(
    ["3.22"]="3.22.3"
    ["3.23"]="3.23.3"
)
alpine_versions=("3.22" "3.23")
architectures=("loongarch64" "s390x" "ppc64le")

# 创建目录
mkdir -p "$SCRIPT_DIR/lxcs/alpine"

total=0
for v in "${alpine_versions[@]}"; do
    for arch in "${architectures[@]}"; do
        ((total++)) || true
    done
done

echo "Total downloads: $total"
current=0
for version in "${alpine_versions[@]}"; do
    full_version="${version_map[$version]}"
    for arch in "${architectures[@]}"; do
        ((current++)) || true
        output_file="$SCRIPT_DIR/lxcs/alpine/alpine-${version}-${rootfs_date}_${arch}.tar.gz"
        
        # 文件存在则跳过
        if [ -f "$output_file" ] && [ -s "$output_file" ]; then
            echo "[$current/$total] File already exists: $output_file"
            continue
        fi
        
        # 下载
        url="https://mirror.nju.edu.cn/alpine/v${version}/releases/${arch}/alpine-minirootfs-${full_version}-${arch}.tar.gz"
        echo "[$current/$total] Downloading: alpine $version $arch"
        
        if curl -L -f --max-time 30 -o "$output_file" "$url" 2>/dev/null; then
            echo "[$current/$total] Success: alpine $version $arch"
        else
            echo "[$current/$total] Failed: alpine $version $arch"
            rm -f "$output_file"
        fi
    done
done

echo "Download complete."