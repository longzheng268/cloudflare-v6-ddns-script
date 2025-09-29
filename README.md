# Cloudflare DDNS 脚本集合

🚀 **功能完整的 Cloudflare 动态 DNS 更新脚本**，支持 IPv4/IPv6 双栈，多平台兼容，专为家庭网络和服务器环境设计。

## ✨ 特性亮点

- 🔄 **双协议支持**: IPv4 (A记录) 和 IPv6 (AAAA记录)
- 🌍 **多平台兼容**: Linux、macOS、Windows (PowerShell)
- 🛡️ **智能过滤**: 自动过滤 ULA、Link-Local 等无效 IPv6 地址
- ⚡ **多种获取方式**: 外部查询 + 内部路由表查询
- 🎯 **用户友好**: 交互式参数提示，完整帮助系统
- 💾 **智能缓存**: 避免不必要的 API 调用
- 🔧 **易于配置**: 支持环境变量和命令行参数

## 📁 文件说明

| 文件名 | 平台 | 协议支持 | 推荐用途 |
|--------|------|----------|----------|
| `cf-v6-ddns.sh` | Linux/macOS | IPv6 (AAAA) | **主推荐脚本** - 功能最全 |
| `cf-v4-ddns.sh` | Linux/macOS | IPv4 (A) | IPv4 更新 |
| `Update-CloudflareDDNS.ps1` | Windows | IPv6 (AAAA) | Windows 环境 |
| `cf-ddns.service` | Linux | - | systemd 服务配置 |

## 🚀 快速开始

### 1. 获取 Cloudflare API 凭据

