# 开发、验证与后续更新

## 本仓库测试不做什么

测试不会连接 VPS，不修改固件、不写真实分区、不安排重启。原先的定制流程已有一次真实成功安装，但**通用仓库版没有新的 Windows 端到端重装验收**。

Linux 上的 PowerShell 7 可以验证许多纯函数及 C# 数据格式；它不能证明 Windows PowerShell 5.1 的所有平台 API 都能执行。GitHub Actions 中的 Windows 任务也只是无副作用的测试，不是 Hyper-V 固件测试。

## 运行测试

PowerShell：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests\test_windows.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests\test_esp.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests\test_quick.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests\test_crypto.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests\test_boot_state.ps1
```

在安装了 PowerShell 的 Linux 上，把 `powershell.exe` 换为 `pwsh`，使用 `/` 路径。

Linux：

```bash
python3 -I -m unittest discover -s tests -p 'test_*.py' -v
```

根属主配置及可选 chroot 检查需要 root；缺少条件时会明确跳过。`test_contract.py` 还需要 PATH 中的 `pwsh`（或 `W2D_TEST_PWSH` 指定路径），检查真实 Windows 配置生成片段 → cpio → Linux 配置解析的完整交接。CI 的临时 Linux runner 以 sudo 运行这些隔离用例，不访问真实磁盘。

主要覆盖：

- 快捷入口的单次确认、随机密码与散列一致、取消/EOF/非交互拒绝、WhatIf/NoReboot 和旧模式兼容；测试只替换控制台状态与读写提示，不执行固件或分区操作；
- IPv4 地址/掩码/网关验证，拒绝 off-link、stub DNS 和不支持的网络；
- 临时 EFI 挂载无 Storage 盘符时，按原生卷路径核验磁盘/GPT 身份及容量；拒绝错误磁盘、错误分区和非唯一映射；
- EFI LoadOption 的 GPT GUID、扇区几何和设备路径编码；
- EFI signature list 的边界检查和原证书条目保留逻辑；
- 真实脚本片段在内存固件替身下的 BootNext 漂移、编号复用和取消重启回归；
- `newc` cpio 对齐、root-only 配置权限、gzip 追加及拒绝盲目覆盖；
- 标准 SHA-512 crypt 的独立向量及与 OpenSSL 的交叉验证；
- Linux 的配置、磁盘身份、确认/自动分支、下载门控和 watchdog 互斥。

## 重新验证上游固定材料

在已有受信 Debian archive keyring、`gpgv`、Python 3.9+ 的 Linux 上：

```bash
python3 -I tools/verify_assets.py
```

工具从官方源读取 InRelease，以系统 Debian keyring 验证，再核验安装器清单、udeb 索引、锁中的摘要和下载字节。它不修改锁、不发布仓库、不对目标服务器做任何操作。

如果当前 Debian point release 与锁不一致，工具会停止，要求维护者审核升级。微软更新文件使用固定 Git 提交与 SHA-256；最终受认证变量写入仍由目标固件验证。

## 更新锁文件的要求

不得只把报错中的“新哈希”复制进锁文件。

维护者至少需要：

1. 验证新的 Debian InRelease、安装器 SHA256SUMS 和 udeb Packages 索引。
2. 保持 kernel/initrd/存储 udebs 的**完整内核版本一致**，检查 OpenSSH 所需动态库是否仍在原 initrd。
3. 检查 shim 内嵌 Debian CA、GRUB/内核签名、相关 dbx/SBAT 撤销状态以及 netboot GRUB 的配置查找路径。
4. 保留微软 payload 的可审核固定提交和摘要；核实新的签名及适用 KEK，不凭文件名假定兼容。
5. 跑本地测试，并在有控制台、可丢弃的兼容 Windows VPS 上完成 Test → SSH → 安装 → 重启 → root SSH 验收。
6. 只发布新的通用源码/锁/测试证据，不发布测试 VPS 的地址、密码、密钥、固件备份或磁盘镜像。

**首次完整验收不能在已有生产服务器上顺手重装。** 应由机器持有人明确授权可销毁的测试目标，并事先验证恢复入口。
