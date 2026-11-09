# TB322FC / SM8750P 解密启动修复

目标设备是 Y700 四代至尊 TB322FC（sun / elden、SM8750P），不是五代 SM8850。
本轮以 GitHub 设备树 1b08bc5、构建仓库 7322d02 和锁定的上游源码为基线。首版镜像在
TB322FC 实机复现了「启动死在 boot HAL 等待」的阻塞；修复版（run 42630430036）已刷入
recovery_a 并通过两次冷启动验收：不手动干预，约 13 s 完成 SPU 准备并自动解密到主界面。

## 从代码可以确认的原因

1. 旧 SPU 脚本会直接执行 `ctl.restart recovery`，首轮解密失败后重启整个 recovery
   进程再试。这解释界面闪回，也能中断 fastbootd。当前删除此分支。
2. 用户态安全服务从 on-fs、模块属性、20 秒兜底多处启动，可能碰上 TWRP 为读取
   additional.fstab/模块而挂载、卸载真实 vendor。新的启动点在 ProcessFstab 完成
   模块加载、SetupFstabPartitions 完成挂载清理之后的 DecryptData。
3. ueventd 仍将 dma_heap 创建为 0444，启动时 chmod 无法保证稍后创建的节点权限。
   改成 recovery 环境中的 0660 system:system，并修复已有节点。
4. 挂载失败后只检查 persist/secnvm 目录，可将 tmpfs 当成真正 persist。现在检查
   挂载设备和文件系统，只有真实分区就绪后才创建缺少的目录。不格式化分区。
5. 固件回退到 modem_a 会掩盖 B 槽固件错误。只使用当前槽，缺失时明确失败。
6. `init.svc=running` 只代表进程已 fork。新增 fox_spu_check，用 Binder
   checkService 验证 KeyMint 两个实例、Gatekeeper、Weaver、secureclock、sharedsecret、
   keystore2 已发布。它不调用安全 TA、不生成测试密钥。
7. 旧脚本用 logcat -c 清除诊断证据。现在按当前 spdaemon PID 读取所有缓冲区，
   避免上一进程的成功日志被当成此次就绪。
8. GUI2 log_error 的参数是翻译键，不是任意错误文本。改用 write_raw 显示错误。
9. 上游 Decrypt_User 使用 user 0 的 spblob 是否存在来决定所有用户的分支。
   改为检查选中的 user_id，支持不同用户的 legacy/SP 状态差异。


## 实机确认的启动阻塞（20261109 晚）

首版镜像刷入后 UI 停在启动画面，`/tmp/recovery.log` 只有 1.7 KB，最后一行是
`=> Processing /etc/recovery.fstab`；logcat 每秒重复
`Waited one second for android.hardware.boot.IBootControl/default`，init 同时报
`Could not find 'aidl/android.hardware.boot.IBootControl/default' for ctl.interface_start`。

原因是启动路径上的无超时等待：

1. `twrp.cpp` 的 `run_early_startup()` 调 `PartitionManager.ProcessFstab()`。
2. `ProcessFstab()` 的第一行就调用 `GetSuperPartition()`，它用
   `BootControlClient::WaitForService()` 等 `android.hardware.boot.IBootControl/default`。
3. recovery 的 `/system/etc/init/hw/init.rc` 只 import `/init.recovery.*.rc`，不解析
   `/vendor/etc/init`；该 HAL 的 rc 是 `class early_hal`，于是服务从未定义，
   `WaitForService()` 永远等下去。它在 `/vendor` 挂载之前执行，属于循环依赖。
4. 结果是 fstab 未处理、super 未映射、`DecryptData()` 从未被调用——与解密算法无关。

实机验证（HA296Z3H，手动 `setsid /vendor/bin/hw/android.hardware.boot-service.qti &`）：
同一进程立刻继续，`Done processing fstab files` → super 解析为
`/dev/block/bootdevice/by-name/super` → 79 s 请求 SPU 准备、96 s ready（约 17 s）→
metadata 解密成功 → 输入密码后 `/data`（`/dev/block/dm-15`，f2fs）挂载。

