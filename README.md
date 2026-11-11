# diskrescue · 坏盘数据抢救

把健康状态不佳的磁盘上的文件，尽可能完整地复制到另一块健康磁盘。

支持三种用法：**Unraid 插件**、**Docker**、**命令行脚本**。复制过程中按「最近 N 秒的平均速度」判断卡死，
自动跳过无响应的文件，并把已读出的数据保留为 `*.partial`，之后可以继续抢救。

```
https://github.com/kryo0o/unraid-disk-rescue
```

---

## 目录

- [快速开始](#快速开始)
- [Docker 部署](#docker-部署)
- [Unraid 插件](#unraid-插件)
- [参数说明](#参数说明)
- [使用流程](#使用流程)
- [常见问题](#常见问题)
- [项目结构](#项目结构)
- [开发与发布](#开发与发布)
- [设计说明](#设计说明)
- [已知限制](#已知限制)
- [许可](#许可)

---

## 快速开始

| 方式 | 适用场景 | 入口 |
| --- | --- | --- |
| Docker | 任意 Linux / Unraid，最省事 | `ghcr.io/kryo0o/diskrescue:latest` |
| Unraid 插件 | 想集成进 Tools 菜单 | 在线安装地址（见下文） |
| 命令行 | 无 Web、脚本化、远程 SSH | `scripts/disk-rescue.sh` |

三者使用的是**同一份核心脚本和同一套页面**，行为完全一致。

---

## Docker 部署

镜像公开，支持 `linux/amd64` 与 `linux/arm64`，由 GitHub Actions 自动构建。

### 直接运行

```bash
docker run -d --name diskrescue --restart unless-stopped \
  -p 8080:80 \
  -v /mnt:/mnt \
  -v /srv/diskrescue:/data \
  ghcr.io/kryo0o/diskrescue:latest
```

然后打开 `http://<NAS-IP>:8080/`。

### docker compose

```yaml
services:
  diskrescue:
    image: ghcr.io/kryo0o/diskrescue:latest
    container_name: diskrescue
    restart: unless-stopped
    ports:
      - "8080:80"
    environment:
      TZ: Asia/Shanghai
      # DR_USER: admin
      # DR_PASS: "换成你的密码"
    volumes:
      - /mnt:/mnt
      - ./diskrescue-data:/data
```

```bash
docker compose up -d
```

### Unraid Docker 页面添加

| 字段 | 值 |
| --- | --- |
| Repository | `ghcr.io/kryo0o/diskrescue:latest` |
| Network | Bridge |
| Port | `8080` → `80` |
| Path 1 | `/mnt` → `/mnt`（读写） |
| Path 2 | `/mnt/user/appdata/diskrescue` → `/data`（读写） |
| 变量 | `DR_USER` / `DR_PASS` 可选，启用登录 |

### 卷与环境变量

| 容器内 | 用途 |
| --- | --- |
| `/mnt` | 要被抢救/写入的磁盘，必须挂载 |
| `/data` | 配置、日志、状态，建议持久化 |

| 变量 | 默认 | 说明 |
| --- | --- | --- |
| `TZ` | `Asia/Shanghai` | 日志时区 |
| `DR_USER` / `DR_PASS` | 空 | 设置后启用 HTTP Basic 认证 |
| `DR_DATA_DIR` | `/data` | 配置与日志目录 |
| `DR_CSRF_TOKEN` | 空 | 非空时校验 CSRF，一般不用设 |

> 容器内以 root 运行（否则无法读写 `/mnt/diskX`），页面本身没有登录。
> 请只在可信内网暴露端口，或务必设置 `DR_USER`/`DR_PASS`。

---

## Unraid 插件

要求 **Unraid 7.3+**。插件文件托管在 GitHub Pages（自定义域名 `blog.kryoo.de`）。

### 在线安装

**Plugins → Install Plugin**，粘贴：

```
https://blog.kryoo.de/unraid-disk-rescue/dist/diskrescue.plg
```

装完 `Ctrl+F5` 刷新，打开 **Tools（工具）→ 坏盘数据抢救**。

### 下载失败时换入口

清单内容和安装包完全相同，只是下载通道不同，任选一条能通的：

| 入口 | 地址 |
| --- | --- |
| Pages（主） | `https://blog.kryoo.de/unraid-disk-rescue/dist/diskrescue.plg` |
| GitHub 加速（纯 IPv4） | `https://ghfast.top/https://raw.githubusercontent.com/kryo0o/unraid-disk-rescue/main/dist/diskrescue-ghfast.plg` |
| GitHub 加速（备用） | `https://gh-proxy.com/https://raw.githubusercontent.com/kryo0o/unraid-disk-rescue/main/dist/diskrescue-ghproxy.plg` |
| jsDelivr | `https://cdn.jsdelivr.net/gh/kryo0o/unraid-disk-rescue@v2026.11.12/dist/diskrescue-jsdelivr.plg` |

> **不要用** `raw.githubusercontent.com` 或 GitHub Release 附件：
> 前者在国内常被 DNS 污染成 `0.0.0.0`，后者会 302 到 `release-assets.githubusercontent.com`（同样不可达），
> 表现就是 `download failure: Network failure`。

### 离线 / 命令行安装

```bash
# 一条命令：打包到 /boot 并注册
bash tools/install-local.sh

# 卸载
bash tools/install-local.sh --uninstall
```

或者手动三步：

```bash
mkdir -p /boot/config/plugins/diskrescue
cp dist/diskrescue-2026.11.12.txz /boot/config/plugins/diskrescue/package.txz
cp dist/diskrescue-local.plg      /boot/config/plugins/diskrescue.plg
/usr/local/sbin/plugin install /boot/config/plugins/diskrescue.plg
```

> `/usr/local/emhttp` 是内存盘：只手工解压 tar 而不放 `.plg`，重启后插件会消失。

---

## 参数说明

| 参数 | 默认 | 说明 |
| --- | --- | --- |
| 源文件夹 | — | 坏盘上的目录，如 `/mnt/disk1/xxx` |
| 目标文件夹 | — | 健康磁盘上**已存在**的目录，如 `/mnt/disk4/xxx` |
| 最低平均速度 | 10 MB/s | 窗口平均低于此值判定卡死；0 = 关闭监控 |
| 统计窗口 | 10 秒 | 用最近 N 秒的平均速度判定，避免瞬时抖动误判 |
| 采样间隔 | 2 秒 | 读取 dd 已复制字节数的频率 |
| 连续判定次数 | 1 | 连续几次窗口不达标才跳过 |
| 宽限倍数 | 2 | 宽限 = 倍数 ×（文件大小 ÷ 阈值速度），期间不判定；0 = 不按大小放宽 |
| 宽限上限 | 900 秒 | 超大文件的封顶 |
| 小文件宽限 | 10 秒 | < 4MiB 固定使用该值 |
| 跳过已存在 | 开 | 目标中大小一致的文件直接跳过（断点续跑） |
| 强制落盘 | 开 | `dd conv=fsync`，速度更真实但略慢 |

页面上的参数与**源/目标路径都会被记住**，保存在 `/boot/config/plugins/diskrescue/diskrescue.cfg`（容器里是 `/data`）。

**关于宽限**：默认 2× 时，1GB 文件要等约 200 秒才开始判定。
想让「10 秒平均低于 10MB/s 就立即跳过」，把**宽限倍数设为 0**。

**退出码**（命令行模式）：

| 码 | 含义 |
| --- | --- |
| 0 | 全部成功（含「已存在」跳过） |
| 1 | 参数或环境错误 |
| 2 | 被用户中断（已保留 `.partial`） |
| 3 | 有文件失败或卡死被跳过 |

---

## 使用流程

1. **先预扫描**：勾选「仅预扫描」跑一遍，只读检查每个文件首 1MB，估算坏道范围
2. 取消预扫描，填好源/目标，点「开始抢救」
3. 观察实时日志、速度、成功/跳过/失败计数；随时可以「停止」
4. 结束后查看目标目录：
   - `disk-rescue-failed.txt`：失败与跳过的清单（时间 | 原因 | 源文件）
   - `*.partial`：被中断文件已读出的部分，可用 `ddrescue` 继续补读

建议：

- 优先选 `/mnt/diskX` 这类裸磁盘路径，避免 `/mnt/user` 的 FUSE 层
- 目标盘预留足够空间；剩余不足 2GB 会被拦下（页面可勾选忽略）
- 抢救过程中不要重启或停止阵列

---

## 常见问题

**装插件时报 `download failure: Network failure`**

`wget` 连不上下载域名。换用[上表的备用入口](#下载失败时换入口)，其中 `ghfast.top` 是纯 IPv4，能绕开 IPv6 不通的问题。

**报 `download failure: zero-length file`**

`.plg` 下好了，但下一个文件拿到 0 字节，通常是 CDN 部署间隙。重试一次；仍不行就换入口。

**报 `Unraid attribute not present`**

这是插件管理器在检查可选的 `max`/`Unraid` 版本上限属性，**不是错误**，可以忽略。

**页面里看不到磁盘 / 选择目录报错**

路径必须在 `/mnt` 下。Docker 部署要确认 `-v /mnt:/mnt` 已挂载。

**复制时提示权限不足 / 无法写入**

插件以 root 运行没有问题；Docker 版容器内也是 root。若挂载了只读卷，检查挂载参数。

**大文件很慢却一直不跳过**

宽限期还没结束（见[参数说明](#参数说明)）。把宽限倍数调到 0 或调小上限。

---

## 项目结构

```
.
├── diskrescue.plg.in                 # 插件清单模板（构建时替换 MD5/URL）
├── build.py / build.sh               # 打包插件（Python / 纯 shell 两种）
├── dist/                             # 构建产物（.txz / .plg / sha256）
├── package/usr/local/emhttp/plugins/diskrescue/
│   ├── DiskRescue.page              # Unraid 页面入口（薄壳）
│   ├── include/page-body.php        # 页面主体（插件与 Docker 共用）
│   ├── include/api.php              # AJAX 接口
│   ├── include/helpers.php          # 路径、状态、配置
│   ├── scripts/disk-rescue.sh       # 核心脚本（也可独立 CLI 使用）
│   ├── css/ · js/ · icons/
├── docker/
│   ├── Dockerfile                   # nginx + php-fpm(-R)
│   ├── entrypoint.sh                # 初始化 /data、可选 Basic 认证
│   ├── nginx.conf · php-fpm-root.conf
│   └── public/                      # 容器入口（index.php / api.php）
├── docker-compose.yml
├── tools/
│   ├── check.py                     # 静态检查 + 功能/行为测试
│   ├── install-local.sh             # 命令行安装/卸载
│   ├── make_icon.py · make_fallback_png.py
│   └── publish.py                   # 通过 GitHub API 发布
└── .github/workflows/docker.yml     # CI：语法检查 → 容器冒烟 → 推送 GHCR
```

---

## 开发与发布

```bash
# 构建插件包（生成 dist/）
python build.py
# 或（Unraid 上无 python 时）
bash build.sh

# 测试：语法 + 功能 + 行为（判卡死 / 不误判 / 停止）
python tools/check.py
PHP=/path/to/php python tools/check.py     # 额外跑 php -l

# 本地构建镜像
docker build -f docker/Dockerfile -t diskrescue:dev .
```

**发布新版本**

1. 改 `build.py` 里的 `VERSION` 与 `diskrescue.plg.in` 的版本号
2. `python build.py --base-url https://blog.kryoo.de/unraid-disk-rescue`
3. 提交 `dist/`，推送到 `main`
4. 打 tag（`v2026.11.12`）→ Actions 自动构建镜像；Pages 约 1 分钟后更新插件

镜像标签：`latest`（默认分支）、分支名、`vX.Y.Z` 及其 `X.Y`。

---

## 设计说明

**为什么不是 `cp`**：`cp` 遇到坏道可能静默截断。这里用 `dd bs=1M conv=fsync`，
坏扇区处报错即停，且能用 `status=progress` 拿到精确的已复制字节数。

**速度判定**：维护 `(秒, 字节)` 样本滑动窗口，丢弃窗口外的旧点，
用 `(当前字节 − 窗口最老字节) ÷ 时间差` 得到窗口平均速度。单个采样点抖动不会误判。

**停止**：`SIGTERM` 后脚本最多等 dd 10 秒，已写数据改名 `*.partial`；
接口只等 5 秒且不轻易 `kill -9`，避免打断收尾丢数据。

**Web 请求不被长任务阻塞**：脚本启动时会关闭从 PHP 继承的多余 fd
（`detach_inherited_fds`），否则浏览器会一直等「开始抢救」的响应直到任务结束。

**容器为什么用 nginx + php-fpm**：Apache 拒绝以 root 运行，而抢救脚本需要 root
读写 `/mnt/diskX`；php-fpm 用 `-R` 以 root 执行，nginx 作前端。

---

## 已知限制

- 只允许 `/mnt` 下的路径（插件与容器都是）
- 不处理符号链接与硬链接（`find -type f` 会跳过链接）
- 预扫描只读每个文件首 1MB，不保证后段完好
- 同一时间只允许一个抢救任务
- 关闭 `conv=fsync` 时，页缓存可能让速度看起来偏高
- 插件依赖 GitHub Pages 自定义域名；改域名后安装地址会变

---

## 许可

[MIT](LICENSE)
