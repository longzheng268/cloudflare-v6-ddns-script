# 备注：Cloudflare DDNS 更新脚本，适用于 Windows 系统
# 备注：优先从有线网卡获取公网 IPv6 地址，如果没有则从无线网卡获取。

# --- 用户配置部分 ---
# 备注：你的 Cloudflare 帐户邮箱
$CFUser = "*@foxmail.com"

# 备注：你的 Cloudflare 全局 API Key。
$CFKEY = ""

# 备注：你的 Cloudflare 区域名称（主域名）
$CFZoneName = "*.com"

# 备注：要更新的 DNS 记录完整名称（包括子域名）
$CFRecordName = "*.*.com"

# 备注：DNS 记录类型，更新 IPv6 地址请使用 "AAAA"
$CFRecordType = "AAAA"

# 备注：DNS 记录的 TTL (Time To Live)，单位秒。Cloudflare 最小值是 120。
$CFTTL = 120

# 备注：是否强制更新 DNS，即使 IP 没有变化。设置为 $true 会强制更新。
$ForceUpdate = $false

# 备注：IP 地址缓存文件路径。脚本会在这里保存上次的 IP 地址，避免频繁更新。
# 备注：缓存文件存放目录。放在用户目录下名为 '.ddns' 的隐藏文件夹内。
$CacheDir = Join-Path $env:USERPROFILE ".ddns"

# 备注：确保缓存目录存在，如果不存在则创建。
if (-not (Test-Path $CacheDir -PathType Container)) {
    try {
        New-Item -ItemType Directory -Path $CacheDir | Out-Null
        Write-Host "备注：已创建缓存目录: $CacheDir"
    } catch {
        Write-Error "备注：创建缓存目录失败: $($_.Exception.Message)"
        exit 1
    }
}
# 备注：IP 地址缓存文件路径。脚本会在这里保存上次的 IP 地址，避免频繁更新。
$WANIPFile = Join-Path $CacheDir "._cf-wan_ip_$($CFRecordName).txt"

# 备注：Zone ID 和 Record ID 缓存文件路径。这些 ID 用于 Cloudflare API 请求。
$IDFile = Join-Path $CacheDir "._cf-id_$($CFRecordName).txt"
# --- 配置结束 ---


# --- 脚本逻辑部分 ---

# 备注：函数：获取指定接口类型的公网 IPv6 地址
function Get-PublicIPv6Address {
    param (
        [string]$InterfaceType # 例如 "Wired" (有线) 或 "Wireless" (无线)
    )
    
    $adapterNames = @()
    if ($InterfaceType -eq "Wired") {
        # 备注：有线网卡常见的英文和中文名称
        $adapterNames = @("Ethernet*", "以太网*", "本地连接*")
    } elseif ($InterfaceType -eq "Wireless") {
        # 备注：无线网卡常见的英文和中文名称
        $adapterNames = @("Wi-Fi*", "WLAN*", "无线局域网*")
    } else {
        Write-Warning "备注：无效的接口类型 '$InterfaceType'。请使用 'Wired' 或 'Wireless'。"
        return $null
    }

    $ipv6Addresses = @()
    foreach ($namePattern in $adapterNames) {
        $adapters = Get-NetAdapter -Name $namePattern -ErrorAction SilentlyContinue | Where-Object { $_.Status -eq "Up" }
        if ($adapters) {
            $ipv6Addresses = $adapters | Get-NetIPAddress -AddressFamily IPv6 |
                             Where-Object { 
                                 ($_.PrefixOrigin -eq "Dhcp" -or $_.PrefixOrigin -eq "RouterAdvertisement" -or $_.PrefixOrigin -eq "Other" ) -and # 备注：选择动态分配的全局地址
                                 $_.IPAddress -notmatch "^fe80::" -and # 备注：忽略本地链路地址
                                 $_.IPAddress -match "^2409:" # 备注：只选择以 2409 开头的地址
                             } |
                             Select-Object -ExpandProperty IPAddress
            if ($ipv6Addresses) {
                # 备注：返回第一个找到的有效 IPv6 地址
                return $ipv6Addresses[0]
            }
        }
    }
    return $null
}

# 备注：尝试从有线网卡获取 IPv6 地址
Write-Host "备注：尝试从有线网卡获取公网 IPv6 地址..."
$CurrentWANIP = Get-PublicIPv6Address -InterfaceType "Wired"

# 备注：如果无线网卡没有，尝试从有线网卡获取
if (-not $CurrentWANIP) {
    Write-Host "备注：有线网卡未找到有效 IPv6 地址，尝试从无线网卡获取..."
    $CurrentWANIP = Get-PublicIPv6Address -InterfaceType "Wireless"
}

# 备注：如果仍然没有找到，则尝试通过外部服务获取（作为备用方案）
if (-not $CurrentWANIP) {
    Write-Warning "备注：本地网卡未找到符合条件的 IPv6 地址，尝试通过外部服务获取。"
    try {
        $CurrentWANIP = (Invoke-RestMethod -Uri "https://ipv6.icanhazip.com").Trim()
        if (-not ($CurrentWANIP -as [ipaddress])) {
            Write-Error "备注：通过外部服务获取的 IPv6 地址无效: $CurrentWANIP"
            exit 1
        }
    }
    catch {
        Write-Error "备注：通过外部服务获取 WAN IP 失败: $($_.Exception.Message)"
        exit 1
    }
}

# 备注：如果最终还是没有 IP，则报错退出
if (-not $CurrentWANIP) {
    Write-Error "备注：无法获取任何有效的公网 IPv6 地址。"
    exit 1
}

