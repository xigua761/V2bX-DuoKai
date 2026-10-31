#!/usr/bin/env bash
# ======================================================================
#  V2bX 多实例一键安装脚本 (Multi-instance installer)
#
#  - 安装时指定实例名称, 与已有 V2bX(/usr/local/V2bX, /etc/V2bX, 服务 V2bX)互不冲突
#  - 每个实例独立: 程序目录 / 配置目录 / 服务名 / 管理命令 / 二进制文件名
#  - 自动对二进制里写死的默认路径 /etc/V2bX、/usr/local/V2bX 做"等长替换"补丁
#  - 同时支持 systemd (Debian/Ubuntu/CentOS...) 与 OpenRC (Alpine)
#  - 支持 安装 / 升级(--update) / 卸载(--uninstall)
#
#  用法:
#     bash install-v2bx-multi.sh                    # 交互式, 会询问实例名称
#     bash install-v2bx-multi.sh -n v2bx-relay      # 指定名称
#     bash install-v2bx-multi.sh -n relay2 -v v0.3.5 -m https://ghfast.top/
#     bash install-v2bx-multi.sh -n relay2 --update
#     bash install-v2bx-multi.sh -n relay2 --uninstall
#
#  非交互配置节点(可选环境变量):
#     API_HOST=https://panel.example.com API_KEY=xxx NODE_ID=12 \
#     NODE_TYPE=vless CORE_TYPE=xray bash install-v2bx-multi.sh -n relay2 -y
# ======================================================================
set -o pipefail

REPO="wyx2685/V2bX"
ORIG_ETC="/etc/V2bX"
ORIG_USR="/usr/local/V2bX"

GH_PROXY="${GH_PROXY:-}"
VER=""
ZIPFILE=""
MODE="install"
NAME=""
ASSUME_YES=0
SKIP_CONFIG=0
CREATED=0
TMP=""
INIT=""
ARCH=""
ID=""

# ---------------------------- 输出工具 ----------------------------
C_RED=$'\033[31m'; C_GREEN=$'\033[32m'; C_YELLOW=$'\033[33m'; C_PLAIN=$'\033[0m'
info() { printf '%s[INFO]%s %s\n' "$C_GREEN" "$C_PLAIN" "$*"; }
warn() { printf '%s[WARN]%s %s\n' "$C_YELLOW" "$C_PLAIN" "$*"; }
err()  { printf '%s[ERR ]%s %s\n' "$C_RED" "$C_PLAIN" "$*" >&2; }
die()  {
  err "$*"
  if [ "$CREATED" = 1 ]; then
    warn "安装失败, 正在回滚本次创建的文件..."
    rollback
  fi
  exit 1
}

usage() {
  cat <<'EOF'
V2bX 多实例安装脚本

选项:
  -n, --name NAME      实例名称 (小写字母开头, 含数字/-/_, 2-24 位)
  -v, --version TAG    指定 V2bX 版本, 如 v0.3.5 (默认最新)
  -m, --mirror PREFIX  GitHub 下载加速前缀, 如 https://ghfast.top/
  -z, --zip FILE       使用本地 V2bX-linux-*.zip (离线安装)
      --update         升级指定实例的二进制 (保留配置)
      --uninstall      卸载指定实例 (配置会先备份到 /root)
      --no-config      安装后不询问节点信息
  -y, --yes            所有确认默认 yes
  -h, --help           显示帮助
EOF
}

# ---------------------------- 参数解析 ----------------------------
need_arg() { [ "$2" -ge 2 ] || die "选项 $1 需要参数"; }

parse_args() {
  while [ $# -gt 0 ]; do
    case "$1" in
      -n|--name)    need_arg "$1" $#; NAME="$2"; shift 2 ;;
      -v|--version) need_arg "$1" $#; VER="$2"; shift 2 ;;
      -m|--mirror)  need_arg "$1" $#; GH_PROXY="$2"; shift 2 ;;
      -z|--zip)     need_arg "$1" $#; ZIPFILE="$2"; shift 2 ;;
      --update)     MODE="update"; shift ;;
      --uninstall)  MODE="uninstall"; shift ;;
      --no-config)  SKIP_CONFIG=1; shift ;;
      -y|--yes)     ASSUME_YES=1; shift ;;
      -h|--help)    usage; exit 0 ;;
      *) die "未知参数: $1 (用 -h 查看帮助)" ;;
    esac
  done
}

