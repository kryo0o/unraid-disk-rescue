# 已废弃：安装/卸载逻辑已内联到 diskrescue.plg

本目录下的 `install.sh` / `uninstall.sh` 是早期版本，**不再使用**，也不会被打进
`.txz`（`build.py` 的 `EXCLUDE_REL` 与 `build.sh` 的 `--exclude` 都会跳过）。

现在的安装方式：

| 场景 | 做法 |
| --- | --- |
| 通过插件管理器安装 | 直接安装 `dist/diskrescue.plg`，安装/卸载指令内联在 `.plg` 的 `<INLINE>` 中 |
| 本地开发调试 | `bash tools/install-local.sh`（卸载加 `--uninstall`） |
| 打包后本地安装 | `./build.sh --install` |

保留这两个文件只是为了避免破坏早期引用，可以安全删除。
