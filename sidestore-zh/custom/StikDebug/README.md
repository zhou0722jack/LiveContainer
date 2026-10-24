# StikDebug 实验性集成

入口：SideStore → 设置 → 实验性功能 → StikDebug：JIT 与配对管理。
若上游隐藏诊断区域，先在设置中用三指上滑三次显示，再进入实验性功能。
只维护普通二合一版；极简版已停用，旧提交及已生成附件不删除。

## 功能

- 使用 StikDebug 作者推荐的 StikJIT 核心，按需加载，最低 iOS 17.4。
- 复用 SideStore 配对文件管理、iOS 26 无线配对和连接配置，不另存一套配对文件。
- 准备设备，自动下载和挂载适合系统版本的 DDI，显示实际进度和错误。
- 从设备读取带 `get-task-allow` 的 App 列表，确认后启动目标并执行 JIT 流程。
- SideStore“我的应用”长按菜单的“启用 JIT”直接执行同一内置核心，使用重签后的实际 Bundle ID，不跳转设置页、不再确认一次。
- 同时使用系统视频画中画（AVPictureInPictureController）显示日志视频，可在切到目标 App 后继续观看。
- 画中画通过 AVSampleBufferDisplayLayer 接收日志渲染帧，最多每秒更新两次，文字未变化时复用像素帧，不进行视频编码。
- 拖动、缩放、播放/暂停、关闭由系统管理；暂停/关闭只影响日志画面，不主动取消 JIT。复制完整日志放在实验页。
- 先准备画中画，再继续提交 JIT；若系统拒绝或 3 秒未能启动，则记录画中画错误并继续 JIT，不让日志窗口阻塞操作。
- iPhone/iPad 共用系统画中画路径，不创建模拟浮窗、额外应用窗口、应用扩展或 App ID，不修改容器全屏启动。
- 每个任务独立保存最多 2000 条日志，省略旧条目会显示数量，错误与完成结果会写入日志；实验页可重新开启最近日志的画中画并复制全文。
- 页面可以按名称或 Bundle ID 搜索桌面 App 和当前主实例中可见、未锁定的容器 App。
- 选择容器 App 会返回 LiveContainer，按私有/共享目录精确交接，以“内置 JIT”启动该 App。
- LiveContainer 设置的“JIT 启动工具”增加“内置 JIT”，原有选项及数值保持。
- App 列表直接读取必要的原生 plist 字段，不把完整设备元数据反序列化为 Foundation plist；
  缺失或异常条目跳过，未知的无关字段不影响其他 App，错误显示阶段及错误标识。
- 固定使用 upstream `universal.js`，强制脚本开关默认关闭。
- 可重置此功能专属的 DDI 缓存，不删除配对文件。

## 必要条件和边界

使用外置 LocalDevVPN、有效 Remote Pairing（RPPairing）文件、开发者模式和带 `get-task-allow` 的目标 App。
本入口读取 SideStore 的 `PairingFile_RemoteRP.plist`，旧 Lockdown 文件不能替代它；
不会修改侧载/刷新正在使用的配对协议。iOS 26 可在无线配对页生成，其他系统需先导入对应文件。
此集成不增加 VPN 权限、不增加应用扩展、不修改主 App 及原有扩展 ID。
独立动态 framework 的标识不是额外注册的应用 App ID。

桌面 App 继续使用已验证的直接调试路径；容器 App 使用现有 LiveProcess 扩展的另一实例执行阻塞 JIT 工作。
辅助进程接收配对数据，在私有临时文件中使用并清理，不向日志输出配对内容，不新增扩展或 App ID。
容器使用 LiveContainer 原来的普通全屏主进程启动，不创建多任务容器窗口。
先完成 DDI 准备，再保存仅限本次目标的一次性交接并重启宿主；交接检查 App、容器、时间和旧 PID。
新主进程在改写 guest 路径和加载 App 前启动辅助 LiveProcess，只对新主进程的实际 PID 执行 JIT。
确认 `CS_DEBUGGED` 后继续加载 App，保留辅助连接处理 App 发出的 JIT 内存请求；
附加状态不等于脚本完成，只有完成回调才记录成功。JIT 启用后不再重启目标。
经典模式仍需关闭或改用其他工具；若已有多任务 App 或此容器在其他实例运行，先退出后重试。
原有其他 JIT 工具和普通多任务窗口功能不改动。
隐藏和锁定 App 不从此列表暴露；启动交接仍经过 LiveContainer 原有查找及认证逻辑。
iOS 26 的目标 App 必须实现匹配 universal.js 的断点/可执行内存协议；
普通附加调试器、URL 打开成功、编译成功都不代表目标 JIT 工作。

StikJIT 的阻塞 API 只在专用串行后台队列执行。容器辅助进程通过私有 XPC 回传进度和完成结果，
完成时确认回执后清理临时配对文件；10 分钟超时则结束本次辅助进程并报告失败。
准备 DDI 在重启宿主之前完成；新主进程最多等待调试器附加 12 秒，主线程运行循环继续处理扩展和 XPC 回调。
附加失败会结束本次辅助进程，回到 LC 界面显示错误；一次性交接在新进程读取时即删除，避免重复启动。
启动状态保存在宿主 `Library/SSBuiltInJITLaunchStatus.plist`，辅助脚本延迟失败会在下次返回 LC 时显示。
启动阶段被 iOS watchdog 终止、后台扩展生命周期以及全屏目标实际 JIT 效果仍需真机验证。
页面显示真实操作结束回调；桌面 App 路径仍受 iOS 后台执行时间限制。
缓存重置同时清理桌面和辅助进程的 DDI 缓存，不删除配对文件。

配对文件不写入日志或 Actions，构建不需要 Apple 账号或证书。
连接地址复用 SideStore 的覆盖设备 IP/发现结果，未发现时使用上游默认 `10.7.0.1`；
端口使用 SideStore 的 Remote Pairing 覆盖/发现结果。可在连接配置中更正。
点击桌面 JIT 或容器启动时保存非敏感的 IP/端口配置供 LiveContainer 读取；配对文件仍使用原位置。
配对变更后重新准备；底层会校验文件格式，错误原样显示。

## 来源与构建

- StikDebug 参考：`17b1e1d90d602a228de663a10efa987a9f9e547b`，AGPL-3.0。
- StikJIT：`32287268fa5824f9edce4cb359f5833ce0cf7b00`，MPL-2.0。
- 保留 upstream idevice FFI 及脚本的各自许可证与源码。
- 实际依赖 SHA 与静态库摘要记录在源码清单；集成源码、补丁与许可证随 source-recipe.zip 分发。
- 原始仓库：https://github.com/StikDebug/StikDebug 和 https://github.com/StikDebug/StikJIT。

本集成为非官方维护版，不代表获得 StikDebug 团队背书。
完整编译、签名结构和静态校验只能证明构建层；真机配对、DDI 挂载、JIT 需要单独验收。
