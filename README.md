Cloudflare API v4 Dynamic DNS Update in Bash, without unnecessary requests
Now the script also supports v6(AAAA DDNS Recoards)
在我测试中，环境一律用用户名：lz，群组：lz。
开机自运行路径位于：/etc/systemd/system/cf-ddns.service
```
 sudo systemctl daemon-reload
 sudo systemctl enable cf-ddns.service
 sudo systemctl restart cf-ddns.service
 sudo systemctl status cf-ddns.service
```
