#!/usr/bin/env bash
# egressctl - IPv4/IPv6 egress mode switcher for Linux
# Modes:
#   block6  - block NEW outbound IPv6 connections; keep loopback/established flows
#   block4  - block NEW outbound IPv4 connections; keep loopback/established flows
#   prefer6 - allow both; prefer IPv6 where libc/application honors address ordering
#   prefer4 - allow both; prefer IPv4 where libc/application honors address ordering
#
# Supported broadly on systemd/OpenRC/SysV-style Linux. nftables is preferred;
# iptables/ip6tables are used as a fallback. Preference control is strongest on glibc.

set -Eeuo pipefail

VERSION="1.2.0"
STATE_DIR="/etc/egressctl"
BACKUP_DIR="$STATE_DIR/backups"
MODE_FILE="$STATE_DIR/mode"
BACKUP_GAI="$STATE_DIR/gai.conf.original"
GAI_META="$STATE_DIR/gai.conf.meta"
MANAGED_BIN="/usr/local/sbin/egressctl"
SYSTEMD_UNIT="/etc/systemd/system/egressctl.service"
OPENRC_HOOK="/etc/local.d/egressctl.start"
RC_LOCAL="/etc/rc.local"
NFT_TABLE="egressctl"
CHECK_URLS=(
  "https://api64.ipify.org"
  "https://icanhazip.com"
  "https://ifconfig.co/ip"
)

C_RESET='\033[0m'
C_RED='\033[31m'
C_GREEN='\033[32m'
C_YELLOW='\033[33m'
C_BLUE='\033[34m'
C_BOLD='\033[1m'

log()  { printf "%b[+]%b %s\n" "$C_GREEN" "$C_RESET" "$*"; }
warn() { printf "%b[!]%b %s\n" "$C_YELLOW" "$C_RESET" "$*" >&2; }
err()  { printf "%b[x]%b %s\n" "$C_RED" "$C_RESET" "$*" >&2; }
info() { printf "%b[*]%b %s\n" "$C_BLUE" "$C_RESET" "$*"; }

need_root() {
  if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
    err "请使用 root 运行：sudo bash $0"
    exit 1
  fi
}

have() { command -v "$1" >/dev/null 2>&1; }

install_pkg() {
  local pkg="$1"
  if have apt-get; then
    DEBIAN_FRONTEND=noninteractive apt-get update -qq || true
    DEBIAN_FRONTEND=noninteractive apt-get install -y "$pkg"
  elif have dnf; then
    dnf install -y "$pkg"
  elif have yum; then
    yum install -y "$pkg"
  elif have pacman; then
    pacman -Sy --noconfirm "$pkg"
  elif have apk; then
    apk add --no-cache "$pkg"
  elif have zypper; then
    zypper --non-interactive install "$pkg"
  else
    return 1
  fi
}

ensure_firewall_tool() {
  if have nft; then
    echo nft
    return 0
  fi
  if have iptables && have ip6tables; then
    echo iptables
    return 0
  fi

  warn "未找到 nftables/iptables，尝试安装 nftables..."
  if install_pkg nftables >/dev/null 2>&1 && have nft; then
    echo nft
    return 0
  fi

  err "无法找到或安装 nftables/iptables。"
  return 1
}

ensure_curl() {
  if have curl; then return 0; fi
  warn "未找到 curl，尝试安装用于自动检查..."
  install_pkg curl >/dev/null 2>&1 || true
  have curl
}

mkdir_state() {
  mkdir -p "$STATE_DIR" "$BACKUP_DIR"
  chmod 700 "$STATE_DIR" "$BACKUP_DIR"
}

# Snapshot a file exactly once before egressctl may modify it.
# meta=1 means the file existed; meta=0 means it did not exist.
snapshot_file_once() {
  local path="$1" key="$2" meta backup
  mkdir_state
  meta="$BACKUP_DIR/${key}.meta"
  backup="$BACKUP_DIR/${key}.original"
  [[ -e "$meta" ]] && return 0

  if [[ -e "$path" ]]; then
    cp -a "$path" "$backup"
    printf 'existed=1\n' > "$meta"
  else
    : > "$backup"
    printf 'existed=0\n' > "$meta"
  fi
  chmod 600 "$meta" 2>/dev/null || true
}

