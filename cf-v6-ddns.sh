#!/usr/bin/env bash
# Cloudflare DDNS Updater Script (Ensuring ASCII safety near shebang)

set -o errexit
set -o nounset
set -o pipefail

# --- 颜色和日志函数 (已修复：重定向到 stderr >&2 防止 $(...) 捕获) ---
NC='\033[0m'    # No Color
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'

log_info() {
    echo -e "${BLUE}INFO:${NC} $1" >&2
}

log_warn() {
    echo -e "${YELLOW}WARN:${NC} $1" >&2
}

log_success() {
    echo -e "${GREEN}SUCCESS:${NC} $1" >&2
}

log_error() {
    echo -e "${RED}ERROR:${NC} $1" >&2
    exit 1 # 遇到错误时退出
}

log_header() {
    echo -e "\n${BLUE}--- Cloudflare DDNS 脚本开始执行 ---${NC}" >&2
    echo -e "${BLUE}INFO:${NC} 使用 ${YELLOW}-?${NC} 查看所有配置参数。使用 ${YELLOW}-h <主机名>${NC} 覆盖默认主机名。" >&2
}

# --- 帮助信息函数 ---
print_usage() {
    echo -e "\n${GREEN}--- Cloudflare DDNS 脚本使用说明 ---${NC}"
    echo "脚本将尝试使用内置配置 (cf-v6-ddns.sh 文件的默认值) 运行。"
    echo "您可以使用以下参数覆盖默认值："
    echo ""
    echo -e "  ${YELLOW}-h <hostname.domain>${NC} : 覆盖默认记录名 (CFRECORD_NAME)。[默认: raspberry.lz-0315.com]"
    echo -e "  ${YELLOW}-z <domain.com>${NC}      : 覆盖 Cloudflare Zone 名 (CFZONE_NAME)。[默认: lz-0315.com]"
    echo -e "  ${YELLOW}-t <A|AAAA>${NC}          : 记录类型，AA (IPv6) 或 A (IPv4)。[默认: AAAA]"
    echo -e "  ${YELLOW}-i <EXTERNAL|INTERNAL>${NC}: IP 获取模式。[默认: EXTERNAL]"
    echo "      - INTERNAL: 通过 Linux 路由表获取 IP (推荐用于 IPv6 且避免外部查询被限流)。"
    echo "      - EXTERNAL: 通过外部网站获取 IP。"
    echo -e "  ${YELLOW}-f <true|false>${NC}      : 强制更新 DNS 记录，即使 IP 未变化。[默认: false]"
    echo -e "  ${YELLOW}-d <true|false>${NC}      : 开启详细调试模式 (set -x)。[默认: false]"
    echo -e "  ${YELLOW}-?${NC}                   : 显示此帮助信息。"
    echo -e "\n${BLUE}--- 运行示例 ---${NC}"
    echo "  ${YELLOW}运行内部模式:${NC} /opt/cf-v6-ddns.sh -i INTERNAL"
    echo "  ${YELLOW}强制更新IPv4:${NC} /opt/cf-v6-ddns.sh -t A -f true"
    echo ""
    exit 0
}

# --- 命令行参数解析 ---
# 检查是否请求帮助
if [[ "$*" =~ "-?" ]]; then
    print_usage
fi

log_header

# 明确设置 HOME 变量，以防脚本在非交互式shell中运行
export HOME="/home/lz" 

