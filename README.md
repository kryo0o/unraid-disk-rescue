# diskrescue —— Unraid 坏盘数据抢救插件

把原来那个交互式 bash 脚本改造成符合 **Unraid 7.3 插件规范** 的 WebGUI 插件：
在 `Tools（工具）` 里点几下就能跑，带实时进度、速度监控、断点续跑和失败清单。

> 原脚本的核心逻辑（连续 N 次低于阈值就跳过、失败清单、保留目录结构）全部保留，
> 只把"交互式 read"换成了网页表单，并把复制引擎换成更适合坏道的 `dd`。

---

## 1. 为什么不是简单把脚本塞进 .plg

Unraid 插件规范要求的是「`.plg` 清单 + `.txz` 安装包 + `/usr/local/emhttp/plugins/<name>/` 下的页面」，
而不是一个可执行脚本。这个仓库按规范提供了：

| 组件 | 路径 | 作用 |
| --- | --- | --- |
| 插件清单 | `diskrescue.plg` | Unraid 插件管理器读取的 XML（含 MD5 校验、安装/卸载指令） |
| 安装包 | `dist/diskrescue-2026.11.12.txz` | 解压到 `/`，内容为 `usr/local/emhttp/plugins/diskrescue/...` |
| 页面 | `DiskRescue.page` | 挂在 Tools 菜单，**不是** `.php` 独立入口 |
| 接口 | `include/api.php` | AJAX：启动 / 停止 / 轮询状态 |
| 核心 | `scripts/disk-rescue.sh` | 真正的复制逻辑，也可在控制台独立运行 |
| 元数据 | `package/`、`icons/` | 打包源目录与图标 |

---

## 2. 与原始脚本的差异（重要）

| 项目 | 原脚本 | 本插件 | 原因 |
| --- | --- | --- | --- |
| 复制引擎 | `cp -p` 后台 + `stat` 轮询目标文件大小 | `dd bs=1M conv=fsync`，解析 dd 报告的字节数 | `cp` 遇到坏道会静默截断；dd 会报错并停止，且能拿到精确进度 |
| 失败文件 | 直接 `rm -f` | 重命名为 `*.partial` 保留 | 已抢救出的数据不能丢，可再用 ddrescue 续读 |
| 速度判定 | 每 5 秒看一次目标文件大小 | **最近 N 秒的平均速度**（默认 10 秒） | 瞬时速度会被缓存/写盘抖动骗；窗口平均才反映真实可读性 |
| 宽限时间 | 无（15 秒就砍） | 可配置：倍数 ×（文件大小/阈值），上限、小文件宽限都能调 | 宽容"慢但正常"的大文件，同时允许调紧 |
| 目录枚举 | `timeout 120s find`，超时后结构不完整且无提示 | 超时可控、超时会提示、枚举时实时显示已找到文件数 | 坏盘上 `find` 卡住很常见 |
| 计数器 | `find ... | wc -l` 再 `find` 一遍 | `-print0` 一次枚举，计数精确且支持任意文件名 | 原逻辑会数错且多扫一遍坏盘 |
| 文件计数 | 管道 while 导致计数器失效的隐患 | `-print0` + `read -d ''` | 正确处理换行/空格文件名 |
| 路径安全 | 无校验 | 拒绝 `..`、拒绝源/目标相同、拒绝目标在源内 | 防手滑把盘写满或递归复制 |
| 交互 | `read -p` | WebGUI 表单 + 目录选择器 | 插件规范 |

---

## 3. 构建

### 3.1 在 Unraid 控制台（推荐）

把整个目录传到 Unraid（例如 `/mnt/user/appdata/unraid-disk-rescue`），然后：

```bash
cd /mnt/user/appdata/unraid-disk-rescue
chmod +x build.sh
./build.sh
```

产物：

- `dist/diskrescue-2026.11.12.txz`
- `dist/diskrescue.plg`（联网发布用）
- `dist/diskrescue-local.plg`（离线本地安装用）
- `dist/diskrescue-2026.11.12.txz.sha256`

### 3.2 在 Windows / macOS（有 Python 3）

