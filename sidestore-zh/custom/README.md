# 自定义功能补丁

将相对对应项目仓库根目录的 Git diff 保存为 `.patch` 文件，在 `series.json`
中按顺序填写相对本目录的路径。例如：

```json
{
  "LiveContainer": ["LiveContainer/my-feature.patch"],
  "SideStore": ["SideStore/my-feature.patch"]
}
```

这些文件名是示例；当前两个列表为空。SideStore 先应用汉化，再应用自己的功能。
补丁先尝试普通应用，再尝试 Git 三方合并。冲突会停止本次构建，日志上传至 Actions。
如果自定义补丁需要三方合并基线，在 `inputs.lock.json` 对应项目的 `patch_bases`
数组加入创建补丁时的完整提交 SHA。汉化补丁基线会自动获取。

不要直接修改构建时下载的临时源码。不要将账号、证书、私钥或配对文件放入补丁。
新增功能需要进行相应真机验证。