restore_snapshotted_file() {
  local path="$1" key="$2" meta backup existed
  meta="$BACKUP_DIR/${key}.meta"
  backup="$BACKUP_DIR/${key}.original"
  [[ -r "$meta" ]] || return 1
  existed="$(awk -F= '$1=="existed"{print $2; exit}' "$meta" 2>/dev/null || true)"
  if [[ "$existed" == "1" ]]; then
    cp -a "$backup" "$path"
  else
    rm -f "$path"
  fi
}

snapshot_persistence_once() {
  snapshot_file_once "$MANAGED_BIN" managed_bin
  snapshot_file_once "$SYSTEMD_UNIT" systemd_unit
  snapshot_file_once "$OPENRC_HOOK" openrc_hook
  snapshot_file_once "$RC_LOCAL" rc_local
}

backup_gai_once() {
  mkdir_state
  if [[ ! -e "$BACKUP_GAI" ]]; then
    if [[ -e /etc/gai.conf ]]; then
      cp -a /etc/gai.conf "$BACKUP_GAI"
      printf 'existed=1\n' > "$GAI_META"
    else
      : > "$BACKUP_GAI"
      printf 'existed=0\n' > "$GAI_META"
    fi
    chmod 600 "$BACKUP_GAI" "$GAI_META" 2>/dev/null || true
  elif [[ ! -e "$GAI_META" ]]; then
    # Compatibility with egressctl 1.0 backups. An existing non-empty backup
    # definitely means gai.conf existed. An empty legacy backup is ambiguous;
    # conservatively restore it as a file rather than deleting user data.
    if [[ -s "$BACKUP_GAI" ]]; then
      printf 'existed=1\n' > "$GAI_META"
    else
      printf 'existed=legacy-unknown\n' > "$GAI_META"
    fi
    chmod 600 "$GAI_META" 2>/dev/null || true
  fi
}

restore_original_gai() {
  backup_gai_once
  local existed='legacy-unknown'
  [[ -r "$GAI_META" ]] && existed="$(awk -F= '$1=="existed"{print $2; exit}' "$GAI_META")"
  if [[ "$existed" == "0" ]]; then
    rm -f /etc/gai.conf
  else
    cp -a "$BACKUP_GAI" /etc/gai.conf
  fi
}

write_preference_gai() {
  local family="$1"
  backup_gai_once

  # Keep the user's original non-precedence settings, but replace active
  # precedence lines with a complete managed table. glibc disables its default
  # precedence table once any precedence line is present, so writing only one
  # line is intentionally avoided.
  awk '
    /^[[:space:]]*precedence[[:space:]]+/ { next }
    { print }
  ' "$BACKUP_GAI" > /etc/gai.conf

  {
    echo
    echo "# BEGIN egressctl managed precedence"
    echo "# Generated by egressctl $VERSION"
    if [[ "$family" == "4" ]]; then
      echo "precedence ::1/128        50"
      echo "precedence ::ffff:0:0/96  100"
      echo "precedence ::/0           40"
      echo "precedence 2002::/16      30"
      echo "precedence ::/96          20"
    else
      echo "precedence ::1/128        110"
      echo "precedence ::/0           100"
      echo "precedence 2002::/16      30"
      echo "precedence ::/96          20"
      echo "precedence ::ffff:0:0/96  10"
    fi
    echo "# END egressctl managed precedence"
  } >> /etc/gai.conf
  chown --reference="$BACKUP_GAI" /etc/gai.conf 2>/dev/null || chown root:root /etc/gai.conf 2>/dev/null || true
  chmod --reference="$BACKUP_GAI" /etc/gai.conf 2>/dev/null || chmod 644 /etc/gai.conf 2>/dev/null || true
}

cleanup_nft() {
  if have nft && nft list table inet "$NFT_TABLE" >/dev/null 2>&1; then
    nft delete table inet "$NFT_TABLE" >/dev/null 2>&1 || true
  fi
}

cleanup_iptables() {
  if have iptables; then
    while iptables -C OUTPUT ! -o lo -m conntrack --ctstate NEW -m comment --comment EGRESSCTL_BLOCK_V4 -j REJECT >/dev/null 2>&1; do
      iptables -D OUTPUT ! -o lo -m conntrack --ctstate NEW -m comment --comment EGRESSCTL_BLOCK_V4 -j REJECT || break
    done
  fi
  if have ip6tables; then
    while ip6tables -C OUTPUT ! -o lo -m conntrack --ctstate NEW -m comment --comment EGRESSCTL_BLOCK_V6 -j REJECT >/dev/null 2>&1; do
      ip6tables -D OUTPUT ! -o lo -m conntrack --ctstate NEW -m comment --comment EGRESSCTL_BLOCK_V6 -j REJECT || break
    done
  fi
}

