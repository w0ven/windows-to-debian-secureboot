# 工作原理与边界

## 1. 解决的是信任链缺口，不是关掉安全启动

部分 Hyper-V 二代虚拟机只预置 Windows 启动证书。Debian 的微软签名 shim 需要相应的第三方 UEFI CA 才能通过固件验证。

本项目使用 Microsoft `secureboot_objects` 的固定提交、固定 SHA-256 的 `DBUpdate3P2023.bin`。如果 `db` 已有准确匹配的 Microsoft UEFI CA 2023，则不重复追加；否则通过 Windows 受认证变量接口以 append 属性提交官方签名更新。

是否接受更新由固件和现有 KEK 决定。来宾管理员权限不保证能写入。写入失败必须停止，不能改为未签名写入、删除原证书、清空撤销库或关闭安全启动。

写入后检查：目标证书存在、原有信任条目保留、PK/KEK/dbx 未被修改、Secure Boot 仍开启。

这些检查仍不代替实际启动：固件实现、映像撤销和 SBAT 状态可能不同。项目不声称识别所有宿主策略。

## 2. 镜像来源

不是整盘 DD，不使用带预设账户的第三方磁盘镜像。

- 官方 Debian netboot `linux`、`initrd.gz`、`bootnetx64.efi`、`grubx64.efi`；
- 官方 `openssh-server-udeb` 和匹配安装内核的 Hyper-V 存储驱动包；
- Microsoft 官方签名信任库更新。

锁文件中的 Debian 材料最初以 Debian archive keyring 验证 InRelease，再校验安装器清单/udeb 索引及文件摘要。Windows 运行时依据随版本发布的 SHA-256 锁逐个校验，不自行信任上游新文件，也不包含动态关闭校验的开关。

`tools/verify_assets.py` 可在具有 `gpgv` 和 Debian archive keyring 的 Linux 上重新验证当前锁。它不自动批准升级，也不替代真实固件验收。

## 3. Windows 预备阶段

1. 检测 Hyper-V x86-64、UEFI/GPT、Secure Boot、Windows 系统盘、唯一 ESP、现有网络和加密状态。
2. 操作者确认测试或自动清盘模式，隐藏输入密码；本地生成标准 SHA-512 crypt 散列。
3. 下载并核验固定版本文件；将脚本、配置散列、SSH 与存储包组成额外 cpio/gzip 层，追加到官方 initrd。
4. 备份 EFI 文件、导出 BCD，保存原 PK/KEK/db/dbx 与固件启动顺序。BCD 的活动日志不直接复制；BCD 本体用系统导出。
5. 在 ESP 创建独立的 `EFI\w2d` 目录及 netboot GRUB 所需桥接配置。**不覆盖 `EFI\Microsoft`，也不覆盖已有其他 netboot 配置。**
6. 必要时提交微软签名 CA 更新，读回验证。
7. 创建唯一试启动项并设置 `BootNext`，保留原长期 BootOrder；明确安排一次重启。

ESP 空间不足时停止，不自动缩放 Windows 分区。所有敏感运行文件保存在管理员/SYSTEM 专属的工作目录；复制到 ESP 的 initrd 包含密码散列，仍应当作敏感数据处理。

## 4. Linux 试启动阶段

- 尽早启动软件 watchdog；未确认接管时尝试重启。
- 解包固定 SSH 和存储 udebs，按 Windows 网卡 MAC 找到对应接口，设置原 IPv4/网关/DNS。
- 启动 `installer` SSH，登录 shell 是普通 shell，而不是自动开始分区的菜单。
- 安装器 early command 保持暂停，anna 下载入口被门控，未批准前不能通过正常流程获得后续分区器。
- 原 ESP 的 GPT PARTUUID 与物理父盘、确切容量共同确定待清除磁盘，不假设永远是 `/dev/sda`，不默认选择第一块盘。

`--hold` 只表示接管并暂停自动回退；安装授权是另一状态转换。真正放行安装时还必须通过磁盘和网络检查，并可靠停止 watchdog，防止安装过程中被测试计时器重启。

## 5. 自动模式的取舍

自动模式在 Windows 端已经获得针对整块盘的明确清盘确认；Linux 端仍做身份和出站网络检查，但省略再次通过 SSH 的人工确认。

**这意味着它不能在清盘前证明 SSH 入站可达。** 商家安全组、端口映射、防火墙或网络策略均可能导致系统装好后仍连不上。第一次使用某商家必须先试 Test，并准备商家恢复入口。

## 6. 正式系统

Debian 官方安装器建立新的 GPT、ESP、ext4 根分区和 swap，安装 cloud 内核、签名 shim/GRUB、OpenSSH 和安全更新。正式 GRUB 首选 Debian 启动项。

配置静态 IPv4、所选 SSH 端口、root 密码登录及固定接口命名；检查必要配置和启动文件后，让安装器正常结束并重启。系统装好后建议改用自己的 SSH 公钥，再按自身安全要求调整 root/密码登录策略。

## 7. 恢复不等于回滚

- 一次性 BootNext + 保留 Windows 默认引导，只在**尚未清盘**且后续重启真的发生时帮助回到 Windows。
- watchdog 是运行在 Linux 内存中的软件；固件/GRUB/内核在其前面卡死时，它不存在。
- 引导备份不是 Windows 系统或用户数据镜像，也不是带外重启能力。
- Secure Boot 的追加证书更新不自动撤销。删除信任证书可能影响其他签名启动项，不属于取消试启动的动作。
- 一旦正式分区获准，不再承诺回到原 Windows；恢复需使用用户自己的完整备份或商家重装。
