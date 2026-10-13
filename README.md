# Windows → Debian 13（UEFI Secure Boot VPS）

用于这次已成功重装的同类 **Hyper-V 二代 x86-64 Windows VPS**，默认快捷入口直接自动安装 Debian 13，不用手工填写 IP、不用先连测试 SSH。必要时追加微软官方签名的 **Microsoft UEFI CA 2023** 更新，保留 Secure Boot 开启。

**不是万能“解锁脚本”，也不是给磁盘直接写一个 DD 镜像。** 实际走的是微软签名 shim → Debian 签名 GRUB → Debian 签名内核 → Debian 官方安装器。

> **风险：安装会删除 Windows 系统所在整块磁盘的全部分区和数据。没有商家控制台、强制重启或重装入口时，失败可能无法自行恢复。请先把重要数据备份到另一台机器。**
>
> **验证范围：** 本项目依据一次成功的 Windows Server 2022 / Hyper-V UEFI → Debian 13.7 实机安装整理。那次安装保持 Secure Boot 开启，重启和 root SSH 登录通过。**仓库通用版与自动模式尚未在新的、可丢弃的 Windows VPS 上完整清盘重装验收**；本仓库提供本地单元/格式/门控测试，不能把这些测试当作新的整机安装成功证明。快捷模式不等于保证不失联；换了商家或配置不同时，可用下方 Test 流程先验证。

## 同一家机器：粘贴一次，再回车确认

在**要被重装的 Windows VPS 里**，右键以管理员身份打开 **64 位 Windows PowerShell**（Windows 自带 5.1 即可），粘贴这一整行并回车：

```powershell
[Net.ServicePointManager]::SecurityProtocol=[Net.SecurityProtocolType]::Tls12; irm https://raw.githubusercontent.com/w0ven/windows-to-debian-secureboot/main/quick.ps1 | iex
```

脚本会显示识别到的系统盘、网络、SSH 登录命令和 **NEW ROOT PASSWORD（自动生成的 24 位随机密码）**。

**先把密码保存到自己电脑，再按一次回车。** 这次回车就是明确同意清空显示的系统盘、接受失败失联风险并开始安装；输入任意其他文字回车会取消。不要向脚本管道传入回车，不要盲目连按。

接下来自动下载并校验材料、准备启动、重启、安装 Debian 13、再重启。**无需另跑 Check、输入确认长句、重复输入密码，或登录 installer 再授权。** 等待安装完成后，用屏幕显示的 `ssh -p 22 root@你的IP` 和新密码登录；密码不是原 Windows 密码。重装后主机密钥会变化，核对目标后再更新自己客户端的旧记录。

- **会清空 Windows 系统所在整块磁盘。重要数据须提前备份到机器外；商家安全组须允许 TCP 22。** 没有恢复入口时，失败可能无法自行恢复。
- 密码仅在当前窗口显示，不写明文密码文件；不要分享截图或控制台记录。固件/安装阶段使用密码散列。
- 网络参数和目标盘仍自动检测；有歧义、已有安装残留、下载校验失败或不支持的配置仍停止，不靠忽略错误继续。
- 一行入口会在线执行**本仓库**的 `quick.ps1`，下载完整源码到独立临时目录并运行 `Install-Debian.ps1 -Quick`。仅对当前 PowerShell 进程设置执行策略。想先检查源码，按下方步骤下载后手动运行 `./Install-Debian.ps1 -Quick`。
- 报错后不要重复安装或随意重启，保留输出并查看[恢复说明](docs/recovery.md)。

## 适用边界（不是所有“禁 Linux”的商家）

适合的情况是：Windows-only Secure Boot 信任库缺少第三方 UEFI CA，但固件接受微软签名的追加更新。

不能保证解决以下情况：

- 商家禁止来宾写入相关 UEFI 变量，或不接受该微软签名更新；
- PK/KEK、撤销库、SBAT 策略或引导组件版本不兼容；
- 商家在 Secure Boot 之外限制启动文件、虚拟设备或 Linux 运行；
- 特殊网络、特殊存储、ARM64、传统 BIOS、非 Hyper-V 等不支持的环境；
- 商家条款本身禁止 Linux：技术上能启动不等于获得许可。

脚本不会关闭 Secure Boot，不会替换 PK/KEK，不会清空 db/dbx，也不会尝试绕过商家控制面权限。

## 其他用法（按需，不是快捷安装的必做步骤）