# 读取一行输入(走 /dev/tty, 兼容 curl | bash)
ask() {
  local prompt="$1" default="${2:-}" v=""
  printf '%s' "$prompt" >&2
  if ! { read -r v </dev/tty; } 2>/dev/null; then v=""; fi
  printf '%s' "${v:-$default}"
}

confirm() {
  [ "$ASSUME_YES" = 1 ] && return 0
  local a
  a=$(ask "$1 [y/N]: ")
  [[ "$a" =~ ^[Yy]$ ]]
}

# ---------------------------- 环境检测 ----------------------------
detect_init() {
  if [ -d /run/systemd/system ] && command -v systemctl >/dev/null 2>&1; then
    INIT="systemd"
  elif command -v rc-service >/dev/null 2>&1; then
    INIT="openrc"
  else
    die "未检测到 systemd 或 OpenRC, 暂不支持此系统"
  fi
}

detect_arch() {
  case "$(uname -m)" in
    x86_64|amd64)  ARCH="64" ;;
    aarch64|arm64) ARCH="arm64-v8a" ;;
    s390x)         ARCH="s390x" ;;
    *) die "不支持的架构: $(uname -m)" ;;
  esac
}

install_deps() {
  local c p pkgs=()

  # Alpine: busybox 的 sed/grep 处理二进制不可靠, 强制装 GNU 版本
  if [ -f /etc/alpine-release ]; then
    info "安装依赖 (Alpine)..."
    apk add --no-cache bash curl unzip jq coreutils sed grep findutils ca-certificates >/dev/null \
      || die "依赖安装失败"
    return
  fi

  # 只安装"缺少的"包, 避免顺带升级已装软件
  command -v curl   >/dev/null 2>&1 || pkgs+=(curl ca-certificates)
  command -v unzip  >/dev/null 2>&1 || pkgs+=(unzip)
  command -v jq     >/dev/null 2>&1 || pkgs+=(jq)
  command -v md5sum >/dev/null 2>&1 || pkgs+=(coreutils)
  command -v sed    >/dev/null 2>&1 || pkgs+=(sed)
  command -v grep   >/dev/null 2>&1 || pkgs+=(grep)
  command -v find   >/dev/null 2>&1 || pkgs+=(findutils)

  if [ "${#pkgs[@]}" -gt 0 ]; then
    info "需要安装依赖: ${pkgs[*]}"
    if command -v apt-get >/dev/null 2>&1; then
      apt-get update || warn "apt-get update 失败, 软件源可能已失效 (Debian 11 已于 2026-08-31 结束支持, 需将源改到 archive.debian.org)"
      for p in "${pkgs[@]}"; do
        apt-get install -y "$p" || warn "安装 $p 失败"
      done
    elif command -v dnf >/dev/null 2>&1; then
      for p in "${pkgs[@]}"; do dnf install -y "$p" || warn "安装 $p 失败"; done
    elif command -v yum >/dev/null 2>&1; then
      for p in "${pkgs[@]}"; do yum install -y "$p" || warn "安装 $p 失败"; done
    else
      warn "无法自动安装依赖, 请手动安装: ${pkgs[*]}"
    fi
  fi

  # curl/unzip 等是必需的; jq 只用于自动写入节点配置, 缺少时降级
  for c in curl unzip md5sum sed grep find; do
    command -v "$c" >/dev/null 2>&1 || die "缺少必需命令: $c, 请先手动安装后重试"
  done
  command -v jq >/dev/null 2>&1 || warn "未安装 jq: 将跳过自动写入节点配置, 安装完成后请用 '$NAME config' 手动编辑"
}

# ---------------------------- 名称 / 路径 ----------------------------
validate_name() {
  [[ "$NAME" =~ ^[a-z][a-z0-9_-]{1,23}$ ]] \
    || die "实例名称不合法: 需小写字母开头, 仅含 小写字母/数字/-/_, 长度 2-24"
  case "$NAME" in
    v2bx|xrayr|xray|sing-box|singbox|xboard-node|root|bin|etc|usr)
      die "名称 '$NAME' 为保留名称, 请换一个" ;;
  esac
}

