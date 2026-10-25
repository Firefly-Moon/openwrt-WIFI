> 声明：该项目仅供个人学习、交流，请遵守当地法律法规，勿用于非法用途；请勿用于生产环境。

# openwrt-WIFI

在 OpenWrt / Kwrt 软路由或无线路由器上一键创建独立 WiFi，并将该独立网段的访问控制（ACL）完整绑定到指定的 VLESS Reality 节点。

## 功能介绍

1. **自动检测并安装组件**：自动检测 `luci-app-passwall` 与支持 VLESS Reality（`xtls-rprx-vision`）的 `xray-core`，缺失时自动通过 `opkg` 或 `apk` 安装。
2. **创建独立隔离网段与 WiFi**：支持选择 `2.4GHz` 或 `5GHz` 频段，自动分配独立网段（`192.168.x.0/24`）、独立桥接接口及防火墙区域，与家庭局域网完全隔离，并自动启用当前无线硬件支持的最高信道宽度。
3. **PassWall 访问控制（ACL）全流量绑定**：
   - 仅匹配该独立 WiFi 源接口，TCP / UDP 全部走指定 VLESS Reality 节点；
   - 禁止未进入节点的流量转发到 WAN，防止节点中断时回落家庭宽带造成真实 IP 暴露；
   - DNS 采用远程代理模式（`1.1.1.1`），并关闭 IPv6 及过滤代理 IPv6，杜绝 DNS 与 WebRTC/IPv6 泄露；
   - 关闭中国列表、GFW 列表及直连/分流列表，不继承 PassWall 全局分流规则；
   - 屏蔽该 WiFi 访问路由器后台管理端口（`22`、`80`、`443`、`7681`）并开启客户端隔离。
4. **支持重复执行**：可多次运行脚本创建多个不同名称、绑定不同节点的独立 WiFi。

## 配置要求

- **系统**：OpenWrt / Kwrt（已配置无线网卡及 PassWall 环境）
- **内存**：最低 128MB，推荐 256MB 及以上
- **网络**：路由器需能正常联网以拉取脚本及所需软件包

## 一键运行（jsDelivr CDN 国内加速）

为避免国内路由器无法直接连接 GitHub，请使用下方带 **jsDelivr CDN** 加速的一键命令在路由器 SSH 终端中执行：

```sh
wget -O /tmp/openwrt-WIFI.sh https://cdn.jsdelivr.net/gh/taozi00001/openwrt-WIFI/openwrt-WIFI.sh && sh /tmp/openwrt-WIFI.sh
```

兼容旧文件名调用命令：

```sh
wget -O /tmp/openwrt-tiktok-wifi.sh https://cdn.jsdelivr.net/gh/taozi00001/openwrt-WIFI/openwrt-tiktok-wifi.sh && sh /tmp/openwrt-tiktok-wifi.sh
```
