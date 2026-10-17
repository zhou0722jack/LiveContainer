# 本地验证记录

核对日期：2026-10-17（Asia/Shanghai）。

- LiveContainer 上游 `main`：`4dbe0f9a626de801184a42c0be8d2cb105058e3d`。
- SideStore 上游 `develop`：`d97ec133719d79916675bdaf722b82a8d091d545`。
- dylibify：`5daf713df9fb07724510490c88aa8e00061be14a`。
- `actionlint v1.7.12`：工作流语法检查通过。
- Python 行为测试：3 项通过，覆盖定时跳过、手动强制构建、三方合并和冲突停止。
- 实际源码准备：通过。使用独立目录中的 Git checkout；未初始化的 LiveContainer
  依赖从上游获取。未修改原聊天的源码或已生成 IPA。
- 汉化源码检查：125 个文件；1,665 处 Swift 文案；1,289 条资源；插值、占位符、
  Storyboard 布局与标识符检查通过。
- 本机使用 Xcode 27.0 beta / iPhoneOS 27.0 SDK。GitHub 配置默认 Xcode 26.4，
  因此本地结果不能替代 GitHub runner 的首次完整构建。
- 双项目源码归档：SideStore 与 LiveContainer 均显示 `ARCHIVE SUCCEEDED`。
- 二合一打包及最终静态验证：通过，293 项包检查；109 个保留宿主文件
  与本次源码编译的宿主基线一致；155 个 SideStore 资源/依赖文件复制一致。
- 最终 IPA：`LiveContainer+SideStore-zh-Hans.ipa`，35,369,754 字节。
  SHA-256：`bf1d485676bcb410a43f79205905e6a0bfc15d3e0a9f288991fc5aea3f2a48e9`。
- 包内版本：LiveContainer 3.8.10、SideStore 0.7.0；具体 Nightly 来源由上方
  源码提交标识，不沿用原官方 Actions 构建号。

首次本地准备发现原镜像未初始化 OpenSSL，已补充缺失依赖的网络回退。
首次归档被 Xcode 拒绝同时指定 `-destination` 与 `-arch`，已改用 `ARCHS=arm64`。
失败代次和旧日志保留于忽略的 `.build/`，未覆盖原聊天产物。

GitHub Actions 实际运行：UNRUN，尚未提供或配置目标 Fork。
真机安装、界面排版、Apple ID 登录、双重验证、配对/VPN、刷新、小组件和容器
应用启动：UNRUN。