修复：`GetSuperPartition()` 不再查询 boot HAL，改用 `ro.boot.super_partition`，
否则用当前槽位后缀并检查 `super<slot>` 是否存在，最后回退到不带后缀的 `super`——
与 `fs_mgr_get_super_partition_name()` 的取名依据一致。`SetActiveSlot()`（用户手动
切 A/B 槽）仍保留 boot HAL 查询，缺该 HAL 时会卡住，属已知遗留，不扩大本次范围。

## 启动顺序

init 提前只挂 firmware，供 remoteproc 加载固件。内核模块加载和真实 vendor 卸载
完成后，DecryptData 请求准备服务：

1. 验证当前槽固件、persist/spunvm、spcom 通道。
2. 选择 Gatekeeper 和 KeyMint 属性环境。
3. qseecomd、minkdaemon、sec_nvm、spdaemon 加载 SP 应用。
4. 启动配套 KeyMint、选定 Gatekeeper、SPU Weaver、keystore2。
5. Binder 接口全部发布后置 ready，原 DecryptData 调用继续 metadata → DE → CE。

等待是事件轮询，上限 180 秒，正常情况在 ready 后立即继续，不固定等满。该上限
不是性能承诺。失败直接显示原因，不重启 recovery、不把未就绪状态送进 TA。
后续手动解密请求可以重试失败的准备；不会因密码错误切换硬件后端。

## 本轮兼容范围

| 情况 | 处理 |
|---|---|
| 四代原厂 SPU Gatekeeper | 默认选择，保留四代配套 SPU KeyMint/Weaver |
| vendor 明确配置 TEE Gatekeeper | 选择随镜像携带的 QTI TEE Gatekeeper，禁止双注册；尚未实机验证 |
| 无密码 / PIN / 图案 / 密码 | 保留上游 vold 凭据识别和验证，不穷举 |
| Weaver protector / Gatekeeper + secdiscardable | 由上游根据当前用户的 protector 文件选择 |
| synthetic password v2/v3 / legacy Gatekeeper | 保留锁定上游的处理；不承诺 v1 或未支持的新格式 |
| user 0 / 其他用户 | vold 按所选 user_id 判定 SP 目录；GUI 用户选择能力另由上游提供 |
| A/B、slot_suffix 缺失但 slot 有效 | 解析当前槽，禁止静默跨槽固件回退 |
| KeyMint 属性差异 | 默认保留已实测的 recovery 未来属性；stock 为显式诊断模式 |
| 固件/模块缺失、persist 错误、AIDL 未发布 | 明确失败，不格式化、不重启、不创建新加密密钥 |

诊断属性：`twrp.crypto.gatekeeper=auto|spu|tee`，
`twrp.keymint.environment=recovery|stock`。这些是开发诊断配置，不是新增 GUI。
不在运行中的 KeyMint 上切换属性，避免缓存和身份不一致。

历史四代实测在 stock 属性下出现 -62 → -38，未来属性下成功；因此不能把“读 ROM
属性”当成全平台自动修复。没有实现自动双属性重试，因为那需要处理 keystore2
生命周期和内存缓存，并证明不会更改密钥状态。

## 参考仓库及适用结论