cleanup_firewall() {
  cleanup_nft
  cleanup_iptables
}

apply_nft_block() {
  local family="$1"
  cleanup_nft
  if [[ "$family" == "6" ]]; then
    nft -f - <<'NFT'
table inet egressctl {
  chain output {
    type filter hook output priority 100; policy accept;
    oifname "lo" accept
    meta nfproto ipv6 ct state new reject with icmpx type admin-prohibited
  }
}
NFT
  else
    nft -f - <<'NFT'
table inet egressctl {
  chain output {
    type filter hook output priority 100; policy accept;
    oifname "lo" accept
    meta nfproto ipv4 ct state new reject with icmpx type admin-prohibited
  }
}
NFT
  fi
}

apply_iptables_block() {
  local family="$1"
  cleanup_iptables
  if [[ "$family" == "6" ]]; then
    ip6tables -I OUTPUT 1 ! -o lo -m conntrack --ctstate NEW -m comment --comment EGRESSCTL_BLOCK_V6 -j REJECT
  else
    iptables -I OUTPUT 1 ! -o lo -m conntrack --ctstate NEW -m comment --comment EGRESSCTL_BLOCK_V4 -j REJECT
  fi
}

apply_block() {
  local family="$1"
  local fw
  restore_original_gai
  cleanup_firewall
  fw="$(ensure_firewall_tool)" || return 1

  if [[ "$fw" == "nft" ]]; then
    if ! apply_nft_block "$family"; then
      warn "nftables 应用失败，尝试 iptables 回退..."
      cleanup_nft
      if have iptables && have ip6tables; then
        apply_iptables_block "$family"
      else
        return 1
      fi
    fi
  else
    apply_iptables_block "$family"
  fi
}

save_mode() {
  mkdir_state
  printf '%s\n' "$1" > "$MODE_FILE"
  chmod 600 "$MODE_FILE"
}

install_self() {
  mkdir -p "$(dirname "$MANAGED_BIN")"
  local src
  src="$(readlink -f "$0" 2>/dev/null || printf '%s' "$0")"
  if [[ "$src" != "$MANAGED_BIN" ]]; then
    cp -f "$src" "$MANAGED_BIN"
    chmod 755 "$MANAGED_BIN"
  fi
}

install_persistence() {
  install_self

  if have systemctl && [[ -d /run/systemd/system ]]; then
    cat > "$SYSTEMD_UNIT" <<EOF_UNIT
[Unit]
Description=egressctl IPv4/IPv6 egress policy
After=network-pre.target nftables.service firewalld.service iptables.service
Before=network-online.target

[Service]
Type=oneshot
ExecStart=$MANAGED_BIN --apply-saved
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF_UNIT
    systemctl daemon-reload >/dev/null 2>&1 || true
    systemctl enable egressctl.service >/dev/null 2>&1 || true
    log "已设置 systemd 开机自动恢复配置"
    return 0
  fi

  if have rc-update && [[ -d /etc/local.d ]]; then
    cat > "$OPENRC_HOOK" <<EOF_OPENRC
#!/bin/sh
$MANAGED_BIN --apply-saved >/var/log/egressctl.log 2>&1
EOF_OPENRC
    chmod 755 "$OPENRC_HOOK"
    rc-update add local default >/dev/null 2>&1 || true
    log "已设置 OpenRC 开机自动恢复配置"
    return 0
  fi

  # Generic fallback. Not every non-systemd distro executes rc.local, but many do.
  if [[ ! -e "$RC_LOCAL" ]]; then
    cat > "$RC_LOCAL" <<'EOF_RC'
#!/bin/sh
exit 0
EOF_RC
  fi
  chmod +x "$RC_LOCAL" || true
  if ! grep -Fq "$MANAGED_BIN --apply-saved" "$RC_LOCAL"; then
    local tmp_rc
    tmp_rc="$(mktemp)"
    awk -v cmd="$MANAGED_BIN --apply-saved >/var/log/egressctl.log 2>&1" '
      BEGIN { inserted=0 }
      !inserted && $0 ~ /^[[:space:]]*exit[[:space:]]+0[[:space:]]*$/ { print cmd; inserted=1 }
      { print }
      END { if (!inserted) print cmd }
    ' "$RC_LOCAL" > "$tmp_rc"
    cat "$tmp_rc" > "$RC_LOCAL"
    rm -f "$tmp_rc"
  fi
  warn "未检测到 systemd/OpenRC，已写入 /etc/rc.local；请确认该发行版会执行 rc.local。"
}

