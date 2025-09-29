# 备注：重要提醒：请将此脚本文件使用 **UTF-8 with BOM** 编码格式保存，
# 备注：以避免在 PowerShell ISE 或某些终端中出现中文注释解析错误（如“字符串缺少终止符”）的问题。
# 备注：------------------------------------------------------------------------------------------

# 备注：Cloudflare DDNS 更新脚本，适用于 Windows 系统
# 备注：已集成协议修复，以解决 9106/400 错误。

# --- 关键协议修复 (解决认证头丢失的最终尝试) ---
# 强制 PowerShell 使用现代 TLS 1.2 和 1.3 协议进行 HTTPS 通信
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 -bor [Net.SecurityProtocolType]::Tls13

# --- 用户配置部分 ---
$CFEmail = "your-email@example.com"  # 请替换为您的 Cloudflare 账户邮箱
# ❗ 必须是 Cloudflare Global API Key
$CFAuthKey = "YOUR_API_KEY_HERE"  # 请替换为您的 Cloudflare API Key 或 Token
$CFZoneName = "your-domain.com"  # 请替换为您的域名
$CFRecordName = "subdomain.your-domain.com"  # 请替换为要更新的完整域名
$CFRecordType = "AAAA"
$CFTTL = 120
$ForceUpdate = $false
$CacheDir = Join-Path $env:USERPROFILE ".ddns"
$WANIPFile = Join-Path $CacheDir "._cf-wan_ip_$($CFRecordName).txt"
$IDFile = Join-Path $CacheDir "._cf-id_$($CFRecordName).txt"

# 备注：确保缓存目录存在
if (-not (Test-Path $CacheDir -PathType Container)) {
    try {
        New-Item -ItemType Directory -Path $CacheDir | Out-Null
        Write-Host "备注：已创建缓存目录: $CacheDir"
    } catch {
        Write-Error "备注：创建缓存目录失败: $($_.Exception.Message)"
        exit 1
    }
}

# --- 脚本逻辑部分 (使用原生 .NET WebRequest 避免 Invoke-RestMethod 引起的头部问题) ---

function Get-ActivePublicIPv6Address {
    $ipv6Addresses = Get-NetIPAddress -AddressFamily IPv6 |
                     Where-Object { 
                         ($_.PrefixOrigin -eq "Dhcp" -or $_.PrefixOrigin -eq "RouterAdvertisement") -and
                         $_.IPAddress -notmatch "^fe80::" -and
                         $_.IPAddress -notmatch "^fd[0-9a-f]{2}:"
                     }
    
    $CurrentWANIP = $ipv6Addresses | Sort-Object -Property InterfaceMetric, PrefixLength | 
                                    Select-Object -First 1 -ExpandProperty IPAddress
    
    if ($CurrentWANIP) {
        Write-Host "备注：已选择最活跃的本地 IPv6 地址: $CurrentWANIP"
        return $CurrentWANIP
    }
    return $null
}

$CurrentWANIP = Get-ActivePublicIPv6Address

if (-not $CurrentWANIP) {
    Write-Error "备注：无法获取任何有效的公网 IPv6 地址。"
    exit 1
}

$OldWANIP = ""
if (Test-Path $WANIPFile) {
    try {
        $OldWANIP = (Get-Content $WANIPFile -Raw).Trim()
    } catch {
        Write-Warning "备注：读取旧 IP 文件失败: $($_.Exception.Message)"
    }
} else {
    Write-Host "备注：未找到旧 IP 缓存文件，将进行首次更新。"
}

if ($CurrentWANIP -eq $OldWANIP -and -not $ForceUpdate) {
    Write-Host "备注：WAN IP 未改变 ($CurrentWANIP)。"
    exit 0
}

Write-Host "备注：WAN IP 发生变化或强制更新。当前 IP: $CurrentWANIP，旧 IP: $($OldWANIP -replace '^$', '无')"

# --- Cloudflare API 核心逻辑 ---

$CFZoneID = ""
$CFRecordID = ""
$AuthHeaders = @{ 
    "X-Auth-Email" = $CFEmail;
    "X-Auth-Key" = $CFAuthKey; 
    "Content-Type" = "application/json" 
}

# 缓存 ID 逻辑保持不变... (省略，因为您已经有缓存文件)
if (Test-Path $IDFile) {
    try {
        $FileContent = Get-Content $IDFile
        if ($FileContent.Count -ge 2) { 
            $CFZoneID = $FileContent[0] 
            $CFRecordID = $FileContent[1] 
            Write-Host "备注：从缓存文件获取 Zone ID 和 Record ID。" 
        } 
    } catch { 
        Write-Warning "备注：读取 ID 缓存文件失败或内容不符，将重新获取。" 
    } 
} 

