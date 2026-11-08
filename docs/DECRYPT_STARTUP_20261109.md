# TB322FC / SM8750P 解密启动修复

目标设备是 Y700 四代至尊 TB322FC（sun / elden、SM8750P），不是五代 SM8850。
本轮以 GitHub 设备树 1b08bc5、构建仓库 7322d02 和锁定的上游源码为基线。
没有刷机、没有对设备执行命令。没有群友失败日志，不能断言他们的唯一根因。

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

这些是离线验证，不等于解密速度或群友成功率已实测。
