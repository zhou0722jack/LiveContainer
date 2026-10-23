# LiveContainer + SideStore 简体中文自动构建

Fork [LiveContainer/LiveContainer](https://github.com/LiveContainer/LiveContainer)，
把本交付包内 `.github/workflows/build-zh.yml` 和整个 `sidestore-zh/` 目录
加入你的 Fork。主仓库负责运行构建；两个应用源码在每次构建中分别获取。
以后维护自定义功能只需改补丁，不必反复手动合并两个完整项目。

## 启用

1. GitHub 上 Fork LiveContainer/LiveContainer，保留默认分支 `main` 即可。
2. 将交付包中的文件按原目录结构加入 Fork 的默认分支。
   `.github` 是隐藏目录，必须一起上传；GitHub 网页不会自动解压 ZIP。
   macOS Finder 可用 `Command + Shift + .` 显示隐藏目录。
   不需要上传旧聊天的 `work/` 或 `outputs/`。
3. 进入你的 Fork → Actions，启用工作流。建议禁用 Fork 自带的旧 `Xcode - Build`
   和更新应用源工作流，避免生成另一套上游原包或触发原有发布流程。
4. 选择 **Build Chinese LiveContainer + SideStore → Run workflow**。
   默认跟踪上游最新源码；`pinned` 勾选后使用 2026-10-23 核对的固定提交。
5. 成功后，在该次运行底部下载 **LiveContainer-SideStore-zh-Hans** 附件，
   解压得到 `LiveContainer+SideStore-zh-Hans.ipa`、校验报告和构建记录。
   它仍需使用 iloader 等工具以自己的账号签名安装，并保留应用扩展。

如果通过 Git 命令上传，在你已经克隆的 Fork 根目录合并交付文件后，
只需将 `.github/workflows/build-zh.yml` 和 `sidestore-zh/` 加入提交。
不要用交付包替换整个 Fork 或覆盖原有 `.github/` 目录。

仅构建和上传 Actions 附件，不会自动发布 Releases。无需提供 Apple ID、密码、
开发者证书或个人 GitHub Token；工作流只申请仓库读取权限。

## 每日同步

- 每天 UTC 00:00，即北京时间 08:00 检查。GitHub 调度可能延迟。
- 跟踪 `LiveContainer/LiveContainer:main` 和 `SideStore/SideStore:develop`。
- 两个项目都从源码编译，不下载旧的官方二合一 IPA 作为宿主。
- 固定每次获取的完整源码 SHA，子模块跟随该 SHA，Swift 包遵循对应
  `Package.resolved`。dylibify 固定到 `inputs.lock.json` 中的提交。
- 上游源码或本仓库的汉化、脚本、自定义补丁有变化时构建；与上次成功构建
  相同的定时任务跳过编译。缓存缺失时会重新构建。手动运行始终构建。
- 推送到本仓库、且改动涉及这套工作流或 `sidestore-zh/` 时也会构建。
- 这不会向你的 Fork 的 `main` 自动写入上游提交。同步发生在独立构建目录内，
  精确来源见每次附件的 `build-provenance.json`。

GitHub Fork 的定时工作流需要先启用，并且仅在默认分支运行；长期不活跃的公开
仓库可能被 GitHub 暂停定时工作流。参见 [GitHub 定时触发说明](https://docs.github.com/en/actions/reference/workflows-and-actions/events-that-trigger-workflows#schedule)。

## 汉化和自己的功能

目前保留已有 SideStore 汉化：源码补丁和 1,289 条中文资源表。上游新增文案
不会自动翻译；旧补丁在上游改动后可能产生冲突，需要维护。
修改内置汉化补丁、中文资源表或历史 `Package.resolved` 后，需要同步更新
`inputs.lock.json` 中 `files` 的 SHA-256；自定义功能补丁不需要修改这组摘要。

已加入 [StikDebug JIT 与配对管理](custom/StikDebug/README.md)实验入口，使用按需加载的 StikJIT 核心。
不增加 VPN、应用扩展或 App ID；仍需外置 LocalDevVPN，且不能调试当前二合一进程自身。
极简版已停用，保留历史提交与附件，后续只维护本普通版工作流。

自定义功能入口是 [custom/series.json](custom/series.json)，SideStore 列表包含 StikDebug 实验入口。
以后分别向 `LiveContainer`、`SideStore` 的列表添加补丁。详见
[自定义补丁说明](custom/README.md)。流程顺序为：获取上游 → 应用汉化 →
应用自己的功能 → 分别编译 → 整合与静态校验。不会在构建失败时替换现有成果。

普通补丁应用失败时尝试三方合并；冲突仍然存在便停止，完整日志上传到
`zh-build-logs`。不会删除你的补丁，也不会静默退回英文包。

## 工具链与问题定位

GitHub runner 使用 `macos-26`，默认 Xcode `26.4`，与此版 SideStore 官方
Nightly 配置一致。若未来源码要求更新工具链，在 Fork 的 Settings →
Secrets and variables → Actions → Variables 添加 `XCODE_VERSION`，填写
GitHub runner 实际提供的版本。不要为这个变量填写账号或密钥。

`verification-zh.json` 验证包结构、文件完整性、动态库转换、刷新 Intent 映射、
扩展身份、执行权限和改动组件临时签名。宿主逐字节比较的基线是本次本地编译
且添加集成 plist 字段后的宿主，不表示它与官方发布二进制一致。

所有构建产物均不代表真机安装、Apple ID 登录、双重验证、配对/VPN、刷新、
快捷指令、小组件或容器内应用运行已通过。包内临时签名不授予手机安装权限。
原聊天中 Lockdown 与 rppairing 的设备配对问题没有在这里改动。

## 本地运行

需要 macOS、完整 Xcode、Python 3.9+、Git 和系统 codesign/zip。先设置
`DEVELOPER_DIR` 指向完整 Xcode。默认将一代构建写入忽略的 `.build/`。

```sh
python3 sidestore-zh/build.py check
python3 sidestore-zh/build.py prepare
python3 sidestore-zh/build.py build
python3 sidestore-zh/build.py package
```

已有一代目录时应保留，并给每一步传入相同的新 `--build-root`，例如
`--build-root sidestore-zh/.build/run-2`。`--pinned` 应在 check 阶段传入。
脚本不自动清理失败代次。

## 来源和许可证

这是非官方维护构建。完整上游源码分别来自
[LiveContainer](https://github.com/LiveContainer/LiveContainer)、
[SideStore](https://github.com/SideStore/SideStore) 和
[dylibify](https://github.com/LiveContainer/dylibify)。许可证保存在 `licenses/`。
附件 `source-recipe.zip` 包含构建脚本、补丁、许可证、实际源码提交以及实际使用的
依赖锁；`source-manifest.json` 记录构建前源码文件摘要。公开分发修改版本时应
保留来源、许可证及对应源码获取方式。以后新增的补丁亦需保留适用的许可证。