is_glibc() {
  getconf GNU_LIBC_VERSION >/dev/null 2>&1
}

family_of_ip() {
  local ip="$1"
  if [[ "$ip" == *:* ]]; then echo 6
  elif [[ "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then echo 4
  else echo "?"
  fi
}

curl_family() {
  local fam="$1" url out
  for url in "${CHECK_URLS[@]}"; do
    if out="$(curl -"$fam" -fsS --max-time 7 --connect-timeout 4 "$url" 2>/dev/null | tr -d '[:space:]')"; then
      if [[ -n "$out" ]]; then
        printf '%s' "$out"
        return 0
      fi
    fi
  done
  return 1
}

curl_default() {
  local url out
  for url in "${CHECK_URLS[@]}"; do
    if out="$(curl -fsS --max-time 7 --connect-timeout 4 "$url" 2>/dev/null | tr -d '[:space:]')"; then
      if [[ -n "$out" ]]; then
        printf '%s' "$out"
        return 0
      fi
    fi
  done
  return 1
}

show_local_state() {
  echo
  printf "%b当前系统网络状态%b\n" "$C_BOLD" "$C_RESET"
  if have ip; then
    local v4 v6 r4 r6
    v4="$(ip -o -4 addr show scope global 2>/dev/null | awk '{print $4}' | paste -sd, - || true)"
    v6="$(ip -o -6 addr show scope global 2>/dev/null | awk '{print $4}' | paste -sd, - || true)"
    r4="$(ip -4 route show default 2>/dev/null | head -n1 || true)"
    r6="$(ip -6 route show default 2>/dev/null | head -n1 || true)"
    printf "  IPv4 地址 : %s\n" "${v4:-无全局 IPv4}"
    printf "  IPv6 地址 : %s\n" "${v6:-无全局 IPv6}"
    printf "  IPv4 默认路由 : %s\n" "${r4:-无}"
    printf "  IPv6 默认路由 : %s\n" "${r6:-无}"
  fi
  if [[ -r "$MODE_FILE" ]]; then
    printf "  egressctl 模式 : %s\n" "$(cat "$MODE_FILE")"
  fi
}

check_mode() {
  local mode="${1:-$(cat "$MODE_FILE" 2>/dev/null || echo unknown)}"
  local ip4='' ip6='' def='' fdef='?'
  show_local_state
  echo
  printf "%b自动出栈检查%b\n" "$C_BOLD" "$C_RESET"

  if ! ensure_curl; then
    warn "curl 不可用，无法执行互联网实测。配置本身已应用。"
    return 2
  fi

  if ip4="$(curl_family 4)"; then
    printf "  IPv4 外连 : %bPASS%b  %s\n" "$C_GREEN" "$C_RESET" "$ip4"
  else
    printf "  IPv4 外连 : %bFAIL%b\n" "$C_RED" "$C_RESET"
  fi

  if ip6="$(curl_family 6)"; then
    printf "  IPv6 外连 : %bPASS%b  %s\n" "$C_GREEN" "$C_RESET" "$ip6"
  else
    printf "  IPv6 外连 : %bFAIL%b\n" "$C_RED" "$C_RESET"
  fi

  if def="$(curl_default)"; then
    fdef="$(family_of_ip "$def")"
    printf "  默认外连 : IPv%s  %s\n" "$fdef" "$def"
  else
    printf "  默认外连 : %bFAIL%b\n" "$C_RED" "$C_RESET"
  fi

  echo
  case "$mode" in
    block6)
      if [[ -n "$ip4" && -z "$ip6" ]]; then
        log "检查通过：新的 IPv6 外连已阻止，IPv4 可用。"
      elif [[ -z "$ip6" ]]; then
        warn "IPv6 已阻止，但 IPv4 也不可用；请检查 IPv4 地址/路由/DNS/上游网络。"
      else
        err "检查异常：IPv6 仍可建立新外连。"
        return 1
      fi
      ;;
    block4)
      if [[ -z "$ip4" && -n "$ip6" ]]; then
        log "检查通过：新的 IPv4 外连已阻止，IPv6 可用。"
      elif [[ -z "$ip4" ]]; then
        warn "IPv4 已阻止，但 IPv6 也不可用；请检查 IPv6 地址/路由/DNS/上游网络。"
      else
        err "检查异常：IPv4 仍可建立新外连。"
        return 1
      fi
      ;;
    prefer6)
      if [[ "$fdef" == 6 ]]; then
        log "检查通过：实际默认外连选择了 IPv6。"
      elif [[ -z "$ip6" ]]; then
        warn "系统当前没有可用 IPv6 外网，因此无法验证 IPv6 优先。"
      else
        warn "IPv6 可用，但本次默认连接选择了 IPv4；应用可能使用 Happy Eyeballs/自带解析器，或 IPv6 建连更慢。"
      fi
      ;;
    prefer4)
      if [[ "$fdef" == 4 ]]; then
        log "检查通过：实际默认外连选择了 IPv4。"
      elif [[ -z "$ip4" ]]; then
        warn "系统当前没有可用 IPv4 外网，因此无法验证 IPv4 优先。"
      else
        warn "IPv4 可用，但本次默认连接选择了 IPv6；应用可能不遵循 /etc/gai.conf。"
      fi
      ;;
    *)
      info "仅完成连通性检查。"
      ;;
  esac
}