| 方式 | 行为 | 推荐对象 |
| --- | --- | --- |
| `-Quick` | 自动生成密码，按一次回车确认后直接自动安装 | 这家已知适用的同类机器，愿意直接重装 |
| `Test` | 一次性启动 Debian；SSH 接管后再次明确确认才清盘 | 新商家/新配置，或想先验证引导与 SSH |
| `AutoInstall` | Windows 中明确确认后；Linux 自检通过即清盘安装 | 已确认适用、已有恢复入口的可丢弃机器 |

自动模式的联网检查**不能证明外部 SSH 入站可达**。如果有商家安全组，请先允许你设置的 SSH 端口。Windows 原 RDP 端口不会自动成为 Debian SSH 端口。

## 可选：先测试再安装（详细步骤）

在**要被重装的 Windows VPS 里面**，以管理员身份打开 **64 位 Windows PowerShell 5.1**。不是在你的日常办公电脑上运行。

### 1. 下载完整仓库

```powershell
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
Invoke-WebRequest -UseBasicParsing `
  https://github.com/w0ven/windows-to-debian-secureboot/archive/refs/heads/main.zip `
  -OutFile "$env:TEMP\w2d.zip"
Expand-Archive "$env:TEMP\w2d.zip" -DestinationPath "$env:USERPROFILE\w2d-source"
Set-Location "$env:USERPROFILE\w2d-source\windows-to-debian-secureboot-main"
Set-ExecutionPolicy -Scope Process Bypass -Force
```

本节是先下载完整源码、阅读后运行的方式，与上方在线快捷入口不同。`ExecutionPolicy` 只在当前 PowerShell 进程内调整。下载目录如果已经存在，请先确认是不是上一次操作，不要直接用覆盖参数盲目覆盖。

### 2. 只检查，不改启动

```powershell
.\Install-Debian.ps1 -Mode Check
```

核对输出的系统盘容量、IPv4、掩码、网关、DNS 和网卡。若本地 DNS 是 `127.0.0.1` 一类 stub，可明确提供 VPS 能访问的真实 IPv4 DNS：

```powershell
.\Install-Debian.ps1 -Mode Check -DnsServers 1.1.1.1,8.8.8.8
```

Check 只做静态前置检查，**不是一次真实启动测试**。

### 3. 进入测试环境

已有商家恢复入口：

```powershell
.\Install-Debian.ps1 -Mode Test -RecoveryAvailable
```

若第 2 步指定了 DNS 或网卡参数，这一步也带相同参数。

脚本会要求输入显示的确认文字，然后以隐藏输入方式设置一个新的 Debian root 密码（16–256 字符，需重复输入）。它也用作本次安装环境的 `installer` 密码。密码只在运行时使用，仓库不保存密码；试启动镜像中存放的是密码散列，不是明文。

默认会安排 15 秒后重启。只想准备、暂不重启可加 `-NoReboot`，但**这时 BootNext 已设置，下一次重启仍会进入所选模式**；取消请看下方恢复说明。

### 4. 从自己的电脑连试启动 SSH

示例地址是文档保留地址，请换成你的 VPS 地址：

```bash
ssh -p 22 installer@192.0.2.100
```

密码是刚才设置的新密码。首次连接请核对目标及可用的主机指纹，不要关闭主机密钥检查来掩盖异常。

先暂停软回退计时器，留出检查时间（**不授权清盘**）：

```sh
/w2d/install-debian.sh --hold
ip -4 addr
ip -4 route
cat /proc/partitions
```

可用 `/w2d/install-debian.sh --status` 查看状态；尚未批准安装时，`/w2d/install-debian.sh --cancel` 会请求重启回 Windows（包括已经 hold 的测试）。

确认目标正确、网络可用，再运行：

```sh
/w2d/install-debian.sh
```

按提示输入针对实际目标磁盘的确认文字。只有此时才会放行清盘。安装过程中不要自行重启、不要重复运行安装命令。首次引导后未明确 hold 或安装时，软回退计时器通常在约 10 分钟后尝试重启回 Windows。

### 5. 安装后登录

```bash
ssh -p 22 root@192.0.2.100
```

密码与第 3 步相同。若用了 `-SshPort 2222`，则两次 SSH 都使用 `-p 2222`。正式系统把选定网卡按 MAC 固定命名为 `w2d0`，不要假定它仍叫 `eth0`。

试启动 SSH 与正式 Debian 会使用不同主机密钥。若客户端提示主机密钥变化，应先核实是这次重装的新密钥；不要把任何主机密钥变化都当作正常并盲目删除记录。

## 已熟悉后：直接自动安装

```powershell
.\Install-Debian.ps1 -Mode AutoInstall -RecoveryAvailable
```

此手动设密码的方式仍要求输入 `AUTO-WIPE DISK <编号>` 和两次新密码。想减少交互，改用 `./Install-Debian.ps1 -Quick`：自动生成密码，把清盘、保存密码和失联风险合并为一次明确提示后的回车确认。两者确认后都自动启动、检查原 ESP 与磁盘大小、配置网络、安装 Debian 并重启，不需再手动连 `installer` 授权。

没有恢复入口但明确接受失联风险时，使用 `-AcceptNoRecovery` **替代** `-RecoveryAvailable`。此参数不会创造任何恢复能力，也不使自动模式变安全。

## 取消试启动 / 失败后回到 Windows

若仍在原 Windows、尚未清盘：

```powershell
.\Restore-WindowsBoot.ps1
```

它先尝试取消已安排的 Windows 重启，再核验并取消本工具自己的 BootNext/测试项，移除哈希匹配的试启动文件，保留备份供检查；不覆盖其他引导项，不删除微软证书更新。若倒计时已开始，建议先立即执行 `shutdown /a`，不要等到最后几秒。

**它不能恢复已被清盘的 Windows。** 卡在固件/GRUB/内核早期时，软件回退计时器可能根本没开始，只能依赖商家控制台/重启/重装。详见 [故障与恢复](docs/recovery.md)。

## 兼容范围和参数

- Windows 管理员、64 位 PowerShell 5.1、Hyper-V 二代 x86-64、UEFI + GPT + Secure Boot 开启；
- 建议 2 GB 或以上内存，系统盘至少 16 GiB；
- 单一可明确识别的 IPv4 默认路由，网关在同一子网；v1 不支持 `/31`、`/32`、额外 on-link 路由、IPv6-only；
- 必须精确识别系统盘上的唯一 ESP，ESP 现有空间足够；不自动缩分区/扩容；
- 不接管已加密的 BitLocker 系统盘，不覆盖已有 `EFI\w2d` 或 `debian-installer`；
- EFI 网络启动文件、磁盘布局和固件策略仍可能不兼容；快捷模式省略独立 Test 阶段，不代表消除了实际启动风险。

| 参数 | 默认值 / 用途 |
| --- | --- |
| `-Mode` | `Check`、`Test`、`AutoInstall`，不带 `-Quick` 时默认 `Check` |
| `-Quick` | 自动安装、随机生成密码，显示目标与风险后回车确认；无需另传恢复声明，仍须接受可能失联的风险 |
| `-InterfaceIndex` | 指定默认路由所在网卡；多网卡时必须明确 |
| `-IPAddress` | 选择该网卡当前已有的 IPv4；不用于更改公网 IP |
| `-PrefixLength`、`-Gateway` | 若指定，必须与当前工作连接相同 |
| `-DnsServers` | 默认当前 Windows IPv4 DNS，可显式替换 |
| `-Hostname` | `debian` |
| `-TimeZone` | `Asia/Shanghai` |
| `-SshPort` | `22`，需自行确认商家安全组开放 |
| `-RecoveryAvailable` | 声明已确认可用的商家恢复入口 |
| `-AcceptNoRecovery` | 明确接受没有恢复入口的风险，与上一项互斥 |
| `-NoReboot` | 仅准备并设置 BootNext，不立即重启 |

[原理与安全边界](docs/design.md) · [故障与恢复](docs/recovery.md) · [Linux 详细流程](docs/linux-flow.md) · [开发测试](docs/testing.md)

## 固定版本下载，不跳过校验

`assets.lock.json` 固定 Debian 13.7 的安装器、SSH/存储安装包以及微软签名更新的 SHA-256。软件来自 Debian/Microsoft 官方域名；**不是从某台服务器复制磁盘镜像，也不下载他人的 root 密码配置**。

准备、恢复期间不要同时运行其他修改固件/启动项的工具或安排系统重启；变量读回检查不是固件级原子锁。

固定版本并不代表永不过期：上游文件下架、撤销策略变化或未来版本更新时，旧版本可能停止工作。遇到下载或校验失败，应等待经过验证的新锁文件/项目版本，**不要删除校验、改成任意镜像或直接换一个未核验内核**。安装后的 Debian 会使用 trixie 软件源和安全更新，内核补丁版本可能高于安装器内核。

## 隐私与许可

本仓库不包含任何实际 VPS 的 IP、密码、私钥、EFI 备份或用户数据。运行时资料位于目标 Windows 的 `%ProgramData%\W2D`，仅管理员和 SYSTEM 可读。它包含密码散列和引导备份，**不要上传到公开 Issue 或仓库**。安装会擦除这份本地目录，需要保留的备份务必提前复制到机器外。

本项目源码使用 MIT 许可。Debian、Microsoft 等下载组件的版权与许可属于原项目。使用前请确认你有权重装该服务器并遵守商家条款。
