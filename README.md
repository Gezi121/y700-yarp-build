# y700-yarp-build

联想拯救者 Y700 四代（TB322FC / elden / SM8750 `sun`）的 **YARP（TWRP-Test twrp-16.0，GUI2/LVGL）** 云端构建仓库。

- 设备树：[Gezi121/android_device_lenovo_TB322FC](https://github.com/Gezi121/android_device_lenovo_TB322FC)
- 解密分析（C17/A17）：见 [DECRYPT_NOTES.md](DECRYPT_NOTES.md)

## 用法

1. Fork/推送到你的 GitHub 账号
2. Actions → **Build YARP TB322FC (ccache)** → Run workflow
3. 首次约 3–6 小时；第二次起 ccache 加速
4. Artifacts 下载 `YARP-TB322FC-recovery.img`（含 AVB testkey 签名 footer，可直接刷 `recovery_a`）

## 内容

```
sources.json                 源码钉版（manifest + recovery/vold/lvgl/libvpx/libwebm 最新 twrp-16.0）
scripts/build-yarp.sh        sync / build / package
scripts/source-lock.py       生成 local_manifest（含设备树 + vold 覆盖）并校验
scripts/verify-image.py      产物静态校验（v4 header / ramdisk-only / YARP 字体 / 100MiB 上限）
scripts/prepare-runner.sh    runner 磁盘清理 + 16G swap
.github/workflows/           build.yml（无缓存）/ build-ccache.yml（推荐）
```

## 钉版策略

vold 单独钉到 `twrp-16.0` tip（`e7e26ed`）——包含合成密码/keystore2/Gatekeeper 全套修复，
这是 Y700 C17 解密修复的核心。其余项目钉 mzsy123/Yarp-macan 验证过的组合。
升级时更新 `sources.json` 对应 revision 即可。

## 免责声明

产物未经真机验证（启动/触摸/解密）。刷 `recovery_a` 前务必备份原厂 recovery，
先 `fastboot boot` 试水，风险自担。
