# diskrescue · 坏盘数据抢救

把健康状态不佳的磁盘上的文件，尽可能完整地复制到另一块健康磁盘。

复制过程中监控**读取速度**，自动跳过卡死的文件；支持断点续跑、失败清单、实时进度，
并提供 Docker 镜像（带 Web 界面）与可直接在命令行运行的脚本。

```
https://github.com/kryo0o/unraid-disk-rescue
```

---

## 快速开始（Docker）

镜像公开，支持 `linux/amd64` / `linux/arm64`：

```bash
docker run -d --name diskrescue --restart unless-stopped \
  -p 8080:80 \
  -v /mnt:/mnt \
  -v /srv/diskrescue:/data \
  ghcr.io/kryo0o/diskrescue:latest
```

打开 `http://<NAS-IP>:8080/`。

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

### 卷与环境变量

| 容器内 | 用途 |
| --- | --- |
| `/mnt` | 要抢救/写入的磁盘，必须挂载 |
| `/data` | 配置、日志、状态 |

| 变量 | 默认 | 说明 |
| --- | --- | --- |
| `TZ` | `Asia/Shanghai` | 日志时区 |
| `DR_USER` / `DR_PASS` | 空 | 设置后启用 HTTP Basic 认证 |
| `DR_DATA_DIR` | `/data` | 配置与日志目录 |
| `DR_CSRF_TOKEN` | 空 | 非空时校验 CSRF，一般不用设 |

> 容器内以 root 运行（否则无法读写 `/mnt/diskX`），页面本身没有登录。
> 请只在可信内网暴露端口，或务必设置 `DR_USER`/`DR_PASS`。

---

## 命令行使用

脚本本身不依赖 Docker，拿到 `app/scripts/disk-rescue.sh` 即可运行（需要 bash、coreutils）。

```bash
# 交互模式
./disk-rescue.sh

# 非交互
./disk-rescue.sh --src /mnt/disk1/xxx --dst /mnt/disk4/xxx --yes

# 关闭速度监控（只靠 dd 报错判断）
./disk-rescue.sh --src ... --dst ... --min-speed 0 --yes

# 不保留未完成文件
./disk-rescue.sh --src ... --dst ... --delete-partial --yes
```

---

## 判卡死逻辑

坏盘最麻烦的不是“读得慢”，而是“卡住不动”。这里的判定分两层：

### 1. 硬卡死（无进度）

**连续 `hang_timeout` 秒（默认 45）没有任何字节增长** → 立即跳过。

- 不看速度阈值，也不受宽限期影响
- 即使 `--min-speed 0` 关闭了速度监控，这一层仍然生效
- 解决“大文件宽限 900 秒，真卡死了却要等 15 分钟”的问题
- 设 `0` 可关闭

### 2. 速度过低（窗口平均）

按**最近 N 秒的平均速度**判定（默认 10 秒 / 10MB/s）：

- 每次采样记录 `(秒, 已复制字节)`，丢掉窗口外的旧样本
- 用 `(当前字节 − 窗口最老字节) ÷ 时间差` 得到窗口平均速度
- 连续 `max_stall` 次低于阈值 → 跳过
- 用窗口平均而不是瞬时速度，避免单点抖动误判

### 3. 宽限期

宽限期内只做硬卡死判定，不做速度判定：

```
宽限 = 倍数 × (文件大小 ÷ 阈值速度)
```

默认 2×，上限 900 秒，小于 4MiB 的文件固定 10 秒。
例如 1GB 文件在 10MB/s 阈值下宽限 200 秒。

**想让 10 秒平均低于阈值就立刻跳过**：把宽限倍数设为 0。

### 4. 读完即停判

一旦已复制字节达到文件大小（dd 正在 `fsync`/关闭），**不再做任何速度或卡死判定**，
避免把“正在落盘”误杀成卡死。

### 跳过之后

| 选项 | 行为 |
| --- | --- |
| 默认 | 已读数据保留为 `文件名.partial`，可用 ddrescue 续读 |
| `--delete-partial` | 直接删除未完成文件，不留 `.partial` |

---

## 参数

| 参数 | 默认 | 说明 |
| --- | --- | --- |
| `--src` / `--dst` | — | 源/目标文件夹，均在 `/mnt` 下 |
| `--min-speed` | 10 | 最低平均速度 MB/s，0 = 关闭 |
| `--speed-window` | 10 | 统计窗口秒数 |
| `--check` | 2 | 采样间隔秒数 |
| `--max-stall` | 1 | 连续几次窗口不达标才跳过 |
| `--hang-timeout` | 45 | 无进度超过多少秒判卡死，0 = 关闭 |
| `--grace-factor` | 2 | 宽限倍数，0 = 不按大小放宽 |
| `--grace-max` | 900 | 宽限上限秒数 |
| `--grace-small` | 10 | 小文件（<4MiB）宽限 |
| `--skip-existing` | 关 | 跳过目标中已存在且大小一致的文件 |
| `--delete-partial` | 关 | 删除未完成文件 |
| `--dry-run` | 关 | 只读预扫描，不复制 |
| `--sync` / `--no-sync` | 开 | `dd conv=fsync` |
| `--force` | 关 | 忽略目标空间不足 2GB 的检查 |