# --- 默认配置部分 (配置信息已内置) ---
# 变量使用 ${:-default} 语法。
CFKEY=${CFKEY:-"YOUR_API_KEY_HERE"} # 请在此处填写你的 Cloudflare 全局 API Key
CFUSER=${CFUSER:-"your-email@example.comE"} # 请在此处填写你的 Cloudflare 账号邮箱
CFZONE_NAME=${CFZONE_NAME:-"your-domain.com"} # 请在此处填写你的 Cloudflare 区域名
CFRECORD_NAME=${CFRECORD_NAME:-"subdomain.your-domain.com"} # 请替换为要更新的完整域名
CFRECORD_TYPE=${CFRECORD_TYPE:-"AAAA"} # 保持 AAAA
CFTTL=${CFTTL:-120}
FORCE=${FORCE:-false} 
DEBUG=${DEBUG:-false} # 默认关闭调试，使用 -d true 开启
IP_SOURCE=${IP_SOURCE:-"EXTERNAL"} # IP 获取方式：EXTERNAL 或 INTERNAL

# 外部 IP 查询服务
WANIPSITE=${WANIPSITE:-"https://api6.ipify.org"} 
WANIPSITE_FALLBACK="https://ipv6.icanhazip.com" 

# 改进参数解析：友好的错误提示
while getopts k:u:h:z:t:f:d:i:? opts; do 
  case ${opts} in 
    k) CFKEY=${OPTARG} ;; 
    u) CFUSER=${OPTARG} ;; 
    h) CFRECORD_NAME=${OPTARG} ;; 
    z) CFZONE_NAME=${OPTARG} ;; 
    t) CFRECORD_TYPE=${OPTARG} ;; 
    f) FORCE=${OPTARG} ;; 
    d) DEBUG=${OPTARG} ;; 
    i) IP_SOURCE=${OPTARG} ;;
    ?) print_usage ;;
    :) 
        # 友好的参数缺失提示，避免系统原生错误
        case $OPTARG in
            h) log_error "参数 -h 需要指定主机名。示例: -h raspberry.lz-0315.com" ;;
            f) log_error "参数 -f 需要指定 true 或 false。示例: -f true" ;;
            i) log_error "参数 -i 需要指定 EXTERNAL 或 INTERNAL。示例: -i INTERNAL" ;;
            *) log_error "参数 -${OPTARG} 需要一个参数。使用 -? 查看帮助。" ;;
        esac
        exit 2
        ;; 
    *) log_error "无法识别的参数：-${opts}。使用 -? 查看帮助。" && exit 2 ;;
  esac 
done 

# 如果没有传递任何参数，则打印帮助并退出 (此检查放在 getopts 之后，因为参数可能来自环境变量)
if [ "$#" -eq 0 ]; then
    # 仅在没有参数且脚本配置完全没有被设置时才显示帮助
    if [ -z "$CFKEY" ] && [ -z "$CFUSER" ]; then
        print_usage
    fi
fi

# 校验：检查 FORCE 参数是否为有效的布尔值
if [[ "$FORCE" != "true" && "$FORCE" != "false" ]]; then
    log_error "参数 -f 的值 '${FORCE}' 无效。必须是 'true' 或 'false'。"
    exit 2
fi

# 启用调试模式 (如果设置为 true)
if [ "$DEBUG" = true ]; then
    log_warn "调试模式已开启 (set -x)"
    set -x 
fi

# --- 配置摘要 ---
log_info "目标主机名: ${CFRECORD_NAME}"
log_info "目标区域: ${CFZONE_NAME}"
log_info "记录类型: ${CFRECORD_TYPE}"
log_info "IP 获取方式: ${IP_SOURCE}"


# --- 脚本内部变量 ---
CACHE_DIR="${HOME}/.cf_ddns_cache" 
WAN_IP_FILE="${CACHE_DIR}/cf-wan_ip_${CFRECORD_NAME}.txt"
ID_FILE="${CACHE_DIR}/cf-id_${CFRECORD_NAME}.txt"

# 关键修复：使用 Bash 数组来存储 cURL Headers，避免 shell 扩展问题
AUTH_HEADERS=(
    -H "X-Auth-Email: $CFUSER"
    -H "X-Auth-Key: $CFKEY"
    -H "Content-Type: application/json"
)

# --- 检查依赖项和配置 ---
if ! command -v curl &> /dev/null || ! command -v jq &> /dev/null; then
    log_error "缺少依赖项 (curl 或 jq)。请安装它们。"