# 如果 ID 丢失，则执行 GET 重新获取/创建（这部分是稳定的，使用 Invoke-RestMethod）
if (-not $CFZoneID -or -not $CFRecordID) { 
    Write-Host "备注：正在获取 Zone ID 和 Record ID..." 
    try { 
        # 获取 Zone ID
        $ZoneUri = "https://api.cloudflare.com/client/v4/zones?name=$CFZoneName"
        $ZoneResponse = Invoke-RestMethod -Uri $ZoneUri -Headers $AuthHeaders -Method Get -TimeoutSec 10
        if ($ZoneResponse.success -eq $true -and $ZoneResponse.result.Count -gt 0) { 
            $CFZoneID = $ZoneResponse.result[0].id 
        } else { Write-Error "备注：无法获取 Zone ID。"; exit 1 } 
        
        # 获取 Record ID
        $RecordUri = "https://api.cloudflare.com/client/v4/zones/$CFZoneID/dns_records?name=$CFRecordName"
        $RecordResponse = Invoke-RestMethod -Uri $RecordUri -Headers $AuthHeaders -Method Get -TimeoutSec 10
        if ($RecordResponse.success -eq $true -and $RecordResponse.result.Count -gt 0) { 
            $CFRecordID = $RecordResponse.result[0].id 
        } else { 
            # 创建记录（如果需要）
            $RecordData = @{ "type" = $CFRecordType; "name" = $CFRecordName; "content" = $CurrentWANIP; "ttl" = $CFTTL; "proxied" = $false } 
            $CreateResponse = Invoke-RestMethod -Uri "https://api.cloudflare.com/client/v4/zones/$CFZoneID/dns_records" ` 
                -Headers $AuthHeaders -Method Post -Body ($RecordData | ConvertTo-Json -Compress) -ContentType "application/json" -TimeoutSec 10
            if ($CreateResponse.success -eq $true) { $CFRecordID = $CreateResponse.result.id; Write-Host "备注：成功创建 DNS 记录。" } else { Write-Error "备注：创建 DNS 记录失败。"; exit 1 } 
        } 
        Set-Content -Path $IDFile -Value "$CFZoneID`n$CFRecordID"
        Write-Host "备注：Zone ID 和 Record ID 已保存到缓存文件。" 
    } catch { 
        # 捕获并显示详细错误
        Write-Error "备注：获取/创建 Zone ID 或 Record ID 失败。"
        exit 1 
    } 
}

# --- 最终更新 DNS 记录 (使用原生 WebRequest 强制发送头部) ---
Write-Host "备注：正在更新 DNS 记录 $($CFRecordName) 到 IP: $($CurrentWANIP) (使用 WebRequest + 协议修复)..." 
$UpdateData = @{ 
    "type"    = $CFRecordType 
    "name"    = $CFRecordName 
    "content" = $CurrentWANIP 
    "ttl"     = $CFTTL 
    "proxied" = $false 
} 

$UpdateBody = $UpdateData | ConvertTo-Json -Compress -Depth 1

try { 
    $UpdateUri = "https://api.cloudflare.com/client/v4/zones/$CFZoneID/dns_records/$CFRecordID"
    $Request = [System.Net.WebRequest]::CreateHttp($UpdateUri)
    $Request.Method = "PUT"
    $Request.ContentType = "application/json"
    $Request.Timeout = 10000 
    
    # 强制设置认证头
    $Request.Headers.Add("X-Auth-Email", $CFEmail)
    $Request.Headers.Add("X-Auth-Key", $CFAuthKey)

    # 写入请求体
    $EncodedBody = [System.Text.Encoding]::UTF8.GetBytes($UpdateBody)
    $Request.ContentLength = $EncodedBody.Length

    $RequestStream = $Request.GetRequestStream()
    $RequestStream.Write($EncodedBody, 0, $EncodedBody.Length)
    $RequestStream.Close()

    # 获取响应
    $Response = $Request.GetResponse()
    $Reader = New-Object System.IO.StreamReader($Response.GetResponseStream())
    $ResponseText = $Reader.ReadToEnd()
    $ResponseObject = $ResponseText | ConvertFrom-Json

    if ($ResponseObject.success -eq $true) { 
        Write-Host "备注：DNS 记录更新成功！" 
        Set-Content -Path $WANIPFile -Value $CurrentWANIP 
        exit 0 
    } else { 
        $CFError = ""
        if ($ResponseObject.errors) { $CFError = ($ResponseObject.errors | ConvertTo-Json -Compress) }
        Write-Error "备注：DNS 记录更新失败。原始响应: $($ResponseText)"
        if ($CFError) { Write-Error "Cloudflare API 详细错误: $CFError" } 
        exit 1 
    } 

} catch { 
    # 捕获 HTTP 错误，尝试提取响应体以获得 Cloudflare 错误详情
    $ErrorMessage = $_.Exception.Message
    $Response = $_.Exception.Response
    if ($Response) {
         try {
            $Stream = $Response.GetResponseStream()
            $Reader = New-Object System.IO.StreamReader($Stream)
            $ResponseText = $Reader.ReadToEnd()
            Write-Error "备注：执行 DNS 更新请求失败: $($ErrorMessage)" 
            Write-Error "Cloudflare API 原始响应内容: $ResponseText"
         } catch {
            Write-Error "备注：执行 DNS 更新请求失败: $($ErrorMessage)" 
         }
    } else {
         Write-Error "备注：执行 DNS 更新请求失败: $($ErrorMessage)"
    }
    exit 1 
}