```powershell
cd unraid-disk-rescue
python tools\make_icon.py   # 只在本机没有现成图标时需要
python build.py             # 生成 dist/diskrescue-2026.11.12.txz + dist/diskrescue.plg
python tools\check.py       # 可选：静态检查 + 功能测试（需要 bash；Windows 上装 Git 即可）
```

`build.py` 只用 Python 标准库（`tarfile` + `lzma`），不需要系统装 `tar`/`xz`；
图标缺失时会自动调用 `tools/make_icon.py`，再不行就写一个纯色占位 PNG。

> 注意：`build.py --check` 只做静态检查；完整的功能测试在 `tools/check.py`。

### 3.3 本地安装（不联网）

**方式 A：一条命令（推荐）**

```bash
cd /mnt/user/appdata/unraid-disk-rescue
bash tools/install-local.sh
```

它会把源码打包成 `/boot/config/plugins/diskrescue/package.txz`、生成带 MD5 的
`/boot/config/plugins/diskrescue.plg`，然后调用 `/usr/local/sbin/plugin install` 完成安装。
卸载：

```bash
bash tools/install-local.sh --uninstall
# 或
/usr/local/sbin/plugin remove diskrescue
```

**方式 B：手动三步（和 A 等价，便于理解）**

```bash
mkdir -p /boot/config/plugins/diskrescue
cp dist/diskrescue-2026.11.12.txz /boot/config/plugins/diskrescue/package.txz
cp dist/diskrescue-local.plg      /boot/config/plugins/diskrescue.plg
/usr/local/sbin/plugin install /boot/config/plugins/diskrescue.plg
```

**方式 C：WebGUI**

Plugins → Install Plugin，粘贴：

```
file:///boot/config/plugins/diskrescue.plg
```

查看是否已登记：

```bash
/usr/local/sbin/plugin list | grep diskrescue
```

> `/usr/local/emhttp` 是内存盘，插件文件平时是解压出来的；
> 真正让它在重启后自动恢复的是 `/boot/config/plugins/diskrescue.plg`
> 和同目录下的 `package.txz`。所以**不要**只手工解压 tar 而不放 .plg，
> 那样重启后插件会消失。

### 3.4 已发布地址

仓库：<https://github.com/kryo0o/unraid-disk-rescue>

安装地址（Unraid → Plugins → Install Plugin，直接粘贴）：

```
https://cdn.jsdelivr.net/gh/kryo0o/unraid-disk-rescue@main/dist/diskrescue.plg
```

> 用 jsDelivr 而不是 `raw.githubusercontent.com`，因为后者在国内经常无法访问；
> jsDelivr 会自己去 GitHub 抓取，国内可以正常下载。

自己重新发布：

```bash
bash build.sh --base-url https://cdn.jsdelivr.net/gh/<你>/<仓库>@main
# 或
python build.py --base-url https://cdn.jsdelivr.net/gh/<你>/<仓库>@main
```

然后提交 `dist/` 与 `icons/`。`.plg` 里的 MD5 是构建时写死的，`.txz` 更新后必须重跑构建。

> 注意：仓库根目录的 `diskrescue.plg.in` 是**模板**（含 `__MD5__` 占位符），
> 不是可安装文件；安装请用 `dist/diskrescue.plg`。

---

## 4. 使用

1. **源文件夹**：坏盘上的目录，例如 `/mnt/disk1/downloads/fsm/exo`
2. **目标文件夹**：健康磁盘上已存在的目录，例如 `/mnt/disk4/downloads/exo`
3. 先勾选 **仅预扫描** 跑一遍（只读检查每个文件首 1MB），确认坏道范围
4. 取消预扫描，点 **开始抢救**

默认速度监控：**最近 10 秒的平均速度低于 10MB/s 就跳过该文件**。

宽限规则默认：`2 × (文件大小 ÷ 10MB/s)`，上限 900 秒，小于 4MiB 的文件固定 10 秒。
宽限期内不判定；宽限结束后才用「10 秒窗口平均速度」判定。
例如 1GB 文件的宽限是 200 秒，2GB 以上基本都会顶到 900 秒上限。

