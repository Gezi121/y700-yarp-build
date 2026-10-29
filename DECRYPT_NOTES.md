# C17 / Android 17 解密分析与修复路线

> 结论先行：**C17 解密失败的根因不在 vendor，而在 recovery 侧 vold 的合成密码（synthetic password）路径**。
> twrp-16.0 的 vold 已重做该路径，因此本仓库（twrp-16.0 + v9j SPU 链）即为 C17 解密修复的载体。
> 真正的"A17"（SDK 37 ROM）在社区已有成功先例：用 A16 源码 + A17 内核/vendor blobs 即可解密。

## 1. 证据：C16 与 C17 的 vendor 加密栈逐字节同构

对 `c17_work/base/parts/vendor_a.img`（C17 super 解包）与本地设备树（C16）的 18 个安全栈核心文件做 SHA256 对比：

| 文件 | C16 (ours) | C17 (vendor_a) | 结论 |
|---|---|---|---|
| `bin/spdaemon` | `0FB74E4B8C96…` | `0FB74E4B8C96…` | SAME |
| `bin/sec_nvm` | `C4FEF40E8CE5…` | `C4FEF40E8CE5…` | SAME |
| `bin/qseecomd` | `DC1CCDD0A328…` | `DC1CCDD0A328…` | SAME |
| `bin/hlosminkdaemon` | `EAAD2FC7A2E0…` | `EAAD2FC7A2E0…` | SAME |
| `bin/hw/*keymint-service-qti` | `DC4535BFA171…` | `DC4535BFA171…` | SAME |
| `bin/hw/*keymint-service-spu-qti` | `FED2AFC0A1FE…` | `FED2AFC0A1FE…` | SAME |
| `bin/hw/*weaver-service-spu-qti` | `9F2F789823B9…` | `9F2F789823B9…` | SAME |
| `bin/hw/*gatekeeper-service-qti` | `C66D485FF028…` | `C66D485FF028…` | SAME |
| `bin/hw/*gatekeeper-service-spu-qti` | `D938B12466FD…` | `D938B12466FD…` | SAME |
| `lib64/libspcom.so` | `76719AECE717…` | `76719AECE717…` | SAME |
| `lib64/libqtikeymint.so` | `37F0E317DAB2…` | `37F0E317DAB2…` | SAME |
| `lib64/libspukeymint.so` | `8AD963385267…` | `8AD963385267…` | SAME |
| `lib64/libspukeymintdeviceutils.so` | `61C4C7D22301…` | `61C4C7D22301…` | SAME |
| `lib64/libspukeymintutils.so` | `52BFC18626E0…` | `52BFC18626E0…` | SAME |
| `lib64/libkeymasterdeviceutils.so` | `1A5D66A91DB5…` | `1A5D66A91DB5…` | SAME |
| `lib64/libQSEEComAPI.so` | `AEF2C29FD13F…` | `AEF2C29FD13F…` | SAME |
| `lib64/libmdmdetect.so` | `10FF024A8BDB…` | `10FF024A8BDB…` | SAME |
| `lib64/libprotobuf-cpp-lite-21.12.so` | `AAFAA0D280B9…` | `AAFAA0D280B9…` | SAME |
| `vendor/etc/fstab.qcom` | `0A14501AAEC43BC1…` | `0A14501AAEC43BC1…` | SAME（与 C16 vendor_boot 的 fstab 也逐字节相同）|

vendor rc 的差异仅在服务编排（C17 用 `on init && property:ro.boot.product.vendor.sku=sun` 的
`enable` 模式，我们用显式 `start`），二进制与加密参数完全一致。

⇒ **如果 C16 能解密而 C17 不能，问题必然在 recovery 自己的解密实现里。**

## 2. twrp-16.0 vold 相对橙狐修复了什么

TWRP-Test/android_system_vold `twrp-16.0` tip（`e7e26ed`，"sync Android 16 decryption and
preserve the full Gatekeeper hash"）相对旧代码系的关键提交（与合成密码直接相关的）：

