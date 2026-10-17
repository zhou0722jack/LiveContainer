# 极简版

独立附件，保留普通版及其工作流。首页只提供四个入口：

- 侧载 App：选择本地 IPA，沿用 SideStore 的签名、权限确认和安装流程。
- 刷新 App：列出已侧载 App 的到期时间，支持单个续签和刷新全部。
- 容器安装 App：导入 IPA 并列出容器 App，点击运行；从已登录账号同步容器签名证书。
- 登录账号：沿用 SideStore 的 Apple 账号登录、双重验证和退出流程。

账号页的“首次配置”保留配对文件、连接及 Anisette 配置。首次启动继续使用上游的初始化引导。
不集成 VPN，侧载和刷新前仍需连接外置 LocalDevVPN。
这是一版界面精简，底层仍使用两个项目的核心实现，不承诺包体显著变小。

## 构建

Actions → **Build Minimal LiveContainer + SideStore** → Run workflow。
每日北京时间 08:00 检查双上游；输入未变时跳过，手动运行始终构建。
附件 **LiveContainer-SideStore-Minimal** 包含 `LiveContainer+SideStore-Minimal.ipa`。

```sh
python3 sidestore-zh/build.py check --variant minimal
python3 sidestore-zh/build.py prepare --variant minimal
python3 sidestore-zh/build.py build --variant minimal
python3 sidestore-zh/build.py package --variant minimal
```

默认写入 `.build/minimal/`，成功状态单独记录在 `.last-success/minimal/`。
普通版不应用本目录的补丁；两版分别上传附件，构建失败保留旧成果。

## 安装和验证边界

按用户选择，两版使用相同主 App 和扩展 ID，不能同时安装。
极简版用于覆盖更新现有版，不应先卸载应用；安装器仍需复用此前的签名 ID。
相同源码 ID 不保证不同安装器一定复用已有注册记录。
不增加扩展，也不能提前释放 Apple 账号已占用的 App ID 配额。

完整源码构建与包内静态检查不代表真机登录、侧载、刷新、配对和容器运行通过。
初次使用或上游发生变动时，需要在设备上验证四个入口及返回首页。