# 备注：获取上次保存的 WAN IP 地址
$OldWANIP = ""
if (Test-Path $WANIPFile) {
    try {
        $OldWANIP = (Get-Content $WANIPFile -Raw).Trim()
    }
    catch {
        Write-Warning "备注：读取旧 IP 文件失败: $($_.Exception.Message)"
    }
} else {
    Write-Host "备注：未找到旧 IP 缓存文件，将进行首次更新。"
}

# 备注：检查 IP 是否有变化，如果没有变化且不是强制更新，则退出
if ($CurrentWANIP -eq $OldWANIP -and -not $ForceUpdate) {
    Write-Host "备注：WAN IP 未改变 ($CurrentWANIP)。"
    exit 0
}

Write-Host "备注：WAN IP 发生变化或强制更新。当前 IP: $CurrentWANIP，旧 IP: $($OldWANIP -replace '^$', '无') "

# 备注：获取 Zone ID 和 Record ID
$CFZoneID = ""
$CFRecordID = ""

if (Test-Path $IDFile) {
    try {
        $FileContent = Get-Content $IDFile
        if ($FileContent.Count -eq 4 -and $FileContent[2] -eq $CFZoneName -and $FileContent[3] -eq $CFRecordName) {
            $CFZoneID = $FileContent[0]
            $CFRecordID = $FileContent[1]
            Write-Host "备注：从缓存文件获取 Zone ID 和 Record ID。"
        }
    }
    catch {
        Write-Warning "备注：读取 ID 缓存文件失败或内容不符，将重新获取。错误: $($_.Exception.Message)"
    }
}

if (-not $CFZoneID -or -not $CFRecordID) {
    Write-Host "备注：正在获取 Zone ID 和 Record ID..."
    try {
        # 备注：获取 Zone ID
        $ZoneResponse = Invoke-RestMethod -Uri "https://api.cloudflare.com/client/v4/zones?name=$CFZoneName" `
            -Headers @{ "X-Auth-Email" = $CFUser; "X-Auth-Key" = $CFKEY; "Content-Type" = "application/json" }
        
        if ($ZoneResponse.success -eq $true -and $ZoneResponse.result.Count -gt 0) {
            $CFZoneID = $ZoneResponse.result[0].id
        } else {
            Write-Error "备注：无法获取 Zone ID。响应: $($ZoneResponse | ConvertTo-Json)"
            exit 1
        }

        # 备注：获取 Record ID
        $RecordResponse = Invoke-RestMethod -Uri "https://api.cloudflare.com/client/v4/zones/$CFZoneID/dns_records?name=$CFRecordName" `
            -Headers @{ "X-Auth-Email" = $CFUser; "X-Auth-Key" = $CFKEY; "Content-Type" = "application/json" }
        
        if ($RecordResponse.success -eq $true -and $RecordResponse.result.Count -gt 0) {
            $CFRecordID = $RecordResponse.result[0].id
        } else {
            # 备注：如果记录不存在，则需要先创建
            Write-Host "备注：DNS 记录不存在，尝试创建记录。"
            $RecordData = @{
                "type"    = $CFRecordType
                "name"    = $CFRecordName
                "content" = $CurrentWANIP
                "ttl"     = $CFTTL
                "proxied" = $false # 备注：DDNS 通常不需要代理，设为 false
            }
            $CreateResponse = Invoke-RestMethod -Uri "https://api.cloudflare.com/client/v4/zones/$CFZoneID/dns_records" `
                -Headers @{ "X-Auth-Email" = $CFUser; "X-Auth-Key" = $CFKEY; "Content-Type" = "application/json" } `
                -Method Post -Body ($RecordData | ConvertTo-Json)
            
            if ($CreateResponse.success -eq $true) {
                $CFRecordID = $CreateResponse.result.id
                Write-Host "备注：成功创建 DNS 记录。"
            } else {
                Write-Error "备注：创建 DNS 记录失败。响应: $($CreateResponse | ConvertTo-Json)"
                exit 1
            }
        }

        # 备注：保存 Zone ID 和 Record ID 到文件
        Set-Content -Path $IDFile -Value "$CFZoneID`n$CFRecordID`n$CFZoneName`n$CFRecordName"
        Write-Host "备注：Zone ID 和 Record ID 已保存到缓存文件。"

    }
    catch {
        Write-Error "备注：获取/创建 Zone ID 或 Record ID 失败: $($_.Exception.Message)"
        exit 1
    }
}

# 备注：更新 Cloudflare DNS 记录
Write-Host "备注：正在更新 DNS 记录 $($CFRecordName) 到 IP: $($CurrentWANIP)..."

$UpdateData = @{
    "id"      = $CFRecordID
    "type"    = $CFRecordType
    "name"    = $CFRecordName
    "content" = $CurrentWANIP
    "ttl"     = $CFTTL
    "proxied" = $false # 备注：DDNS 通常不需要代理，设为 false
}

try {
    $Response = Invoke-RestMethod -Uri "https://api.cloudflare.com/client/v4/zones/$CFZoneID/dns_records/$CFRecordID" `
        -Headers @{ "X-Auth-Email" = $CFUser; "X-Auth-Key" = $CFKEY; "Content-Type" = "application/json" } `
        -Method Put -Body ($UpdateData | ConvertTo-Json)
    
    if ($Response.success -eq $true) {
        Write-Host "备注：DNS 记录更新成功！"
        # 备注：更新成功后保存新的 IP 地址
        Set-Content -Path $WANIPFile -Value $CurrentWANIP
        exit 0
    } else {
        Write-Error "备注：DNS 记录更新失败。响应: $($Response | ConvertTo-Json)"
        exit 1
    }
}
catch {
    Write-Error "备注：执行 DNS 更新请求失败: $($_.Exception.Message)"
    exit 1
}

# --- 脚本逻辑结束 ---