如果希望更激进（一出现慢速就切），把**宽限倍数设为 0**，并把**连续判定次数**设为 1：
这样文件在攒满一个统计窗口（10 秒）后就会按窗口平均速度判定。

页面上可调（都保存在 `/boot/config/plugins/diskrescue/diskrescue.cfg`，下次打开自动带出）：

| 参数 | 默认 | 说明 |
| --- | --- | --- |
| 最低平均速度 | 10 MB/s | 0 = 关闭速度监控 |
| 统计窗口 | 10 秒 | 窗口内平均速度 |
| 采样间隔 | 2 秒 | 读取 dd 进度的频率 |
| 连续判定次数 | 1 | 连续几次窗口不达标才跳过 |
| 宽限倍数 | 2 | 0 = 不按文件大小放宽 |
| 宽限上限 | 900 秒 | 超大文件的封顶 |
| 小文件宽限 | 10 秒 | <4MiB 固定用这个值 |

**源目录和目标目录也会被记住**：下次打开页面自动带出上次用的路径，改完直接点开始。
所有参数和路径都保存在 `/boot/config/plugins/diskrescue/diskrescue.cfg`。

### 命令行用法

```bash
/usr/local/emhttp/plugins/diskrescue/scripts/disk-rescue.sh --help

# 只抢救一个目录，关闭速度监控
/usr/local/emhttp/plugins/diskrescue/scripts/disk-rescue.sh \
  --src /mnt/disk1/downloads --dst /mnt/disk4/rescue \
  --min-speed 0 --yes

# 断点续跑（跳过已存在且大小一致的文件）
... --skip-existing --yes
```

### 输出

| 位置 | 内容 |
| --- | --- |
| 目标目录/`disk-rescue-failed.txt` | 失败与跳过清单（时间 \| 原因 \| 源文件） |
| 目标目录/`*.partial` | 被中断文件的已读部分 |
| `/boot/config/plugins/diskrescue/state/` | 日志与状态（保留最近 10 份） |

---

## 5. 目录结构

```
unraid-disk-rescue/
├── diskrescue.plg.in               # 插件清单模板（__MD5__ / __PKGURL__ 由构建替换）
├── build.sh                        # Unraid 上的 shell 构建脚本
├── build.py                        # 跨平台 Python 构建脚本
├── tools/
│   ├── make_icon.py                # 纯 Python 生成图标
│   ├── check.py                    # 静态检查 + 功能测试
│   └── make_fallback_png.py
├── icons/diskrescue.png            # 给 .plg 引用的图标
├── package/                        # 打包内容（原样解压到 /）
│   └── usr/local/emhttp/plugins/diskrescue/
│       ├── DiskRescue.page         # Tools 菜单页面
│       ├── include/
│       │   ├── helpers.php         # 公共函数（路径校验/状态读取）
│       │   ├── api.php             # AJAX 接口
│       │   ├── install.sh          # 手动安装（可选）
│       │   └── uninstall.sh        # 手动卸载（可选）
│       ├── scripts/disk-rescue.sh  # 核心脚本
│       ├── css/diskrescue.css
│       ├── js/diskrescue.js
│       └── icons/diskrescue.png
└── dist/                           # 构建产物
```

---

## 6. 实现要点（给后续维护）

### 6.1 后台任务如何活过 PHP 请求

`api.php` 用 `nohup setsid bash disk-rescue.sh ... &` 启动，脚本自己写：

- `state/status`：`key=value` 状态（state/phase/total/done/ok/skipped/failed/bytes_done/speed_bps/cur_file）
- `state/disk-rescue-<时间>.log`：完整日志

前端每 2 秒 `GET api.php?action=status&offset=N`，只取新增日志。
进程存活用 `posix_kill($pid, 0)` 判断，**不依赖** PHP 的进程管理。

> 关键细节：PHP 启动子进程时，子进程会继承 PHP 的**响应管道 fd**（不止 0/1/2）。
> 如果一直持有，浏览器端会一直等「开始抢救」的响应直到整个任务结束（实测 18 秒）。
> 因此 `disk-rescue.sh` 在非交互模式下会调用 `detach_inherited_fds` 主动关闭
> `/proc/$$/fd` 中大于 2 的描述符。修改启动逻辑时不要删掉这一步。