- [四代同机型 polygraphene](https://github.com/polygraphene/android_device_lenovo_TB322FC/tree/c9c6a9f1287e5b416c3480c5fe06b23dc54c9ab8)：
  同样携带 SPU 栈、persist/spunvm 和 sun 配置；不能仅凭仓库存在认定所有 ROM 已验证。
- [同 SM8750P/sun 的 TB522FU](https://github.com/lanweikayu/android_device_lenovo_TB522FU/tree/2ed9572c0869180d2b48b0b765970233fb8cd481)：
  明确等待 fstab.additional 和 vendor 卸载后才启安全服务；README 声明解密可用。
- [五代 TB323FU](https://github.com/isrgish/TB323FU-TWRP/tree/9ad948cdf1b7c8622873b4a45a898fac175373c5)：
  README 声明 fix3b 已验证解密；故障文档强调精确原厂 SPU KeyMint/Gatekeeper 库，
  不能把旧 Lenovo keymint shim 误认为必要。五代 KeyMint V4 不搬到四代 V3。
- [三代 TB321FU](https://github.com/polygraphene/android_device_lenovo_TB321FU/tree/116684bd39e3c41d64aa4ee976f470954d544807)、
  [二代 TB320FC](https://github.com/polygraphene/android_device_lenovo_TB320FC/tree/ed3c7e7d691f530bc00967f7f8f3a37296ecbadc)、
  [一代 9707F](https://github.com/Barracuda72/android_device_lenovo_9707F/tree/8c4ed3a9553aa1fc1e28109ac942f203f826788a)：
  主要是旧 QSEE/Keymaster 路径，不能替换四代 SPU 链。
- [morannlx 四代树](https://github.com/morannlx/twrp-elden-lenovo/tree/b69b94680590fe8473e36311060a567623a98e75)：
  README 的 Decryption 未勾选，不能把其中不同 Weaver blobs 当成成功参考。
- [小米 SM8750 Thales](https://github.com/YuKongA/twrp_device_xiaomi_sm8750_thales/tree/ba8dc259c86d8287f9260e5f393f0a4cf230f4e7)、
  [YARP SM8850](https://github.com/TWRP-Test/twrp_device_xiaomi_sm8850/tree/8023035649595341e26f9b924928c0b0cd67fbd2)：
  可参考按硬件选择后端和 Binder 接口，不能把 NXP/Thales 硬件替代四代 SPU。

以“无极/wujie”没有找到可核验的对应 REC 源码，未假定其机型或做法。

## 验证

- 18 项 mksh + busybox 隔离 chroot 场景测试通过（没有真实设备、真实分区访问）。
- mksh 语法与 ShellCheck 通过。
- 在锁定上游原文执行完整 patch 阶段，两次运行验证幂等。
- 生成的 DecryptData 在 AArch64 Clang C++23 下通过接口桩语法检查。
- Binder 检查器通过 AArch64 目标编译；完整链接由 Android 构建验证。
- 产物校验新增准备脚本、检查器、错误字符串、LF 行尾、禁止恢复重启/后台清 BCB。

上述离线项之外，下面的 20261109 晚实机验收已经完成。

### 20261109 晚追加

- 补丁脚本对同一段 `GetSuperPartition()` 做锚点替换，锚点失配即构建失败；已用
  pin 的上游原文和已打补丁的树各跑两次，两条路径均为幂等。
- `verify-image.py` 现在同时要求镜像内出现新的静态回退日志、且不再出现被删掉的
  阻塞分支日志。
- `GetSuperPartition()` 是 static 成员，槽位后缀直接读 `ro.boot.slot_suffix`；
- 修正后的版本已由 run 42630430036 重新构建（1h17m，全绿），产物 SHA256
  `4dc7d2ca54e21538ea62bbff2249fab55b929e1c6ce5febb41049d06d46d7562`。

### 实机验收（20261109，TB322FC，刷入 recovery_a）

- 刷写：`dd if=/data/local/tmp/rec.img of=/dev/block/by-name/recovery_a bs=1M`，
  回读分区 SHA256 与产物一致；**不手动启动任何 boot HAL**。
- 版本：`3.7.1_16-TB322FC-8a58fc3b-dirty`，冷启动后 `/tmp/recovery.log`：
  - 37/38 行 `No boot control HAL; using the static super partition path`（新代码路径）
  - 36 行 `=> Processing /etc/recovery.fstab` → 136 行 `Done processing fstab files`（不再卡住）
  - 178 行 `Preparing secure storage; see /tmp/fox_spu.log`
  - 187 行 `Successfully decrypted metadata encrypted data partition ... '/dev/block/mapper/userdata'`
  - 299/300 行 `All found users are decrypted.` / `Data successfully decrypted`
  - 327 行 `Successfully decrypted with default password.`（本机无锁屏密码分支）
- `fox_spu.log`：`[11s] bring-up requested` → `[13s] SPU ready`（准备耗时约 2 秒），
  抓取时 uptime 37.7 s，`/data` 已挂载为 `/dev/block/dm-15`（f2fs），MTP 正常。
- 复现两次（两次冷启动行号与结果一致），不存在 recovery 自重启。
- 未覆盖：有锁屏密码/PIN/图案的 Gatekeeper 校验分支、TEE Gatekeeper 后端、
  `SetActiveSlot()` 手动切槽（仍保留 boot HAL 查询，缺 HAL 会卡，已知遗留）。
