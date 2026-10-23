# StikDebug 实验性集成

入口：SideStore → 设置 → 实验性功能 → StikDebug：JIT 与配对管理。
若上游隐藏诊断区域，先在设置中用三指上滑三次显示，再进入实验性功能。
只维护普通二合一版；极简版已停用，旧提交及已生成附件不删除。

## 功能

- 使用 StikDebug 作者推荐的 StikJIT 核心，按需加载，最低 iOS 17.4。
- 复用 SideStore 配对文件管理、iOS 26 无线配对和连接配置，不另存一套配对文件。
- 准备设备，自动下载和挂载适合系统版本的 DDI，显示实际进度和错误。
- 从设备读取带 `get-task-allow` 的 App 列表，确认后启动目标并执行 JIT 流程。
- 固定使用 upstream `universal.js`，强制脚本开关默认关闭。
- 可重置此功能专属的 DDI 缓存，不删除配对文件。

## 必要条件和边界

使用外置 LocalDevVPN、有效配对文件、开发者模式和带 `get-task-allow` 的目标 App。
此集成不增加 VPN 权限、不增加应用扩展、不修改主 App 及原有扩展 ID。
独立动态 framework 的标识不是额外注册的应用 App ID。

此入口调试其他已侧载 App，明确排除当前二合一宿主。进程无法为自身附加调试器；
不提供自调试或为容器中当前进程自动启用 JIT 的承诺。LiveContainer 原有 JIT 流程保持。
iOS 26 的目标 App 必须实现匹配 universal.js 的断点/可执行内存协议；
普通附加调试器、URL 打开成功、编译成功都不代表目标 JIT 工作。

StikJIT 的阻塞 API 只在一个专用串行后台队列执行。页面显示真实操作结束回调；
未实现中断底层 FFI 的取消操作。目标切到前台后，iOS 仍可能暂停二合一进程，
必要时返回本 App 查看实际结果，不能保证无限后台运行。

配对文件不写入日志或 Actions，构建不需要 Apple 账号或证书。
连接地址复用 SideStore 的覆盖设备 IP/发现结果，未发现时使用上游默认 `10.7.0.1`；
端口使用 SideStore 的 Remote Pairing 覆盖/发现结果。可在连接配置中更正。
配对变更后重新准备；底层会校验文件格式，错误原样显示。

## 来源与构建

- StikDebug 参考：`17b1e1d90d602a228de663a10efa987a9f9e547b`，AGPL-3.0。
- StikJIT：`32287268fa5824f9edce4cb359f5833ce0cf7b00`，MPL-2.0。
- 保留 upstream idevice FFI 及脚本的各自许可证与源码。
- 实际依赖 SHA 与静态库摘要记录在源码清单；集成源码、补丁与许可证随 source-recipe.zip 分发。
- 原始仓库：https://github.com/StikDebug/StikDebug 和 https://github.com/StikDebug/StikJIT。

本集成为非官方维护版，不代表获得 StikDebug 团队背书。
完整编译、签名结构和静态校验只能证明构建层；真机配对、DDI 挂载、JIT 需要单独验收。