| 提交 | 修复 |
|---|---|
| `6c61e34` | **spblob 文件名补零到 16 位** —— `/data/vendor_de/0/spblob` 命名不匹配会直接找不到 protector |
| `95ce339` | **keystore2 停机期间同步数据库** —— super key 解包走 keystore2 表，不同步拿不到包层密钥 |
| `5221c76`/`c61159a` | keystore2 服务等待超时/放弃逻辑 |
| `fa68b04`/`ab2b028` | **legacy Decrypt_User 路径支持 AIDL GateKeeper**（含等待上限）|
| `0368105`/`4676956` | KeyMint 升级合成密码密钥时的报告/不落盘（避免破坏 ROM 侧状态）|
| `7cb699c` | legacy 路径 UB 修复 |
| `00a0780` | 读 CE 密钥时不 fixate（避免把验证密钥当持久密钥写回）|
| `6ff6526` | 不改写 `/data/unencrypted` key 元数据 |
| `6818b65` | **recovery 永不创建 FBE 密钥**（防止在格式化边缘场景把密钥体系弄脏）|
| `b87aa31` | metadata key 缺失时不清 keystore |
| `e7e26ed` | **完整 64 字节 Gatekeeper hash 传给 HIDL 校验**（32 字节截断会让有效凭据被拒）|
| `fd34740` | 整体与 `android-16.0.0_r1` 解密语义对齐 |

另含社区共享的 `Decrypt.cpp` AES-256-GCM 认证标签修复（ciphertext/tag 切分 + 未初始化 tag +
EVP 返回码检查），四个小米 17 系设备树（antocorvo3000 系列）都带同一补丁；twrp-16.0 主线已含。

## 3. "A17 解密"的真相

- **AOSP 官方 vold `android16-release → android17-release` diff**：`Weaver1.cpp`、
  `HashPassword.cpp`、`Keymaster.cpp` **完全没变**；改动集中在 Checkpoint（OTA）、
  KeyUtil/NVMe（PC）、FsCrypt 小调整。**CE/BE 密钥、合成密码、Weaver/Gatekeeper 契约零变化。**
- **社区实证**（twrp-xiaomi-17-series，HyperOS 4 = SDK 37）：
  Xiaomi 17 (pudding) 与 17 Pro Max (popsicle) 用 **twrp-16.0 源码 + A17 stock 内核 + A17
  vendor blobs** 实现稳定解密。没有任何人在源码层面"适配 A17"。
- ⇒ Y700 的正确路线一致：**recovery 源码保持 twrp-16.0；C17 ROM 上只需保证 vendor blobs
  可用（已核对同构）+ fstab 加密参数一致（已核对逐字节相同）**。

## 4. Y700（QTI SPU weaver）与小米 17 系（NXP/Thales）的差异风险

| 项 | 小米 17 系 | Y700 (sun) | 风险 |
|---|---|---|---|
| Weaver | NXP eSE 或 Thales | QTI SPU (weaver-service-spu-qti) | 低——都是 AIDL `android.hardware.weaver` |
| StrongBox | pandora 依赖 StrongBox + OMAPI 时序 | 无 StrongBox（SPU 即安全域） | **无**（恰好规避了 pandora 的不稳定项）|
| SPU 加载 | 无 SPU 守护链 | `spdaemon`/`sec_nvm` 事件链 | 中——Y700 特有，但 v9j 已真机打通（C16）|
| KeyMint patchlevel | 2099 trick 有效 | 2099 trick 有效（v8/v9j 验证） | 低 |

pandora（NXP Weaver+StrongBox）解密不稳的根因是 StrongBox 时序依赖真 `/vendor` 挂载与
OMAPI 可见性——Y700 走 spdaemon 用户态链（不依赖 ISPUManager），nezha 树"移除 StrongBox、
仅 Weaver+Gatekeeper"的成功思路与 v9j 的"绝不能启动 spu-service"决策互相印证。

## 5. 验证清单（C17 上真机验收）

1. `fastboot boot` 新镜像 → 显示/触摸正常（GUI2/LVGL 渲染链）
2. `getprop twrp.modules.loaded`（若 false，20s 后应出现 `twrp.spu.fallback=true` 且 SPU 链照样起来）
3. `dmesg | grep -iE 'spcom|spss|spdaemon'` 无 fatal；`logcat | grep -E 'pil_called|nvm_ready|spu_ready'` 事件链 SIGNALED
4. 解密：TWRP 日志应出现 `Successfully decrypted metadata encrypted data partition` 与
   `All found users are decrypted`（C16 基准行为）
5. 若 C17 解密仍失败：抓 `/tmp/recovery.log` + `logcat`，重点看
   `spblob` 路径/命名（16 位补零）、keystore2 数据库同步日志、Gatekeeper hash 长度

## 6. 后续：上游 A17 分支出现时

设备树不依赖基线版本（全部资产在 `recovery/root` 覆盖层 + BoardConfig 变量）。
届时只需把 `sources.json` 的 manifest/projects revision 换到 A17 分支重跑同一工作流。
