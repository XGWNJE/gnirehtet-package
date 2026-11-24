# gnirehtet 反向 USB 工具包（Windows x64）

离线准备产物，用于「手机通过 USB 借电脑上网（反向 tethering）」。

> 实机前请先运行 `scripts\00_offline_verify.ps1` 与 `scripts\10_env_preflight.ps1` 确认包完整且端口无冲突。
> 完整图文/命令行教程（含 **Windows 7 专项准备** 与 **部分 App 报无网络 / 后台断连排错**）请看 👉 [docs/GUIDE.md](docs/GUIDE.md)。

## 目录结构

```
gnirehtet-package\            ← 绿色包，整个文件夹放哪都能跑
├─ scripts\
│  ├─ build_package.ps1      下载 + 解压 + 合并 adb 三件套，生成 manifest.json
│  ├─ 00_offline_verify.ps1  离线验收：文件、adb version、31416、防火墙、语法、环境
│  ├─ 10_env_preflight.ps1   环境体检；-Fix 交互式关干扰，-Apply 只清本包残留
│  ├─ gnirehtet.ps1          统一入口：体检闸门 → 选设备 → 确认 → 执行
│  ├─ lib\EnvCheck.ps1       检测（进程、端口、PATH、环境变量，只读）
│  ├─ lib\EnvFix.ps1         处置（识别干扰目标、按 PID 关闭、复查）
│  └─ lib\AdbDevices.ps1     设备列表、状态翻译、多设备选择、adb 服务预启动
├─ tools\gnirehtet\          实机工作目录，所有文件同目录
├─ docs\GUIDE.md             详细操作教程（含 Win7 准备与实测排错手册）
├─ download\                 原始压缩包缓存（可删）
├─ logs\                     构建 / 验收 / 体检日志
└─ manifest.json             版本、大小、SHA256 清单
```

## 绿色版说明

- **放哪都能跑**：脚本按自身位置定位包目录，没有写死任何绝对路径。整个文件夹可以随便移动、改名、复制到 U 盘。
- **不写系统**：不写注册表、不改系统环境变量、不加 PATH、不改路由和防火墙。只在本次进程内临时置顶自己的 adb。
- **产物都在包内**：日志写 `logs\`，下载缓存在 `download\`，清单是 `manifest.json`。
- **删掉即卸载**：把文件夹删了就没有残留（除非你自己用 `-Fix` 关过别人的服务，那本来就该由你决定）。

兼容 **PowerShell 7（`pwsh`）** 与 **Windows 自带 PowerShell 5.1（含 Windows 7 SP1 + WMF 5.1）**：全部 `.ps1` 脚本采用 UTF-8 with BOM 编码，并在缺少 Win10/11 新命令时自动降级到 `netstat` / `WMI` / 防火墙 COM / `.NET WebClient`（TLS 1.2）。

## 推荐流程

> Windows 7 或未装 `pwsh` 时，把下面命令中的 `pwsh -NoProfile -File` 替换为 `powershell -NoProfile -ExecutionPolicy Bypass -File` 即可。

```powershell
cd <包目录>                                                  # 例如 D:\tools\gnirehtet-package
pwsh -NoProfile -File scripts\build_package.ps1              # 1. 准备
pwsh -NoProfile -File scripts\00_offline_verify.ps1          # 2. 验收（只读）
pwsh -NoProfile -File scripts\10_env_preflight.ps1           # 3. 体检（只读）
pwsh -NoProfile -File scripts\10_env_preflight.ps1 -Fix      # 4. 处理干扰（逐个确认）
pwsh -NoProfile -File scripts\gnirehtet.ps1 -Action status   # 5. 看设备
pwsh -NoProfile -File scripts\gnirehtet.ps1 -Action run      # 6. 开始
```

## 交互点：只有三处会打断你

| 什么时候 | 会问什么 | 不想被问 |
|---|---|---|
| 环境有冲突 | 要不要关掉干扰项（两次确认） | `-Force` 跳过闸门；`-Answers` 预置回答 |
| 连了多台设备 | 用哪台 | `-Serial <序列号>` |
| 要动手机前（install / run / stop） | 一句话摘要，回车继续 | `-Yes` |
| 只连一台设备 | **不问**，直接用 | — |
| `-Action status` | **不问**，直接执行 | — |

能自动判断的一律不问：端口、PATH、adb 版本、设备数量。

### 多设备选择

```
发现多台可以用的设备，装错机器不好回退，所以问一下：
  [1] Mi 13（a1b2c3d4）
  [2] Pixel 7（z9y8x7w6）