apply_mode() {
  local mode="$1"
  need_root
  backup_gai_once
  snapshot_persistence_once
  ensure_curl || warn "curl 安装失败；配置仍会应用，但自动互联网检查可能无法执行。"

  case "$mode" in
    block6)
      info "模式：关闭 IPv6 出栈（阻止新的 IPv6 外连）"
      apply_block 6
      ;;
    block4)
      info "模式：关闭 IPv4 出栈（阻止新的 IPv4 外连）"
      apply_block 4
      ;;
    prefer6)
      info "模式：优先 IPv6 出栈（IPv4/IPv6 均保留）"
      cleanup_firewall
      write_preference_gai 6
      if ! is_glibc; then
        warn "当前 libc 不是 glibc；/etc/gai.conf 可能不被系统解析器采用，实际结果以自动检查为准。"
      fi
      ;;
    prefer4)
      info "模式：优先 IPv4 出栈（IPv4/IPv6 均保留）"
      cleanup_firewall
      write_preference_gai 4
      if ! is_glibc; then
        warn "当前 libc 不是 glibc；/etc/gai.conf 可能不被系统解析器采用，实际结果以自动检查为准。"
      fi
      ;;
    *)
      err "未知模式：$mode"
      return 2
      ;;
  esac

  save_mode "$mode"
  install_persistence
  log "配置已应用并保存：$mode"
  check_mode "$mode" || true
}

apply_saved() {
  need_root
  if [[ ! -r "$MODE_FILE" ]]; then
    warn "没有已保存模式，跳过。"
    return 0
  fi
  local mode
  mode="$(cat "$MODE_FILE")"
  case "$mode" in
    block6) apply_block 6 ;;
    block4) apply_block 4 ;;
    prefer6) cleanup_firewall; write_preference_gai 6 ;;
    prefer4) cleanup_firewall; write_preference_gai 4 ;;
    *) err "保存的模式无效：$mode"; return 1 ;;
  esac
}

