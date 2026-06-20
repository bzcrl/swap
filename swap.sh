#!/usr/bin/env bash
# swap-manager.sh - 简洁交互式 Swap 管理脚本
# 功能：查看 / 添加 / 删除 / 修改 Swap 文件
# 不修改 swappiness，不修改 vfs_cache_pressure

set -u

DEFAULT_SWAPFILE="/swapfile"
DEFAULT_SIZE_MB="1024"

RED='\033[1;31m'
GREEN='\033[1;32m'
YELLOW='\033[1;33m'
CYAN='\033[1;36m'
NC='\033[0m'

info() { echo -e "${CYAN}[信息]${NC} $*"; }
ok() { echo -e "${GREEN}[完成]${NC} $*"; }
warn() { echo -e "${YELLOW}[警告]${NC} $*"; }
err() { echo -e "${RED}[错误]${NC} $*"; }

need_root() {
    if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
        err "请使用 root 运行：sudo bash $0"
        exit 1
    fi
}

pause() {
    read -rp "按 Enter 返回菜单..." _
}

is_number() {
    [[ "$1" =~ ^[0-9]+$ ]]
}

backup_file() {
    local file="$1"
    if [[ -f "$file" ]]; then
        cp -a "$file" "${file}.bk_$(date +%Y%m%d_%H%M%S)"
    fi
}

detect_openvz() {
    if [[ -d /proc/vz && ! -d /proc/bc ]]; then
        return 0
    fi
    return 1
}

valid_swap_path() {
    local path="$1"

    if [[ ! "$path" =~ ^/[-_./a-zA-Z0-9]+$ ]]; then
        err "路径不合法，只允许普通绝对路径，例如 /swapfile"
        return 1
    fi

    if [[ "$path" == "/" || "$path" == "/etc/"* || "$path" == "/bin/"* || "$path" == "/sbin/"* || "$path" == "/usr/"* ]]; then
        err "不建议把 swap 文件放在系统关键目录：$path"
        return 1
    fi

    return 0
}

show_status() {
    echo
    info "内存与 Swap 状态："
    free -h || true

    echo
    info "当前启用的 Swap："
    swapon --show || true

    echo
    info "/etc/fstab 中的 Swap 项："
    grep -nE '^[^#].+[[:space:]]swap[[:space:]]' /etc/fstab || echo "未发现 fstab swap 项"

    echo
    info "磁盘空间："
    df -h / || true

    echo
}

swap_is_active() {
    local path="$1"
    swapon --noheadings --show=NAME 2>/dev/null | awk '{print $1}' | grep -Fxq "$path"
}

escape_sed_path() {
    printf '%s\n' "$1" | sed 's/[\/&]/\\&/g'
}

remove_swap_from_fstab() {
    local path="$1"
    local escaped_path

    escaped_path="$(escape_sed_path "$path")"

    backup_file /etc/fstab
    sed -i "\|^[[:space:]]*${escaped_path}[[:space:]]\+none[[:space:]]\+swap[[:space:]]|d" /etc/fstab
    sed -i "\|^[[:space:]]*${escaped_path}[[:space:]]\+swap[[:space:]]\+swap[[:space:]]|d" /etc/fstab
}

add_swap_to_fstab() {
    local path="$1"
    local escaped_path

    escaped_path="$(escape_sed_path "$path")"

    backup_file /etc/fstab

    if ! grep -Eq "^[[:space:]]*${escaped_path}[[:space:]]+(none|swap)[[:space:]]+swap[[:space:]]" /etc/fstab; then
        echo "$path none swap defaults 0 0" >> /etc/fstab
    fi
}

create_swapfile() {
    local path="$1"
    local size_mb="$2"
    local dir
    local avail_mb

    valid_swap_path "$path" || return 1

    dir="$(dirname "$path")"

    if [[ ! -d "$dir" ]]; then
        err "目录不存在：$dir"
        return 1
    fi

    if [[ -e "$path" ]]; then
        err "$path 已存在，请先删除或选择其他路径。"
        return 1
    fi

    avail_mb="$(df -Pm "$dir" | awk 'NR==2 {print $4}')"

    if is_number "$avail_mb" && (( size_mb > avail_mb - 64 )); then
        err "磁盘剩余空间不足。可用约 ${avail_mb}MB，不能创建 ${size_mb}MB。"
        return 1
    fi

    info "创建 ${size_mb}MB Swap 文件：$path"

    if command -v fallocate >/dev/null 2>&1; then
        fallocate -l "${size_mb}M" "$path" 2>/dev/null || dd if=/dev/zero of="$path" bs=1M count="$size_mb" status=progress
    else
        dd if=/dev/zero of="$path" bs=1M count="$size_mb" status=progress
    fi

    chmod 600 "$path"

    if ! mkswap "$path"; then
        err "mkswap 失败，删除未完成文件。"
        rm -f "$path"
        return 1
    fi

    if ! swapon "$path"; then
        err "swapon 失败，删除未完成文件。"
        rm -f "$path"
        return 1
    fi

    add_swap_to_fstab "$path"

    ok "Swap 已创建并启用：$path ${size_mb}MB"
}