前往 [Cloudflare Dashboard](https://dash.cloudflare.com/profile/api-tokens)：
- **API Key**: `我的个人资料` → `API 密钥` → `Global API Key`
- **邮箱**: 您的 Cloudflare 账户邮箱

### 2. 脚本配置 (推荐使用 cf-v6-ddns.sh)

编辑脚本文件，修改以下变量：

```bash
# 必需配置
CFKEY="your_global_api_key_here"           # Cloudflare Global API Key
CFUSER="your-email@example.com"            # Cloudflare 账户邮箱
CFZONE_NAME="example.com"                  # 您的域名
CFRECORD_NAME="home.example.com"           # 要更新的完整域名
```

### 3. 基本使用

```bash
# 下载并设置权限
chmod +x cf-v6-ddns.sh

# 查看帮助信息
./cf-v6-ddns.sh -?

# 使用内部IPv6获取 (推荐，避免外部限流)
./cf-v6-ddns.sh -i INTERNAL

# 强制更新DNS记录
./cf-v6-ddns.sh -f true

# 更新IPv4记录
./cf-v4-ddns.sh -t A
```

## 📋 详细参数说明

### cf-v6-ddns.sh (主脚本)

| 参数 | 说明 | 示例 | 默认值 |
|------|------|------|--------|
| `-h <hostname>` | 覆盖目标主机名 | `-h home.example.com` | 脚本内配置 |
| `-z <domain>` | 覆盖域名 | `-z example.com` | 脚本内配置 |
| `-t <A\|AAAA>` | 记录类型 | `-t AAAA` | AAAA |
| `-i <模式>` | IP获取方式 | `-i INTERNAL` | EXTERNAL |
| `-f <true\|false>` | 强制更新 | `-f true` | false |
| `-d <true\|false>` | 调试模式 | `-d true` | false |
| `-?` | 显示帮助 | `-?` | - |

### IP 获取模式详解

| 模式 | 原理 | 优势 | 限制 |
|------|------|------|------|
| **EXTERNAL** | 通过外部网站查询 | 简单可靠 | 可能被限流 |
| **INTERNAL** | 从本地路由表获取 | 无外部依赖，更快 | 需要正确的IPv6配置 |

## 🛠️ 平台特定指南

### Linux 系统

#### 手动运行
```bash
# 一次性运行
./cf-v6-ddns.sh -i INTERNAL

# 定期检查 (推荐5-15分钟)
# 编辑 crontab: crontab -e
*/10 * * * * /path/to/cf-v6-ddns.sh -i INTERNAL >/dev/null 2>&1
```

#### Systemd 服务 (推荐)
```bash
# 复制服务文件
sudo cp cf-ddns.service /etc/systemd/system/

# 编辑服务文件，修改脚本路径
sudo nano /etc/systemd/system/cf-ddns.service

# 启动服务
sudo systemctl daemon-reload
sudo systemctl enable cf-ddns.service
sudo systemctl start cf-ddns.service

# 检查状态
sudo systemctl status cf-ddns.service
```

### macOS 系统

macOS 完全支持，建议使用 `INTERNAL` 模式：

```bash
# 检查 IPv6 连接
ifconfig | grep inet6

# 运行脚本
./cf-v6-ddns.sh -i INTERNAL

# 使用 launchd 定时任务 (可选)
# 创建 ~/Library/LaunchAgents/com.cloudflare.ddns.plist
```

### Windows 系统

使用 PowerShell 脚本：

```powershell
# 以管理员身份运行 PowerShell
Set-ExecutionPolicy -ExecutionPolicy RemoteSigned -Scope CurrentUser

# 编辑脚本配置
notepad Update-CloudflareDDNS.ps1

# 运行脚本
.\Update-CloudflareDDNS.ps1

# 计划任务 (可选)
# 使用任务计划程序创建定期执行任务
```

## 🔧 故障排除

### IPv6 ULA 地址问题
**错误**: `ERROR: 无法获取有效的 IPv6 地址 (WAN_IP: 'fdfe:dcba:9876::1')`

**原因**: 脚本检测到 ULA (Unique Local Address) 私有地址

**解决方案**:
1. 检查您的网络是否真正获得了公网IPv6地址
2. 使用外部模式: `-i EXTERNAL`  
3. 联系ISP确认IPv6公网地址分配

### 参数错误
**错误**: `option requires an argument`

**原因**: 参数缺少必需值

**解决方案**:
```bash
# 错误用法
./cf-v6-ddns.sh -h

# 正确用法  
./cf-v6-ddns.sh -h home.example.com
./cf-v6-ddns.sh -?  # 查看完整帮助
```

### API 认证失败
**错误**: `获取 Zone ID 失败`

**解决方案**:
1. 确认 API Key 正确性 (Global API Key，不是 Token)
2. 确认邮箱地址正确
3. 检查域名是否在该账户下
4. 使用调试模式: `-d true`

### IPv6 格式验证问题
现已修复压缩格式支持，如 `2409:8a1e:8f42::af7` 这样的地址现在能正确识别。

## 🔒 安全提示

1. **保护 API 凭据**: 
   - 设置文件权限: `chmod 600 cf-v6-ddns.sh`
   - 避免将凭据提交到版本控制

2. **使用专用 Token**: 
   - 推荐创建权限受限的 API Token 而非 Global Key
   - 只给予 Zone:Read、DNS:Edit 权限

3. **日志安全**:
   - 检查日志文件权限
   - 定期清理包含敏感信息的日志

## 📊 更新日志

### 最新优化 (v2.0)
- ✅ **修复 ULA 地址过滤**: 强力过滤 `fc00::/7` 和 `fd00::/8` 地址段
- ✅ **IPv6 压缩格式支持**: 正确识别 `::` 压缩格式
- ✅ **改进参数解析**: 友好的错误提示，避免系统原生错误消息
- ✅ **macOS 完整支持**: 使用 `ifconfig` 实现内部 IPv6 获取  
- ✅ **增强调试功能**: 更详细的错误诊断和解决建议

### 历史版本
- **v1.5**: 添加 INTERNAL 模式支持
- **v1.0**: 基础 Cloudflare DDNS 功能

## 🆘 获取帮助

- **脚本帮助**: `./cf-v6-ddns.sh -?`
- **调试模式**: `./cf-v6-ddns.sh -d true`
- **GitHub Issues**: 提交详细的错误日志和系统信息

## 📄 许可证

MIT License - 详见 LICENSE 文件