fi

if [ -z "$CFKEY" ] || [ -z "$CFUSER" ] || [ -z "$CFZONE_NAME" ] || [ -z "$CFRECORD_NAME" ]; then
    log_error "脚本配置信息不完整。请检查 CFKEY/CFUSER 等变量。"
fi

# 如果主机名不是 FQDN，则尝试自动修正 
if [ "$CFRECORD_NAME" != "$CFZONE_NAME" ] && ! [[ "$CFRECORD_NAME" == *".$CFZONE_NAME" ]]; then
  CFRECORD_NAME="$CFRECORD_NAME.$CFZONE_NAME"
  log_warn "主机名修正为 ${CFRECORD_NAME}"
fi

mkdir -p "$CACHE_DIR"
log_info "缓存目录: ${CACHE_DIR}"


# --- 1. 获取当前 WAN IP (可配置的获取方式, 终极鲁棒性) ---
WAN_IP=""

if [ "$IP_SOURCE" = "INTERNAL" ]; then
    if [[ "$(uname)" == "Linux" ]]; then
        log_info "正在使用内部 IPv6 地址查询 (Linux) - 强力过滤 ULA 和 Link-Local..."
        # 强力过滤逻辑：
        # 1. 过滤掉 Link-Local (fe80::/10)
        # 2. 过滤掉 ULA (fc00::/7, 包括 fd00::/8)  
        # 3. 只保留全球单播地址 (2000::/3, 通常以 2 或 3 开头)
        WAN_IP=$(ip -6 addr show scope global | \
                 grep -oP 'inet6 \K[0-9a-f:]+(?=/[0-9]+)' | \
                 grep -v '^fe[89ab][0-9a-f]:' | \
                 grep -v '^f[cd][0-9a-f][0-9a-f]:' | \
                 grep -E '^[23][0-9a-f][0-9a-f][0-9a-f]:' | \
                 head -n 1)

        if [ -z "$WAN_IP" ]; then
            log_error "INTERNAL 模式失败。未找到有效的全球单播 IPv6 地址 (GUA)。"
            log_error "检测到的地址可能为: Link-Local (fe80::) 或 ULA (fc00::/fd00::)"
            log_error "解决方案: 请确保您的网络接口已获得公网 IPv6 地址，或使用 '-i EXTERNAL'。"
        fi

    elif [[ "$(uname)" == "Darwin" ]]; then
        log_info "正在使用内部 IPv6 地址查询 (macOS) - 强力过滤 ULA 和 Link-Local..."
        # macOS 使用 ifconfig 获取 IPv6 地址
        WAN_IP=$(ifconfig | grep -E 'inet6.*(?:2[0-9a-f]{3}|3[0-9a-f]{3}):' | \
                 grep -v '%' | \
                 grep -oE '2[0-9a-f:]+|3[0-9a-f:]+' | \
                 head -n 1)

        if [ -z "$WAN_IP" ]; then
            log_error "INTERNAL 模式失败 (macOS)。未找到有效的全球单播 IPv6 地址。"
            log_error "macOS 解决方案: 请确保 IPv6 已启用，或使用 '-i EXTERNAL'。"
        fi

    else
        log_warn "INTERNAL 模式仅完整支持 Linux 和 macOS。在 $(uname) 上回退到外部查询。"
        IP_SOURCE="EXTERNAL" # 强制回退
    fi
fi