restore_all() {
  need_root
  info "正在一键恢复到 egressctl 首次运行前的网络出栈配置..."

  # 1) Remove only firewall objects/rules created by egressctl.
  cleanup_firewall

  # 2) Restore /etc/gai.conf to its original state.
  if [[ -e "$BACKUP_GAI" ]]; then
    restore_original_gai
  else
    warn "未找到 gai.conf 备份；跳过 /etc/gai.conf 恢复。"
  fi

  # 3) Stop/disable the egressctl boot service before restoring/removing files.
  if have systemctl && [[ -e "$SYSTEMD_UNIT" ]]; then
    systemctl disable --now egressctl.service >/dev/null 2>&1 || true
  fi

  # 4) v1.2+ can restore persistence-related files byte-for-byte to their
  # original existence/content. For older state directories, fall back to
  # removing only lines/files recognizable as egressctl-created artifacts.
  if [[ -r "$BACKUP_DIR/systemd_unit.meta" ]]; then
    restore_snapshotted_file "$SYSTEMD_UNIT" systemd_unit || true
  else
    if [[ -f "$SYSTEMD_UNIT" ]] && grep -Fq 'egressctl IPv4/IPv6 egress policy' "$SYSTEMD_UNIT"; then
      rm -f "$SYSTEMD_UNIT"
    fi
  fi

  if [[ -r "$BACKUP_DIR/openrc_hook.meta" ]]; then
    restore_snapshotted_file "$OPENRC_HOOK" openrc_hook || true
  else
    if [[ -f "$OPENRC_HOOK" ]] && grep -Fq "$MANAGED_BIN --apply-saved" "$OPENRC_HOOK"; then
      rm -f "$OPENRC_HOOK"
    fi
  fi

  if [[ -r "$BACKUP_DIR/rc_local.meta" ]]; then
    restore_snapshotted_file "$RC_LOCAL" rc_local || true
  else
    if [[ -f "$RC_LOCAL" ]] && grep -Fq "$MANAGED_BIN --apply-saved" "$RC_LOCAL"; then
      local tmp_rc
      tmp_rc="$(mktemp)"
      awk -v needle="$MANAGED_BIN --apply-saved" 'index($0, needle) == 0 { print }' "$RC_LOCAL" > "$tmp_rc"
      cat "$tmp_rc" > "$RC_LOCAL"
      rm -f "$tmp_rc"
    fi
  fi

  if have systemctl; then
    systemctl daemon-reload >/dev/null 2>&1 || true
    systemctl reset-failed egressctl.service >/dev/null 2>&1 || true
  fi

  # 5) Clear saved mode before checking, so nothing can be reapplied later.
  rm -f "$MODE_FILE"

  log "防火墙规则、协议优先级和开机持久化项已恢复/移除。"
  echo
  info "恢复后自动检查 IPv4/IPv6 实际出栈状态："
  check_mode restored || true

  # 6) Restore a pre-existing /usr/local/sbin/egressctl if there was one;
  # otherwise remove the copy installed by this script. Do this last because
  # the current process may itself be executing that path.
  if [[ -r "$BACKUP_DIR/managed_bin.meta" ]]; then
    restore_snapshotted_file "$MANAGED_BIN" managed_bin || true
  else
    # Legacy v1.0/v1.1 cleanup: only remove it when it looks like our script.
    if [[ -f "$MANAGED_BIN" ]] && grep -Fq 'IPv4/IPv6 egress mode switcher for Linux' "$MANAGED_BIN"; then
      rm -f "$MANAGED_BIN" 2>/dev/null || true
    fi
  fi

  rm -rf "$STATE_DIR" 2>/dev/null || true
  log "一键恢复完成：已恢复首次运行前状态，并清除 egressctl 保存状态。"
}

menu() {
  need_root
  clear 2>/dev/null || true
  printf "%b============================================%b\n" "$C_BOLD" "$C_RESET"
  printf "%b egressctl %s - IPv4/IPv6 出栈控制%b\n" "$C_BOLD" "$VERSION" "$C_RESET"
  printf "%b============================================%b\n" "$C_BOLD" "$C_RESET"
  echo "1) 关闭 IPv6 出栈   （IPv4 出网）"
  echo "2) 关闭 IPv4 出栈   （IPv6 出网）"
  echo "3) 优先 IPv6 出栈   （双栈保留）"
  echo "4) 优先 IPv4 出栈   （双栈保留）"
  echo "5) 一键恢复原始配置 （恢复备份 + 清除规则 + 清除持久化）"
  echo
  read -r -p "请选择 [1-5]: " choice
  case "$choice" in
    1) apply_mode block6 ;;
    2) apply_mode block4 ;;
    3) apply_mode prefer6 ;;
    4) apply_mode prefer4 ;;
    5) restore_all ;;
    *) err "无效选择"; exit 2 ;;
  esac
}

usage() {
  cat <<EOF_USAGE
用法：
  $0                    交互菜单
  $0 --mode block6      关闭 IPv6 新建外连
  $0 --mode block4      关闭 IPv4 新建外连
  $0 --mode prefer6     双栈，优先 IPv6
  $0 --mode prefer4     双栈，优先 IPv4
  $0 --check            自动检查当前 IPv4/IPv6 出栈
  $0 --apply-saved      重新应用已保存模式（用于开机启动）
  $0 --restore          一键恢复：移除规则/持久化并恢复首次运行前配置
  $0 --version
EOF_USAGE
}

main() {
  case "${1:-}" in
    '') menu ;;
    --mode)
      [[ $# -ge 2 ]] || { usage; exit 2; }
      apply_mode "$2"
      ;;
    --check)
      need_root
      check_mode
      ;;
    --apply-saved)
      apply_saved
      ;;
    --restore)
      restore_all
      ;;
    --version|-V)
      echo "$VERSION"
      ;;
    --help|-h)
      usage
      ;;
    *)
      usage
      exit 2
      ;;
  esac
}

main "$@"