### 6.2 为什么 dd 的字节数可信

`conv=fsync` 让 dd 在退出前把数据落盘，`status=progress` 每 0.5 秒向 stderr 写一行
`<n> bytes ... copied`。解析最后一行即可得到已复制字节数，比 `stat` 目标文件更准，
也不会被页缓存欺骗。

速度判定用的是「滑动窗口」：每次采样把 `(秒, 已复制字节)` 压入数组，
丢掉窗口外的旧样本，用 `(当前字节 − 窗口最老字节) ÷ 时间差` 得到窗口平均速度。
这样单个采样点的抖动不会误判，持续慢速才会触发。若 dd 不支持 `status=progress`
（BusyBox），会退回用目标文件大小估算进度。

### 6.3 停止

- WebGUI「停止」→ `kill -TERM` 脚本
- 脚本的 trap 置 `STOP_SIGNAL=1`，当前 dd 最多等 10 秒后 `kill -9`
- 已写入的数据改名 `*.partial`，不会删除
- `api.php` 只等 5 秒就返回（不轻易 `kill -9` 脚本），避免打断收尾导致丢数据

### 6.4 CSRF

页面把 `$var['csrf_token']` 写进 `<input id="dr-csrf">`，POST 时带 `csrf_token` 字段 +
`X-CSRF-Token` 头；`api.php` 用 `hash_equals()` 校验。取不到 token 的环境（旧版 webGUI）
降级为不校验，仍依赖 webGUI 自身登录鉴权。

---

## 7. 测试

```bash
python tools/check.py           # 静态检查 + 功能测试 + 行为测试
PHP=/path/to/php python tools/check.py   # 同时做 php -l
```

覆盖内容：

- `.plg` 结构、XML 实体、两段 `<INLINE>` 的 bash 语法
- 包内文件齐全、文本文件无 CRLF
- `bash -n`、`php -l`（有 php 时）、`node --check`（有 node 时）
- 功能：复制内容逐一比对、status 字段、`--skip-existing`、`--dry-run`、
  拒绝「源=目标」与「目标在源内」、无参数时正常报错退出
- 行为：慢速 dd 替身下验证 **窗口平均速度判卡死 → 保留 `.partial` → 退出码 3**、
  **慢速但正常不被误杀**、**中途停止 → `stopped` → `.partial` → 退出码 2**
- 行为：用「慢速 dd 替身」确定性验证 **判卡死 → 保留 `.partial` → 退出码 3**，
  以及 **中途停止 → `state=stopped` → 保留 `.partial` → 退出码 2**

在 Unraid 上也可以直接：

```bash
bash -n /usr/local/emhttp/plugins/diskrescue/scripts/disk-rescue.sh
php -l /usr/local/emhttp/plugins/diskrescue/include/api.php
```

### 退出码

| 码 | 含义 |
| --- | --- |
| 0 | 全部成功（含「已存在」跳过） |
| 1 | 参数或环境错误 |
| 2 | 被用户中断（已保留 `.partial`） |
| 3 | 有文件失败或卡死被跳过 |

---

## 8. 已知限制

- 只允许 `/mnt` 下的路径（插件规范内的安全约束）。要抢救 `/boot` 或外接挂载点需自行改 `dr_check_path()`。
- 预扫描只读每个文件首 1MB，不保证文件后段完好。
- 不处理硬链接/符号链接（符号链接会被 `find -type f` 跳过）。
- 同一时间只允许一个抢救任务（`/tmp/diskrescue/running` 锁）。
- 速度监控的判定基于 dd 的累计字节数；若关闭 `conv=fsync`，页缓存可能让速度看起来偏高。

---

## 9. 免责声明

坏盘读取存在不确定性，本工具只负责"尽力复制"，不保证数据完整性。
重要数据请优先考虑专业数据恢复服务；操作前请确认目标磁盘空间充足，
并避免在抢救过程中停止阵列或重启。