add_swap_interactive() {
    local path
    local size_mb

    echo
    read -rp "Swap 文件路径 [默认 ${DEFAULT_SWAPFILE}]: " path
    path="${path:-$DEFAULT_SWAPFILE}"

    read -rp "Swap 大小 MB [默认 ${DEFAULT_SIZE_MB}，512M 小鸡建议 1024]: " size_mb
    size_mb="${size_mb:-$DEFAULT_SIZE_MB}"

    if ! is_number "$size_mb" || (( size_mb < 64 )); then
        err "大小必须是 >= 64 的整数，单位 MB。"
        return 1
    fi

    create_swapfile "$path" "$size_mb"
}

choose_swapfile() {
    local default_path="$1"
    local active
    local path

    active="$(swapon --noheadings --show=NAME 2>/dev/null || true)"

    echo >&2
    if [[ -n "$active" ]]; then
        info "当前启用的 Swap：" >&2
        echo "$active" >&2
    else
        warn "当前没有启用的 Swap。" >&2
    fi

    read -rp "请输入要操作的 Swap 文件路径 [默认 ${default_path}]: " path
    path="${path:-$default_path}"

    echo "$path"
}

delete_swap_interactive() {
    local path
    local confirm

    path="$(choose_swapfile "$DEFAULT_SWAPFILE")"

    valid_swap_path "$path" || return 1

    if [[ ! -e "$path" ]]; then
        err "$path 不存在。"
        return 1
    fi

    if [[ ! -f "$path" ]]; then
        err "$path 不是普通文件。为避免误删分区/设备，本脚本只删除 swap 文件。"
        return 1
    fi

    echo
    warn "即将关闭并删除：$path"
    read -rp "确认删除？输入 YES 继续: " confirm

    if [[ "$confirm" != "YES" ]]; then
        warn "已取消。"
        return 0
    fi

    if swap_is_active "$path"; then
        swapoff "$path"
    fi

    remove_swap_from_fstab "$path"
    rm -f "$path"

    ok "已删除 Swap：$path"
}

resize_swap_interactive() {
    local path
    local size_mb
    local confirm

    path="$(choose_swapfile "$DEFAULT_SWAPFILE")"

    valid_swap_path "$path" || return 1

    read -rp "新的 Swap 大小 MB [默认 ${DEFAULT_SIZE_MB}]: " size_mb
    size_mb="${size_mb:-$DEFAULT_SIZE_MB}"

    if ! is_number "$size_mb" || (( size_mb < 64 )); then
        err "大小必须是 >= 64 的整数，单位 MB。"
        return 1
    fi

    if [[ -e "$path" && ! -f "$path" ]]; then
        err "$path 不是普通文件。为避免误操作，本脚本不修改 swap 分区/设备。"
        return 1
    fi

    echo
    warn "即将重建 $path 为 ${size_mb}MB。"
    read -rp "确认修改？输入 YES 继续: " confirm

    if [[ "$confirm" != "YES" ]]; then
        warn "已取消。"
        return 0
    fi

    if [[ -e "$path" ]]; then
        if swap_is_active "$path"; then
            swapoff "$path"
        fi

        remove_swap_from_fstab "$path"
        rm -f "$path"
    fi

    create_swapfile "$path" "$size_mb"
}

menu() {
    clear 2>/dev/null || true

    echo "========================================"
    echo "              Swap 管理脚本"
    echo "========================================"
    echo "1) 查看 Swap / 内存状态"
    echo "2) 添加 Swap 文件"
    echo "3) 删除 Swap 文件"
    echo "4) 修改 Swap 大小"
    echo "5) 退出"
    echo "========================================"
}

main() {
    need_root

    if detect_openvz; then
        warn "检测到 OpenVZ 环境，通常不支持自行创建 swap。"
        warn "如果服务商不支持，本脚本可能失败。"
        sleep 2
    fi

    while true; do
        menu
        read -rp "请选择 [1-5]: " choice

        case "$choice" in
            1)
                show_status
                pause
                ;;
            2)
                add_swap_interactive
                pause
                ;;
            3)
                delete_swap_interactive
                pause
                ;;
            4)
                resize_swap_interactive
                pause
                ;;
            5)
                echo "退出。"
                exit 0
                ;;
            *)
                err "无效选择。"
                sleep 1
                ;;
        esac
    done
}

main "$@"