退出码：`0` 全部成功 · `1` 参数/环境错误 · `2` 被中断 · `3` 有文件失败或被跳过。

---

## 使用流程

1. **先预扫描**：勾选「仅预扫描」，只读检查每个文件首 1MB，估算坏道范围
2. 填好源/目标，点「开始抢救」
3. 观察日志、速度、成功/跳过/失败计数；随时可停止
4. 结束后查看目标目录：
   - `disk-rescue-failed.txt`：失败与跳过清单（时间 | 原因 | 源文件）
   - `*.partial`：被中断文件已读出的部分（可关闭该行为）

建议：

- 优先用 `/mnt/diskX` 裸磁盘路径，避免 `/mnt/user` 的 FUSE 层
- 目标盘预留足够空间；剩余不足 2GB 会被拦下
- 抢救过程中不要重启或停止阵列

---

## 常见问题

**页面能打开，但点「开始」没反应**

`diskrescue.js` 依赖 jQuery，容器里由页面按需加载本地副本。
若出现此问题，先强制刷新（`Ctrl+F5`）；仍不行看浏览器 Console 与 `docker logs`。

**提示看不到 `/mnt`**

启动参数缺少 `-v /mnt:/mnt`。

**怎么确认容器环境正常**

```bash
docker exec diskrescue curl -s http://127.0.0.1/api.php?action=doctor
```

`shell_exec`、`data_writable`、`mnt_readable` 都应为 `true`，`bin_*` 不应为 `null`。

**不想保留没拷完的 `.partial`**

页面上勾选「不保留未完成文件」，或命令行加 `--delete-partial`。
清理已有文件：

```bash
find /mnt/disk4/xxx -type f -name '*.partial' -delete
find /mnt/disk4/xxx -type f -name '*.dr-meta.*' -delete
```

**清理没转移成功的目录**

页面右上角「清理空/小目录」，可填大小阈值（默认 10MB）：

- 空目录：直接删除
- 只含未完成文件（`.partial` / `.dr-meta.*`）且总大小 **小于阈值** 的目录：删文件再删目录
- **含正常文件的目录一律不动**（哪怕是几 MB 的小目录）
- 阈值填 `0` = 只删空目录
- 点击后先预览（数量、大小、路径），确认后才真正删除

命令行等价操作：

```bash
# 先删未完成文件，再从深到浅删空目录
find /mnt/disk4/xxx -type f -name '*.partial' -delete
find /mnt/disk4/xxx -depth -type d -empty -delete
```

**大文件很慢却一直不跳过**

宽限期还没结束。把宽限倍数调到 0，或调小上限；
若属于“完全不动”，硬卡死会在 45 秒后触发（可调 `--hang-timeout`）。

---

## 目录结构

```
.
├── app/
│   ├── scripts/disk-rescue.sh     # 核心脚本（可独立 CLI 运行）
│   ├── include/page-body.php      # 页面主体
│   ├── include/api.php            # AJAX 接口（含 doctor / clean_partial）
│   ├── include/helpers.php        # 路径、状态、配置
│   ├── css/ · js/                 # 前端资源（含本地 jQuery）
├── docker/
│   ├── Dockerfile                 # nginx + php-fpm(-R)
│   ├── entrypoint.sh
│   ├── nginx.conf · php-fpm-root.conf
│   └── public/                    # 容器入口 index.php / api.php
├── docker-compose.yml
├── tools/check.py                 # 静态检查 + 功能/行为测试
└── .github/workflows/docker.yml   # CI：lint → 冒烟 → 推送 GHCR
```

---

## 开发与测试

```bash
# 本地构建镜像
docker build -f docker/Dockerfile -t diskrescue:dev .

# 语法 + 功能 + 行为测试（窗口判卡死 / 不误杀 / 停止 / 硬卡死 / 删除）
python tools/check.py
PHP=/path/to/php NODE=/path/to/node python tools/check.py
```

CI 在每次推送时执行：PHP/Shell 语法检查 → 构建镜像并真实跑一次「启动 → 复制 → 完成」
和「清理 .partial」→ 推送 `ghcr.io/kryo0o/diskrescue`。

镜像标签：`latest`（默认分支）、分支名、`vX.Y.Z` 及 `X.Y`。

---

## 已知限制

- 只允许 `/mnt` 下的路径
- 不处理符号链接与硬链接
- 预扫描只读每个文件首 1MB，不保证后段完好
- 同一时间只允许一个任务
- 卡死后**跳过整个文件**，不会自动跳过坏区继续读同一文件（需要 ddrescue 的 trim/retry 能力）

---

## 许可

[MIT](LICENSE)
