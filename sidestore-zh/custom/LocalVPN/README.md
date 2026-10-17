# SideStore 内置 LocalVPN

此功能基于 [SiamSadik/LocalDevVPN](https://github.com/SiamSadik/LocalDevVPN)，
固定参考提交 `1b9ff7a2d79b4208919bb291f0c693b8cfabb6a5`。
原始项目及隧道代码作者为 SideStore Team / Stossy11，/32 路由修复来自 SiamSadik。
保留原项目许可证 `LICENSE-LocalDevVPN`，同时随 IPA 附上许可证，在设置中显示出处。
此集成使用原项目代码，增加了输入校验、停止控制、对端过滤和可测试的数据包转换；
它是 SideStore 的实验性功能，不是 LocalDevVPN 原应用的重发。

## 入口与行为

SideStore → 设置 → 实验性功能 → 内置 LOCALVPN。

- 刷新 App 时自动开启：刷新组进入 Minimuxer 就绪检查前启动 VPN，等待连接完成；
  失败停止刷新并保留可读错误。快捷指令在 LiveProcess 内刷新时，沿现有 XPC
  通道请求真正的宿主启动已授权的 VPN，最多等待 20 秒；通信失败或超时停止刷新。
- 打开 SideStore 时自动开启：SideStore 进入前台时尝试连接。

两个偏好分别持久化且默认关闭；关闭开关不主动断开正在使用的隧道。
并发的启动/刷新共享一次连接任务，不重复创建配置。不会启用系统按需连接。
“VPN 状态与配置”可连接、断开、查看错误、修改两个 IPv4 地址。
首次使用需在前台允许 iOS 添加 VPN 配置；后台不会尝试新增/修改配置。

默认隧道地址 `10.7.0.0`、对端地址 `10.7.0.1`，均可修改。
保留 /32 接口地址和 /32 对端路由，排除默认路由；不配置 DNS，不连接外部服务器。
某些 iOS 26.4+ 网络环境需要两个可用的当前 Wi-Fi 同子网地址，应按实际网络设置，
不可把路由器、DNS 或已使用的设备地址设为隧道/对端地址。
VPN 连接成功只表明 Network Extension 已启动，配对、锁定服务通信、刷新和真机界面仍需验证。

## 二合一安装与签名

扩展独立源码编译后放在真正安装的 `LiveContainer.app/PlugIns/LocalVPN.appex`。
SideStore 使用现有 `Bundle.Info.activeBundle` 宿主映射，从扩展 Info.plist 读取实际 Bundle ID，
适应安装重签名后的标识，不能用 SideStore framework 的 Bundle ID 推导。
外层应用和扩展均声明 `packet-tunnel-provider`，外层另声明 `allow-vpn`。
打包后重新签封外层应用，并验证宿主代码除签名外不变以及扩展位置和权限。

IPA 中的临时签名不能代替有效的安装描述文件。安装签名工具必须保留该扩展，
为宿主和扩展提供相应 VPN 权限；不支持这些权限的签名方式无法运行内置 VPN。
不要删除其他 LiveContainer 扩展来掩盖签名失败。

GitHub 的双上游同步机制保持原样。本功能以独立 SideStore 和 LiveContainer 补丁加入队列；
参考 LocalDevVPN 提交固定，后续更新需单独审查。