set_paths() {
  INST_DIR="/usr/local/$NAME"
  CONF_DIR="/etc/$NAME"
  CMD="/usr/local/bin/$NAME"
  UNIT="/etc/systemd/system/$NAME.service"
  RCFILE="/etc/init.d/$NAME"
}

check_conflict() {
  [ -e "$INST_DIR" ] || [ -L "$INST_DIR" ] && die "$INST_DIR 已存在 (升级请用 --update, 重装请先 --uninstall)"
  [ -e "$CONF_DIR" ] || [ -L "$CONF_DIR" ] && die "$CONF_DIR 已存在, 为避免覆盖已有配置, 已中止"
  [ -e "$CMD" ] && die "$CMD 已存在"
  command -v "$NAME" >/dev/null 2>&1 && die "系统中已存在名为 '$NAME' 的命令"
  [ -e "$UNIT" ] && die "$UNIT 已存在"
  [ -e "$RCFILE" ] && die "$RCFILE 已存在"
  if [ "$INIT" = systemd ] && systemctl list-unit-files 2>/dev/null | grep -q "^$NAME\.service"; then
    die "已存在同名 systemd 服务: $NAME"
  fi
  return 0
}

# 选出一个 4 位 ID, 用于等长替换 "V2bX"。
# /etc/V2bX(9) -> /etc/<ID>(9), /usr/local/V2bX(15) -> /usr/local/<ID>(15)
# 名称恰为 4 位时直接用名称; 否则取名称 md5 的 4 位, 并建立软链 /etc/<ID> -> /etc/<NAME>
pick_id() {
  if [ "${#NAME}" -eq 4 ]; then
    ID="$NAME"
    return
  fi
  local h c i
  h=$(printf '%s' "$NAME" | md5sum | cut -d' ' -f1)
  for i in $(seq 0 24); do
    c="${h:$i:4}"
    [ "$c" = "V2bX" ] && continue
    if [ ! -e "/etc/$c" ] && [ ! -L "/etc/$c" ] && [ ! -e "/usr/local/$c" ] && [ ! -L "/usr/local/$c" ]; then
      ID="$c"
      return
    fi
  done
  die "无法为实例分配补丁 ID, 请换一个名称重试"
}

# ---------------------------- 下载 / 补丁 ----------------------------
fetch() {
  local url="$1" out="$2" i
  for i in 1 2 3; do
    curl -fL --connect-timeout 15 --retry 2 -o "$out" "$url" && return 0
    sleep 2
  done
  return 1
}

download_release() {
  TMP=$(mktemp -d /tmp/v2bx-inst.XXXXXX) || die "无法创建临时目录"
  trap 'rm -rf "$TMP"' EXIT
  local zip="$TMP/v2bx.zip" url file bin
  if [ -n "$ZIPFILE" ]; then
    [ -f "$ZIPFILE" ] || die "找不到本地压缩包: $ZIPFILE"
    cp "$ZIPFILE" "$zip"
  else
    file="V2bX-linux-${ARCH}.zip"
    if [ -n "$VER" ]; then
      url="${GH_PROXY}https://github.com/${REPO}/releases/download/${VER}/${file}"
    else
      url="${GH_PROXY}https://github.com/${REPO}/releases/latest/download/${file}"
    fi
    info "下载: $url"
    fetch "$url" "$zip" || die "下载失败 (可用 -m 指定加速前缀, 或 -z 使用本地压缩包)"
  fi
  unzip -o -q "$zip" -d "$TMP/pkg" || die "解压失败"
  bin=$(find "$TMP/pkg" -type f -name V2bX | head -n1)
  [ -n "$bin" ] || die "压缩包内未找到 V2bX 可执行文件"
  SRC=$(dirname "$bin")
}

count_str() { LC_ALL=C grep -a -o -F -- "$2" "$1" | wc -l; }