if [ "$IP_SOURCE" = "EXTERNAL" ]; then
    
    # 辅助函数：尝试通过外部服务获取 IP
    get_external_ip() {
        local url="$1"
        local flags="$2"
        local ip_type_check="$3"
        local ip_addr

        # 确保日志输出到 stderr
        if [ "$CFRECORD_TYPE" = "AAAA" ] && [ "$flags" = "-6" ]; then
            log_info "尝试 IPv6 协议强制查询 (${url})..."
        elif [ "$CFRECORD_TYPE" = "AAAA" ] && [ "$flags" = "" ]; then
            log_warn "尝试 IPv6 协议回退查询 (不强制 -6)..."
        elif [ "$CFRECORD_TYPE" = "A" ]; then
            log_info "尝试 IPv4 查询 (${url})..."
        fi

        # 外部查询也添加超时
        ip_addr=$(curl -s --max-time 5 ${flags} --connect-timeout 5 --noproxy '*' "$url")

        # 改进的IP格式验证：支持IPv6压缩格式
        if [ "$ip_type_check" = "AAAA" ]; then
            # IPv6验证：必须包含冒号，允许压缩格式，排除明显无效地址
            if [[ "$ip_addr" =~ : ]] && [[ "$ip_addr" =~ ^[0-9a-fA-F:]+$ ]] && \
               [[ ! "$ip_addr" =~ ^fe80: ]] && [[ ! "$ip_addr" =~ ^f[cd][0-9a-fA-F][0-9a-fA-F]: ]]; then
                echo "$ip_addr"
                return 0
            fi
        elif [ "$ip_type_check" = "A" ] && [[ "$ip_addr" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
            echo "$ip_addr"
            return 0
        fi
        
        # 失败时返回空字符串
        echo ""
        return 1
    }

    # --- 外部查询逻辑 ---
    if [ "$CFRECORD_TYPE" = "AAAA" ]; then
        # 1. 尝试使用 -6 强制 IPv6 协议栈 (最理想但可能失败)
        WAN_IP=$(get_external_ip "$WANIPSITE" "-6" "AAAA")
        
        # 2. 如果失败，尝试备用服务，仍然强制 -6
        if [ -z "$WAN_IP" ]; then
            WAN_IP=$(get_external_ip "$WANIPSITE_FALLBACK" "-6" "AAAA")
        fi

        # 3. 终极回退：如果 -6 失败，移除 -6 标志，让 curl 自行选择
        if [ -z "$WAN_IP" ]; then
            log_warn "强制 IPv6 (-6) 模式失败，正在尝试通过普通路由查询 IPv6..."
            WAN_IP=$(get_external_ip "$WANIPSITE" "" "AAAA")
            
            if [ -z "$WAN_IP" ]; then
                WAN_IP=$(get_external_ip "$WANIPSITE_FALLBACK" "" "AAAA")
            fi
        fi
        
    elif [ "$CFRECORD_TYPE" = "A" ]; then
        # IPv4 逻辑
        WAN_IP=$(get_external_ip "http://ipv4.icanhazip.com" "" "A")
    fi
fi

# IP 验证和失败退出逻辑
if [ "$CFRECORD_TYPE" = "AAAA" ]; then
    # 修复：放宽 IPv6 验证，支持压缩格式 (::)
    # 简化验证：只要包含冒号且不为空就认为是有效的 IPv6
    if [ -z "$WAN_IP" ] || ! [[ "$WAN_IP" =~ : ]]; then
        log_error "无法获取有效的 IPv6 地址 (WAN_IP: '${WAN_IP}')。请检查公网 IPv6 连接。"
        log_error "调试建议: 尝试 '-i INTERNAL' 或检查外部 IPv6 查询服务可达性。"
    fi
    
    # 进一步验证：确保不是明显的无效地址
    if [[ "$WAN_IP" =~ ^fe80: ]] || [[ "$WAN_IP" =~ ^f[cd][0-9a-f][0-9a-f]: ]]; then
        log_error "检测到无效的 IPv6 地址类型: ${WAN_IP}"
        log_error "Link-Local (fe80::) 或 ULA (fc00::/fd00::) 地址无法用于公网 DNS。"
    fi
    
    log_info "当前公网 IPv6 地址: ${GREEN}${WAN_IP}${NC}"
elif [ "$CFRECORD_TYPE" = "A" ]; then
    if [ -z "$WAN_IP" ] || ! [[ "$WAN_IP" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
         log_error "无法获取有效的 IPv4 地址。"
    fi
    log_info "当前公网 IPv4 地址: ${GREEN}${WAN_IP}${NC}"
fi


# --- 2. 检查 IP 是否有变化 ---
OLD_WAN_IP=""
if [ -f "$WAN_IP_FILE" ]; then
    OLD_WAN_IP=$(cat "$WAN_IP_FILE")
    log_info "缓存文件中的旧 IP: ${YELLOW}${OLD_WAN_IP:-无}${NC}"
fi

FORCE_TRUE=false
# 使用校验后的 FORCE 变量
if [ "$FORCE" = "true" ]; then
    FORCE_TRUE=true
    log_warn "检测到强制更新 (-f true)。"
fi

if [ "$WAN_IP" = "$OLD_WAN_IP" ] && [ "$FORCE_TRUE" = false ]; then
    log_success "IP 地址未改变 (${WAN_IP})。脚本无需更新，成功退出。"
    exit 0
fi

log_warn "IP 地址发生变化或强制更新。"


# --- 3. 获取 Zone ID 和 Record ID (使用 jq) ---
CFZONE_ID=""
CFRECORD_ID=""

if [ -f "$ID_FILE" ] && [ $(wc -l < "$ID_FILE") -ge 2 ]; then 
    CFZONE_ID=$(head -n 1 "$ID_FILE")
    CFRECORD_ID=$(sed -n '2p' "$ID_FILE")
    log_info "从缓存文件获取 Zone ID 和 Record ID。"
fi

if [ -z "$CFZONE_ID" ] || [ -z "$CFRECORD_ID" ]; then
    log_info "ID 缓存无效或不存在，正在通过 API 获取..."
    
    # 增强诊断：获取 Zone ID
    log_info "正在尝试通过 Cloudflare API 获取 Zone ID..."
    
    # 使用数组扩展，确保 headers 正确传递
    ZONE_RESPONSE=$(curl -s --max-time 10 -X GET "https://api.cloudflare.com/client/v4/zones?name=$CFZONE_NAME" "${AUTH_HEADERS[@]}")
    CURL_EXIT_CODE=$? # 立即捕获 curl 退出码

    # 强制打印原始响应，这是诊断认证错误的关键
    log_warn "--- Cloudflare RAW 响应 (诊断) ---"
    echo "$ZONE_RESPONSE" >&2 # 确保原始响应输出到 stderr
    log_warn "--- 诊断结束 (curl 退出码: ${CURL_EXIT_CODE}) ---"

    if [ "$CURL_EXIT_CODE" -ne 0 ]; then
        log_error "Cloudflare API 请求失败 (curl 退出码: ${CURL_EXIT_CODE})。可能是网络连接超时或 DNS 解析失败。"
    fi

    # 检查 Cloudflare 响应的 success 字段
    API_SUCCESS=$(echo "$ZONE_RESPONSE" | jq -r '.success' 2>/dev/null) 

    if [ "$API_SUCCESS" != "true" ]; then
        log_error "获取 Zone ID 失败。请检查 CFZONE_NAME 或 API Key 权限。"
        log_error "Cloudflare API 原始响应已在上方打印。"
    fi

    CFZONE_ID=$(echo "$ZONE_RESPONSE" | jq -r '.result[0].id' 2>/dev/null)
    if [ -z "$CFZONE_ID" ] || [ "$CFZONE_ID" = "null" ]; then
        log_error "无法从 API 响应中解析出 Zone ID。Zone 响应: ${ZONE_RESPONSE}"
    fi
    log_info "Zone ID: ${CFZONE_ID}"

    # 增强诊断：获取 Record ID
    # 使用数组扩展，确保 headers 正确传递
    RECORD_RESPONSE=$(curl -s --max-time 10 -X GET "https://api.cloudflare.com/client/v4/zones/$CFZONE_ID/dns_records?type=$CFRECORD_TYPE&name=$CFRECORD_NAME" "${AUTH_HEADERS[@]}")
    CURL_EXIT_CODE=$? 
    API_SUCCESS=$(echo "$RECORD_RESPONSE" | jq -r '.success' 2>/dev/null)

    if [ "$CURL_EXIT_CODE" -ne 0 ]; then
        log_error "Cloudflare API 请求失败 (curl 退出码: ${CURL_EXIT_CODE})。可能是网络连接超时。"
    fi
    
    # 如果记录不存在，则创建 (新增超时)
    CFRECORD_ID=$(echo "$RECORD_RESPONSE" | jq -r '.result[0].id' 2>/dev/null)
    
    if [ -z "$CFRECORD_ID" ] || [ "$CFRECORD_ID" = "null" ]; then
        log_warn "记录 ${CFRECORD_NAME} 不存在，正在创建新记录..."
        CREATE_DATA="{\"type\":\"$CFRECORD_TYPE\",\"name\":\"$CFRECORD_NAME\",\"content\":\"$WAN_IP\",\"ttl\":$CFTTL,\"proxied\":false}"
        
        # 使用数组扩展，确保 headers 正确传递
        CREATE_RESPONSE=$(curl -s --max-time 10 -X POST "https://api.cloudflare.com/client/v4/zones/$CFZONE_ID/dns_records" "${AUTH_HEADERS[@]}" --data "$CREATE_DATA")
        
        if [ "$(echo "$CREATE_RESPONSE" | jq -r '.success')" = "true" ]; then
            CFRECORD_ID=$(echo "$CREATE_RESPONSE" | jq -r '.result.id')
            log_success "成功创建记录。Record ID: ${CFRECORD_ID}"
        else
            log_error "创建记录失败。请检查权限或数据格式。"
            log_error "Cloudflare API 原始响应: ${CREATE_RESPONSE}"
        fi
    else
        log_info "Record ID: ${CFRECORD_ID}"
    fi

    # 存储 ID 文件
    echo "$CFZONE_ID" > "$ID_FILE"
    echo "$CFRECORD_ID" >> "$ID_FILE"
    echo "$CFZONE_NAME" >> "$ID_FILE"
    echo "$CFRECORD_NAME" >> "$ID_FILE"
fi

# --- 4. 更新 Cloudflare DNS 记录 ---
log_info "正在更新 DNS 记录 (${CFRECORD_NAME}) 到 IP: ${WAN_IP}..."

UPDATE_DATA="{\"type\":\"$CFRECORD_TYPE\",\"name\":\"$CFRECORD_NAME\",\"content\":\"$WAN_IP\",\"ttl\":$CFTTL,\"proxied\":false}"

# 更新记录 (新增超时, 使用数组扩展)
RESPONSE=$(curl -s --max-time 10 -X PUT "https://api.cloudflare.com/client/v4/zones/$CFZONE_ID/dns_records/$CFRECORD_ID" \
  "${AUTH_HEADERS[@]}" \
  --data "$UPDATE_DATA")
CURL_EXIT_CODE=$?

if [ "$CURL_EXIT_CODE" -ne 0 ]; then
    log_error "Cloudflare API 更新请求失败 (curl 退出码: ${CURL_EXIT_CODE})。可能是网络连接超时。"
fi

if [ "$(echo "$RESPONSE" | jq -r '.success')" = "true" ]; then
    log_success "更新完成！记录 ${CFRECORD_NAME} 已成功指向 ${WAN_IP}。"
    echo "$WAN_IP" > "$WAN_IP_FILE"
    exit 0
else
    log_error "更新失败。请检查 API 密钥权限或网络连接。"
    log_error "Cloudflare API 原始响应内容: ${RESPONSE}"
fi