用哪台？输入编号，直接回车用第 1 台：
```

未授权的设备不出现在可选项里；直接回车默认选第 1 台，编号输错或越界则取消本次操作（避免误选）。用 `-Serial` 指定时完全不问。

### 操作确认

```
要给「Mi 13（a1b2c3d4）」开启反向网络吗？
  手机没装客户端时会先自动装好，然后在手机上建一个本地 VPN，把流量转到这台电脑。结束按 Ctrl+C。
  按回车继续，输入 n 取消
```

回车继续，输入 `n` 取消，其它输入也按继续处理（傻瓜化）。`-Yes` 直接跳过。

## 为什么需要“先整理环境”

gnirehtet 自己不碰路由和防火墙，但它**通过 PATH 调用 adb**：

1. 用错 adb：PATH 里先找到谁就用谁，版本不同会导致设备时有时无。
2. 挤掉别人的 adb server：adb 是单 server 架构，端口固定 5037，版本不一致时客户端会杀掉 server 重启，打断别人正在跑的调试。

所以入口做了三件事：体检 + 阻断 + 进程级 PATH 置顶（只影响本次调用）。

### 判定规则

| 情况 | 判定 | 默认处理 | `-Fix` 可关 |
|---|---|---|---|
| 5037 是本包 adb 起的 | 注意 | `-Apply` 可回收 | 是 |
| 5037 是别的工具起的，版本不同 | **阻断** | 只提示 | 是（两次确认） |
| 5037 是别的工具起的，版本相同 | 注意 | 可直接共用 | 可选 |
| 31416 被非 gnirehtet 程序占用 | **阻断** | 只提示 | 是（两次确认） |
| 31416 是 gnirehtet 残留 | 注意 | 只提示 | 是 |
| PATH 先命中别的 adb | 注意 | 只提示 | 不用关，入口自动规避 |
| 存在多份不同路径的 adb | 注意 | 只提示 | 不处理，需人工收拢 |
| 设置了 `ANDROID_SERIAL` | 注意 | 只提示 | 不动环境变量 |

**默认只读**：不带参数不会关任何东西。`-Apply` 只碰本包自己的 adb 服务和下载临时文件。`-Fix` 关闭任何东西都要两步确认，回车/乱输视为“不动”。

## 一个已知坑（已修）

adb 客户端拉起常驻 server 时，会把调用方的句柄表复制给 server。如果脚本输出被管道捕获（如 `| Tee-Object`），管道的写端会被 server 长期持有，脚本跑完了外层还在挂。现在：

- 所有 adb 调用都重定向到临时文件读取，不用管道捕获；
- 查询设备前先用独立方式启动 server（不继承句柄）；
- 结果：`-Action status | Out-String` 实测 6.8 秒正常返回。

## 验收记录

**最近离线验收（Windows 11 x64）**

- 包完整性：PASS / 阻断 0；必需文件齐全，哈希与 manifest 一致；`adb version` 37.0.3；`build_package.ps1` 启用上游 SHA256 与 Google 数字签名校验。
- 31416 空闲；防火墙规则保持原样未改动。
- 7 个脚本语法解析通过。
- 交互处置实测：假占用进程占 31416 → 选 1 + 确认 → 进程关闭、端口释放；同轮 5037 未被触碰。
- 设备逻辑实测（假 adb）：0 台提示、1 台自动选、3 台中排除未授权、编号越界安全取消。
- 端到端实测：隔离端口 5099 上跑 `-Action status`，正常返回“没找到手机”提示，且不影响 5037 上的既有服务。
- 绿色版实测：整包复制到含空格与中文的路径下，体检、验收、入口、`-Action status` 全部正常，日志写在副本自己的 `logs\` 下。

## 待实机验证

1. 插上手机、确认 RSA 指纹后，`-Action status` 能列出设备。
2. `-Action install` 能装上 APK；确认提示里的设备名对得上。
3. `-Action run` 后 31416 正常监听、手机流量确实走 USB。
4. 多设备时选择逻辑在真机上表现一致。
5. 断开/重连 USB 后的恢复行为；是否需要为 31416 加防火墙放行。

## 安全边界

不会自动：改路由、改防火墙、自动连手机、批量结束进程、调用非 `adb.exe` 的未知端口占用程序。关闭干扰必须两步确认（并在关闭前复核进程身份防止 PID 复用）或显式传参；所有改变系统状态的动作都需要人工触发。