# 对二进制做"等长替换": 长度不变, 不会破坏 Go 二进制结构
patch_binary() {
  local f="$1" pair from to n size_before size_after
  size_before=$(stat -c %s "$f")
  for pair in "$ORIG_ETC|/etc/$ID" "$ORIG_USR|/usr/local/$ID"; do
    from="${pair%%|*}"
    to="${pair##*|}"
    [ "${#from}" -eq "${#to}" ] || die "补丁长度不一致: $from -> $to"
    n=$(count_str "$f" "$from")
    if [ "$n" -gt 0 ]; then
      LC_ALL=C sed -i "s|${from}|${to}|g" "$f" || die "sed 补丁失败"
      [ "$(count_str "$f" "$from")" -eq 0 ] || die "补丁后仍残留 $from"
      [ "$(count_str "$f" "$to")" -ge "$n" ] || die "补丁校验失败: 未找到 $to"
      info "二进制补丁: $from -> $to (${n} 处)"
    else
      info "二进制中未发现 $from, 无需补丁"
    fi
  done
  size_after=$(stat -c %s "$f")
  [ "$size_before" = "$size_after" ] || die "补丁后文件大小变化, 已中止"
}

# ---------------------------- 安装文件 ----------------------------
install_files() {
  local f b
  mkdir -p "$INST_DIR" "$CONF_DIR" || die "无法创建目录"

  # 二进制: 改名为实例名, 避免 pkill V2bX / 进程列表混淆
  cp -f "$SRC/V2bX" "$INST_DIR/$NAME" || die "复制二进制失败"
  chmod +x "$INST_DIR/$NAME"
  patch_binary "$INST_DIR/$NAME"

  # 配置与资源文件: .dat 总是更新, 其它(json 等)已存在则不覆盖
  for f in "$SRC"/*; do
    b=$(basename "$f")
    case "$b" in
      V2bX|README*|LICENSE*|*.md) continue ;;
      *.dat) cp -f "$f" "$CONF_DIR/" ;;
      *) [ -e "$CONF_DIR/$b" ] || cp -rf "$f" "$CONF_DIR/" ;;
    esac
  done

  # 配置文件里的路径全部指向本实例目录
  find "$CONF_DIR" -maxdepth 2 -type f -name '*.json' -print0 \
    | xargs -0 -r sed -i "s|${ORIG_ETC}|${CONF_DIR}|g; s|${ORIG_USR}|${INST_DIR}|g"

  # 补丁 ID 与实例目录不同名时, 建软链让"被补丁的默认路径"落到本实例目录
  if [ "$ID" != "$NAME" ]; then
    ln -sfn "$CONF_DIR" "/etc/$ID"
    ln -sfn "$INST_DIR" "/usr/local/$ID"
  fi
}

save_instance() {
  cat >"$INST_DIR/.instance" <<EOF
NAME=$NAME
ID=$ID
INIT=$INIT
VERSION="${VER:-latest}"
EOF
  # 保存脚本自身, 供 <name> update / uninstall 使用
  local self="${BASH_SOURCE[0]:-$0}"
  if [ -f "$self" ]; then
    cp -f "$self" "$INST_DIR/install-v2bx-multi.sh" 2>/dev/null
  fi
}

load_instance() {
  [ -f "$INST_DIR/.instance" ] || die "未找到实例 '$NAME' (缺少 $INST_DIR/.instance), 拒绝操作, 以免误伤其它 V2bX"
  # shellcheck disable=SC1091
  . "$INST_DIR/.instance"
  [ -n "$ID" ] || die "实例元数据损坏"
}

# ---------------------------- 服务 / 管理命令 ----------------------------
write_service() {
  if [ "$INIT" = systemd ]; then
    cat >"$UNIT" <<EOF
[Unit]
Description=$NAME (V2bX instance) Service
After=network.target nss-lookup.target
Wants=network.target

[Service]
User=root
Group=root
Type=simple
LimitAS=infinity
LimitRSS=infinity
LimitCORE=infinity
LimitNOFILE=999999
Environment=XRAY_LOCATION_ASSET=$CONF_DIR
WorkingDirectory=$CONF_DIR
ExecStart=$INST_DIR/$NAME server -c $CONF_DIR/config.json
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
  else
    cat >"$RCFILE" <<EOF
#!/sbin/openrc-run
name="$NAME"
description="V2bX instance $NAME"
command="$INST_DIR/$NAME"
command_args="server -c $CONF_DIR/config.json"
command_background=true
pidfile="/run/$NAME.pid"
directory="$CONF_DIR"
output_log="/var/log/$NAME.log"
error_log="/var/log/$NAME.err"

depend() {
  need net
  after firewall
}

start_pre() {
  export XRAY_LOCATION_ASSET="$CONF_DIR"
}
EOF
    chmod +x "$RCFILE"
  fi
}

write_wrapper() {
  cat >"$CMD" <<'WRAP'
#!/usr/bin/env bash
NAME="__NAME__"
INST_DIR="__INST__"
CONF_DIR="__CONF__"
INIT="__INIT__"

svc() {
  if [ "$INIT" = systemd ]; then systemctl "$1" "$NAME"; else rc-service "$NAME" "$1"; fi
}

usage() {
  cat <<EOF
$NAME 管理命令 (V2bX 多实例)
  $NAME start|stop|restart|status   服务控制
  $NAME enable|disable              开机自启 开/关
  $NAME log                         查看日志
  $NAME config                      编辑 $CONF_DIR/config.json
  $NAME version                     查看内核版本
  $NAME info                        查看路径信息
  $NAME update [-v 版本] [-m 前缀]   升级二进制(保留配置)
  $NAME uninstall                   卸载本实例
EOF
}

case "${1:-}" in
  start|stop|restart) svc "$1" ;;
  status)
    if [ "$INIT" = systemd ]; then systemctl status "$NAME" --no-pager -l; else rc-service "$NAME" status; fi ;;
  enable)
    if [ "$INIT" = systemd ]; then systemctl enable "$NAME"; else rc-update add "$NAME" default; fi ;;
  disable)
    if [ "$INIT" = systemd ]; then systemctl disable "$NAME"; else rc-update del "$NAME" default; fi ;;
  log)
    if [ "$INIT" = systemd ]; then journalctl -u "$NAME" -n 100 -f --no-pager
    else tail -n 100 -f "/var/log/$NAME.log" "/var/log/$NAME.err"; fi ;;
  config)
    "${EDITOR:-vi}" "$CONF_DIR/config.json"
    echo "修改完成后执行: $NAME restart" ;;
  version) "$INST_DIR/$NAME" version ;;
  info)
    echo "名称:     $NAME"
    echo "程序:     $INST_DIR/$NAME"
    echo "配置目录: $CONF_DIR"
    echo "服务:     $NAME ($INIT)" ;;
  update)
    shift
    [ -f "$INST_DIR/install-v2bx-multi.sh" ] || { echo "缺少 $INST_DIR/install-v2bx-multi.sh, 请重新下载安装脚本后执行 --update"; exit 1; }
    exec bash "$INST_DIR/install-v2bx-multi.sh" -n "$NAME" --update "$@" ;;
  uninstall)
    [ -f "$INST_DIR/install-v2bx-multi.sh" ] || { echo "缺少 $INST_DIR/install-v2bx-multi.sh, 请重新下载安装脚本后执行 --uninstall"; exit 1; }
    exec bash "$INST_DIR/install-v2bx-multi.sh" -n "$NAME" --uninstall ;;
  *) usage ;;
esac
WRAP
  sed -i "s|__NAME__|$NAME|g; s|__INST__|$INST_DIR|g; s|__CONF__|$CONF_DIR|g; s|__INIT__|$INIT|g" "$CMD"
  chmod +x "$CMD"
}

svc_do() { # svc_do start|stop|restart
  if [ "$INIT" = systemd ]; then systemctl "$1" "$NAME"; else rc-service "$NAME" "$1"; fi
}

svc_enable() {
  if [ "$INIT" = systemd ]; then systemctl enable "$NAME" >/dev/null 2>&1; else rc-update add "$NAME" default >/dev/null 2>&1; fi
}

# ---------------------------- 节点配置 ----------------------------
setup_config() {
  local cfg="$CONF_DIR/config.json" H K N T C tmp
  CONFIGURED=0
  if ! command -v jq >/dev/null 2>&1; then
    warn "未安装 jq, 跳过节点配置, 请用 '$NAME config' 手动编辑"
    return
  fi
  if [ ! -f "$cfg" ]; then
    warn "未找到 $cfg, 跳过节点配置"
    return
  fi

  if [ -n "${API_HOST:-}" ] && [ -n "${API_KEY:-}" ] && [ -n "${NODE_ID:-}" ]; then
    H="$API_HOST"; K="$API_KEY"; N="$NODE_ID"; T="${NODE_TYPE:-vless}"; C="${CORE_TYPE:-xray}"
  else
    echo
    info "配置节点信息 (直接回车可跳过, 之后用 '$NAME config' 手动编辑)"
    H=$(ask "面板地址 ApiHost (如 https://panel.example.com): ")
    [ -n "$H" ] || { warn "已跳过节点配置"; return; }
    K=$(ask "面板通讯密钥 ApiKey: ")
    N=$(ask "节点 NodeID (数字, 不能与其它实例重复): ")
    T=$(ask "节点类型 NodeType [vless]: " "vless")
    C=$(ask "内核 Core (xray/sing/hysteria2) [xray]: " "xray")
  fi

  H="${H%/}"  # 去掉末尾斜杠
  [[ "$N" =~ ^[0-9]+$ ]] || { warn "NodeID 必须是数字, 已跳过节点配置"; return; }
  case "$C" in xray|sing|hysteria2) ;; *) warn "Core 只能是 xray/sing/hysteria2, 已跳过节点配置"; return ;; esac
  [ -n "$K" ] || { warn "ApiKey 为空, 已跳过节点配置"; return; }

  tmp=$(mktemp)
  if jq --arg h "$H" --arg k "$K" --argjson n "$N" --arg t "$T" --arg c "$C" '
        .Nodes = [ ((.Nodes[0] // {}) + {Core:$c, ApiHost:$h, ApiKey:$k, NodeID:$n, NodeType:$t}) ]
      ' "$cfg" >"$tmp" && jq empty "$tmp" 2>/dev/null; then
    mv "$tmp" "$cfg"
    chmod 600 "$cfg"
    CONFIGURED=1
    info "已写入节点配置 (Core=$C, NodeType=$T, NodeID=$N)"
    if ! jq -e --arg c "$C" '[.Cores[]? | select(.Type==$c)] | length > 0' "$cfg" >/dev/null 2>&1; then
      warn "config.json 的 Cores 中没有 Type=\"$C\" 的条目, 请参考默认配置手动补上, 否则该节点无法启动"
    fi
  else
    rm -f "$tmp"
    warn "自动写入配置失败, 请手动编辑 $cfg"
  fi
}

post_install() {
  local ver
  ver=$("$INST_DIR/$NAME" version 2>&1 | head -n 3)
  [ -n "$ver" ] && info "内核版本信息: $ver"

  if "$INST_DIR/$NAME" server --help 2>&1 | grep -q -- '-c'; then
    :
  else
    warn "未在 'server --help' 中识别到 -c 选项, 该版本可能不支持; 由于默认路径已打补丁, 通常仍可正常运行"
  fi

  echo
  if [ "${CONFIGURED:-0}" = 1 ]; then
    if confirm "现在启动并设为开机自启?"; then
      svc_enable
      svc_do start
      sleep 2
      info "已启动, 查看日志: $NAME log"
    fi
  else
    warn "尚未配置节点, 未启动服务。编辑配置后执行: $NAME enable && $NAME start"
  fi

  cat <<EOF

==================== 安装完成 ====================
  实例名称   : $NAME
  程序       : $INST_DIR/$NAME
  配置目录   : $CONF_DIR   (config.json / custom_outbound.json / route.json ...)
  服务       : $NAME ($INIT)
  管理命令   : $NAME {start|stop|restart|status|log|config|update|uninstall}
  补丁 ID    : $ID  (/etc/$ID -> $CONF_DIR 仅在名称不是 4 位时存在)

  与原 V2bX 完全隔离, 原有 $ORIG_ETC / $ORIG_USR / V2bX 服务未被改动。
  请自行确认:
    1) 本实例的 NodeID 不与其它实例/机器重复
    2) 面板里该节点的监听端口不与本机已有端口冲突
    3) 防火墙已放行该端口
  中继(转发到另一台 VLESS)只需编辑:
    $CONF_DIR/custom_outbound.json 与 $CONF_DIR/route.json
    只影响本实例, 不会动到原 V2bX
==================================================
EOF
}

# ---------------------------- 回滚 / 安装 / 升级 / 卸载 ----------------------------
rollback() {
  CREATED=0
  [ -n "$NAME" ] || return
  [ "$INIT" = systemd ] && { systemctl stop "$NAME" 2>/dev/null; rm -f "$UNIT"; systemctl daemon-reload 2>/dev/null; }
  [ "$INIT" = openrc ] && { rc-service "$NAME" stop 2>/dev/null; rm -f "$RCFILE"; }
  [ -n "$ID" ] && [ "$ID" != "$NAME" ] && {
    [ "$(readlink "/etc/$ID" 2>/dev/null)" = "$CONF_DIR" ] && rm -f "/etc/$ID"
    [ "$(readlink "/usr/local/$ID" 2>/dev/null)" = "$INST_DIR" ] && rm -f "/usr/local/$ID"
  }
  rm -f "$CMD"
  rm -rf "${INST_DIR:?}" "${CONF_DIR:?}"
}

do_install() {
  check_conflict
  install_deps
  detect_arch
  pick_id
  download_release
  CREATED=1
  install_files
  write_service
  write_wrapper
  save_instance
  CREATED=0
  [ "$SKIP_CONFIG" = 1 ] || setup_config
  post_install
}

do_update() {
  load_instance
  install_deps
  detect_arch
  download_release
  info "停止服务..."
  svc_do stop
  cp -f "$INST_DIR/$NAME" "$INST_DIR/$NAME.bak" 2>/dev/null
  install_files
  sed -i "s|^VERSION=.*|VERSION=\"${VER:-latest}\"|" "$INST_DIR/.instance"
  svc_do start
  sleep 2
  info "升级完成: $("$INST_DIR/$NAME" version 2>&1 | head -n 1)"
  info "旧二进制已备份为 $INST_DIR/$NAME.bak, 配置文件未改动"
}

do_uninstall() {
  load_instance
  warn "将卸载实例 '$NAME': 删除 $INST_DIR、$CONF_DIR、服务与管理命令"
  confirm "确认卸载?" || { info "已取消"; exit 0; }

  local bk="/root/${NAME}-config-backup-$(date +%Y%m%d-%H%M%S).tar.gz"
  tar -czf "$bk" -C /etc "$NAME" 2>/dev/null && info "配置已备份: $bk"

  svc_do stop 2>/dev/null
  if [ "$INIT" = systemd ]; then
    systemctl disable "$NAME" >/dev/null 2>&1
    rm -f "$UNIT"
    systemctl daemon-reload
  else
    rc-update del "$NAME" default >/dev/null 2>&1
    rm -f "$RCFILE"
  fi
  if [ "$ID" != "$NAME" ]; then
    [ "$(readlink "/etc/$ID" 2>/dev/null)" = "$CONF_DIR" ] && rm -f "/etc/$ID"
    [ "$(readlink "/usr/local/$ID" 2>/dev/null)" = "$INST_DIR" ] && rm -f "/usr/local/$ID"
  fi
  rm -f "$CMD"
  rm -rf "${INST_DIR:?}" "${CONF_DIR:?}"
  info "实例 '$NAME' 已卸载"
}

main() {
  parse_args "$@"
  [ "$(id -u)" -eq 0 ] || die "请使用 root 运行"
  [ "$(uname -s)" = Linux ] || die "仅支持 Linux"
  detect_init
  if [ -z "$NAME" ]; then
    NAME=$(ask "请输入要安装的实例名称 (小写字母开头, 可含数字/-/_, 例如 v2bx-relay): ")
  fi
  validate_name
  set_paths
  case "$MODE" in
    install)   do_install ;;
    update)    do_update ;;
    uninstall) do_uninstall ;;
  esac
}

# 被 source 时不自动执行 (方便测试)
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  main "$@"
fi
