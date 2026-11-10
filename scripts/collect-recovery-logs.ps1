#Requires -Version 5.1
<#
YARP REC 日志一键采集（只读，不改设备）
------------------------------------
用途：别人刷了 YARP/TWRP 但解不开密时，让他在“设备已进入 REC、USB 连着、
adb 能认到设备”的状态下运行本脚本，把生成的 zip 发回来即可。

用法（Windows PowerShell）：
    powershell -ExecutionPolicy Bypass -File .\collect-recovery-logs.ps1

可选参数：
    -Serial  HA296Z3H            多台设备同时连接时指定
    -OutDir  D:\yarp-logs        输出目录（默认：桌面\yarp-recovery-logs）
    -Adb     E:\platform-tools\adb.exe   指定 adb 路径

脚本做的事：
    1. 定位 adb、确认设备在线，并判断当前是不是 recovery；
    2. 拉取 /tmp/recovery.log、/tmp/fox_spu.log、fox_spu_interfaces 等；
    3. 抓 logcat / dmesg / ps / mounts / getprop / 分区与 dma_heap 权限；
    4. 运行只读的 fox_spu_check，列出缺哪个 AIDL 接口；
    5. 生成 summary.txt（人话结论）+ 打包 zip。

脚本不会：重启、刷写、格式化、改属性、删文件。
#>
[CmdletBinding()]
param(
    [string]$Serial = "",
    [string]$OutDir = "",
    [string]$Adb = ""
)

$ErrorActionPreference = "Continue"
$ProgressPreference = "SilentlyContinue"

function Write-Step($msg)  { Write-Host ("[*] " + $msg) -ForegroundColor Cyan }
function Write-Ok($msg)    { Write-Host ("[+] " + $msg) -ForegroundColor Green }
function Write-Warn2($msg) { Write-Host ("[!] " + $msg) -ForegroundColor Yellow }
function Write-Err2($msg)  { Write-Host ("[x] " + $msg) -ForegroundColor Red }

# ---------- 1. 找 adb ----------
function Resolve-Adb {
    param([string]$Hint)
    $candidates = @()
    if ($Hint) { $candidates += $Hint }
    $candidates += @(
        "E:\platform-tools\adb.exe",
        "$env:LOCALAPPDATA\Android\Sdk\platform-tools\adb.exe",
        "$env:ANDROID_HOME\platform-tools\adb.exe",
        "$env:ANDROID_SDK_ROOT\platform-tools\adb.exe"
    )
    foreach ($c in $candidates) {
        if ($c -and (Test-Path $c)) { return (Resolve-Path $c).Path }
    }
    $cmd = Get-Command adb -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    return $null
}

$adbPath = Resolve-Adb -Hint $Adb
if (-not $adbPath) {
    Write-Err2 "找不到 adb。请安装 platform-tools，或用 -Adb 指定 adb.exe 的完整路径。"
    exit 2
}
Write-Ok ("adb: " + $adbPath)

# ---------- 2. 选设备 ----------
& $adbPath start-server 2>&1 | Out-Null
$deviceLines = @(& $adbPath devices | Select-Object -Skip 1 | Where-Object { $_.Trim() -ne "" })
$online = @()
foreach ($line in $deviceLines) {
    $parts = $line -split "\s+"
    # REC 里 adb 报告的 state 是 "recovery"，不是 "device"，两者都要认。
    if ($parts.Count -ge 2 -and ($parts[1] -eq "device" -or $parts[1] -eq "recovery")) { $online += $parts[0] }
}

if ($online.Count -eq 0) {
    Write-Err2 "没有在线设备。检查："
    Write-Host "    1) 设备已进入 REC（不是停在开机动画/系统）；"
    Write-Host "    2) USB 线接到电脑，REC 里 adb 已可用；"
    Write-Host "    3) 试一次：adb kill-server 然后重新运行本脚本。"
    & $adbPath devices -l
    exit 3
}

if ($Serial) {
    if ($online -notcontains $Serial) {
        Write-Err2 ("指定的 -Serial " + $Serial + " 不在线，当前在线：" + ($online -join ", "))
        exit 3
    }
    $target = $Serial
} elseif ($online.Count -eq 1) {
    $target = $online[0]
} else {
    Write-Err2 ("检测到多台设备：" + ($online -join ", ") + "；请用 -Serial 指定其中一台。")
    exit 3
}
Write-Ok ("设备: " + $target)

# ---------- 3. 输出目录 ----------
if (-not $OutDir) {
    $desktop = [Environment]::GetFolderPath("Desktop")
    if (-not $desktop) { $desktop = $env:USERPROFILE }
    $OutDir = Join-Path $desktop "yarp-recovery-logs"
}
$stamp = Get-Date -Format "yyyyMMdd-HHmmss"
$safeSerial = ($target -replace "[^A-Za-z0-9\.\-]", "_")
$workDir = Join-Path $OutDir ("rec-" + $safeSerial + "-" + $stamp)
New-Item -ItemType Directory -Force -Path $workDir | Out-Null
Write-Ok ("输出目录: " + $workDir)

function Run-Adb {
    param([string[]]$CmdArgs)
    & $adbPath -s $target @CmdArgs 2>&1
}

function Save-Cmd {
    param([string]$Name, [string[]]$CmdArgs)
    $out = Run-Adb -CmdArgs $CmdArgs
    $path = Join-Path $workDir $Name
    ($out | Out-String -Width 400) | Set-Content -Path $path -Encoding UTF8
    return $out
}

function Save-RemoteFile {
    param([string]$Remote, [string]$LocalName)
    $probe = Run-Adb -CmdArgs @("shell", ("test -f '" + $Remote + "' && echo yes || echo no"))
    if (($probe | Out-String).Trim() -notmatch "yes") {
        Write-Warn2 ("设备上不存在: " + $Remote)
        return $false
    }
    $localPath = Join-Path $workDir $LocalName
    $pull = & $adbPath -s $target pull $Remote $localPath 2>&1
    if (Test-Path $localPath) {
        Write-Ok ("已拉取 " + $Remote + " -> " + $LocalName)
        return $true
    }
    Write-Warn2 ("拉取失败: " + $Remote + " / " + ($pull | Out-String).Trim())
    return $false
}

# ---------- 4. 基本信息 ----------
Write-Step "读取设备属性与运行状态"
$propAll = Save-Cmd "getprop-all.txt" @("shell", "getprop")
$get = @{}
foreach ($line in $propAll) {
    if ($line -match '^\[(.+?)\]: \[(.*)\]$') { $get[$Matches[1]] = $Matches[2] }
}
$twrpVersion = $get["ro.twrp.version"]
$model       = $get["ro.product.model"]
$deviceCode  = $get["ro.product.device"]
$uptime      = (Run-Adb -CmdArgs @("shell", "cat /proc/uptime") | Out-String).Trim()
$isRecovery  = [bool]$twrpVersion

Save-Cmd "cmdline.txt"        @("shell", "cat /proc/cmdline")      | Out-Null
Save-Cmd "mounts.txt"         @("shell", "cat /proc/mounts")       | Out-Null
Save-Cmd "date.txt"           @("shell", "date")                   | Out-Null
Save-Cmd "ps.txt"             @("shell", "ps -A -o PID,PPID,STAT,USER,NAME,ARGS") | Out-Null
Save-Cmd "blocks.txt"         @("shell", "ls -l /dev/block/by-name | grep -E 'super|recovery_|boot_|init_boot|modem|persist|spunvm|userdata|misc'") | Out-Null
Save-Cmd "dma-heap.txt"       @("shell", "ls -l /dev/dma_heap")    | Out-Null
Save-Cmd "sp-nodes.txt"       @("shell", "ls -l /dev/spcom /dev/sp_kernel") | Out-Null
Save-Cmd "ramdisk-assets.txt" @("shell", "ls -l /system/bin/fox_spu_bringup.sh /system/bin/fox_crypto_select.sh /system/bin/fox_spu_check /vendor/bin/prepdecrypt.sh") | Out-Null
Save-Cmd "twrp-props.txt"     @("shell", "getprop | grep -E 'twrp\.|ro\.crypto|vendor\.gatekeeper|ro\.boot\.(slot|mode|bootreason)'") | Out-Null

# 只读 AIDL 探针：只查服务是否发布，不调用安全 TA
Save-Cmd "fox-spu-check.txt"  @("shell", "/system/bin/fox_spu_check") | Out-Null

# ---------- 5. 日志 ----------
Write-Step "抓 logcat / dmesg（logcat 有几 MB，稍等）"
Save-Cmd "logcat-all.txt"  @("shell", "logcat -d -b all -v threadtime") | Out-Null
Save-Cmd "dmesg.txt"       @("shell", "dmesg")                          | Out-Null

Write-Step "拉取 REC 内部日志"
$gotRecovery = Save-RemoteFile "/tmp/recovery.log"        "recovery.log"
$gotSpu      = Save-RemoteFile "/tmp/fox_spu.log"         "fox_spu.log"
Save-RemoteFile "/tmp/fox_spu_interfaces"   "fox_spu_interfaces.txt"     | Out-Null
Save-RemoteFile "/tmp/fox_spdaemon.current" "fox_spdaemon.current.txt"   | Out-Null
Save-RemoteFile "/cache/recovery/last_log"  "cache-recovery-last_log.txt"| Out-Null

# pstore（上次若是崩溃/看门狗重启，这里有证据）
$pstore = Run-Adb -CmdArgs @("shell", "ls /sys/fs/pstore")
if (($pstore | Out-String) -match "console|dmesg|pmsg") {
    Write-Step "发现 pstore 记录，一并拉取"
    foreach ($f in @($pstore)) {
        $name = ($f.Trim() -split "/")[-1]
        if ($name) { Save-RemoteFile ("/sys/fs/pstore/" + $name) ("pstore-" + $name + ".txt") | Out-Null }
    }
}

# ---------- 6. 生成 summary.txt ----------
Write-Step "分析并生成 summary.txt"

function Get-FileText {
    param([string]$Name)
    $p = Join-Path $workDir $Name
    if (Test-Path $p) { return (Get-Content $p -Raw -Encoding UTF8) }
    return ""
}

$recoveryText = Get-FileText "recovery.log"
$spuText      = Get-FileText "fox_spu.log"
$checkText    = Get-FileText "fox-spu-check.txt"
$psText       = Get-FileText "ps.txt"
$propsText    = Get-FileText "twrp-props.txt"

$verdict = @()
if (-not $isRecovery) {
    $verdict += "当前连接的不是 REC（ro.twrp.version 为空，可能已经启动到系统）。请在 REC 里重跑。"
}
if (-not $gotRecovery) {
    $verdict += "拿不到 /tmp/recovery.log：REC 可能已重启过（tmpfs 已清空），或这不是本项目的 REC。"
} else {
    $hasFstab    = $recoveryText -match "Processing /etc/recovery\.fstab"
    $doneFstab   = $recoveryText -match "Done processing fstab files"
    $bootHalFix  = $recoveryText -match "No boot control HAL; using the static super partition path"
    $oldWait     = $recoveryText -match "Boot control HAL unavailable, using static super partition path"
    $prep        = $recoveryText -match "Preparing secure storage"
    $metaOk      = $recoveryText -match "Successfully decrypted metadata"
    $ceOk        = $recoveryText -match "All found users are decrypted"
    $decryptPage = $recoveryText -match "Is encrypted, do decrypt page first"
    $metaFail    = $recoveryText -match "Metadata key unlock failed"
    $ceFail      = $recoveryText -match "FBE user key unlock failed"

    if ($bootHalFix) { $verdict += "镜像包含 boot HAL 修复（GetSuperPartition 不再等 vendor boot HAL）。" }
    if ($oldWait)    { $verdict += "镜像是旧版：仍在等 vendor boot HAL，会永久卡住，请先升级到最新 REC。" }
    if ($hasFstab -and -not $doneFstab) {
        $verdict += "启动停在 fstab 处理阶段（没到 Done processing fstab files）。旧镜像=boot HAL 死等；新镜像请看 logcat 里是否仍有 IBootControl 等待。"
    } elseif ($prep -and -not $metaOk) {
        $verdict += "已进入 SPU 准备阶段但 metadata 没解开，重点看 fox_spu.log 的最后阶段与 ERROR 行。"
    } elseif ($metaFail) {
        $verdict += "metadata key 解锁失败：KeyMint/Gatekeeper 身份或 TA 调用失败。"
    } elseif ($ceFail) {
        $verdict += "metadata 已解开但 CE（用户密钥）失败：凭据类型或 Gatekeeper 校验问题。"
    } elseif ($ceOk) {
        $verdict += "日志显示解密成功（All found users are decrypted）。"
    } elseif ($decryptPage) {
        $verdict += "已停在解密页：属于凭据输入/校验流程，不是启动问题。"
    }
}

$spuReady = ""
# getprop 的输出形如 [twrp.spu.ready]: [true]，不是 key=value。
if ($propsText -match "twrp\.spu\.ready[^A-Za-z0-9]+(\w+)") { $spuReady = $Matches[1] }
$reasonLine = ($propsText -split "`r?`n" | Where-Object { $_ -match "twrp\.decrypt\.reason" } | Select-Object -First 1)
$gkLine     = ($propsText -split "`r?`n" | Where-Object { $_ -match "twrp\.crypto\.gatekeeper\.selected" } | Select-Object -First 1)

$spuStages = @()
foreach ($line in ($spuText -split "`r?`n")) {
    if ($line -match "^\[(\d+)s\]") { $spuStages += $line }
}
$spuErrors = @()
foreach ($line in ($spuText -split "`r?`n")) {
    if ($line -match "ERROR:") { $spuErrors += $line }
}
$missingIfaces = @()
foreach ($line in ($checkText -split "`r?`n")) {
    if ($line -match "^missing:\s*(.+)$") { $missingIfaces += $Matches[1].Trim() }
}

$svcNames = @("qseecomd","spdaemon","sec_nvm","hlosminkdaemon","keystore2",
              "keymint-service-qti","keymint-service-spu-qti","gatekeeper-service-qti",
              "gatekeeper-service-spu-qti","weaver-service-spu-qti")
$running = @()
foreach ($n in $svcNames) {
    if ($psText -match [regex]::Escape($n)) { $running += $n }
}
$notRunning = $svcNames | Where-Object { $running -notcontains $_ }

$sb = New-Object System.Text.StringBuilder
[void]$sb.AppendLine("YARP REC 诊断摘要")
[void]$sb.AppendLine("生成时间: " + (Get-Date -Format "yyyy-MM-dd HH:mm:ss"))
[void]$sb.AppendLine("序列号  : " + $target)
[void]$sb.AppendLine("型号    : " + $model + " / " + $deviceCode)
$fullVersion = ""
if ($gotRecovery) {
    $m = [regex]::Match($recoveryText, "Starting TWRP (\S+)")
    if ($m.Success) { $fullVersion = $m.Groups[1].Value }
}
$versionLine = $twrpVersion
if ($fullVersion) { $versionLine = $fullVersion }
[void]$sb.AppendLine("REC 版本: " + $versionLine)
[void]$sb.AppendLine("uptime  : " + $uptime)
[void]$sb.AppendLine("")
[void]$sb.AppendLine("== 结论 ==")
if ($verdict.Count -eq 0) { [void]$sb.AppendLine("未匹配到已知失败特征，请把 zip 发回来人工看。") }
foreach ($v in $verdict) { [void]$sb.AppendLine("- " + $v) }
[void]$sb.AppendLine("")
[void]$sb.AppendLine("== SPU 状态 ==")
[void]$sb.AppendLine("twrp.spu.ready = " + $spuReady)
if ($gkLine)     { [void]$sb.AppendLine($gkLine.Trim()) }
if ($reasonLine) { [void]$sb.AppendLine($reasonLine.Trim()) }
if ($spuStages.Count -gt 0) {
    [void]$sb.AppendLine("fox_spu.log 最后阶段: " + $spuStages[-1])
} elseif (-not $gotSpu) {
    if ($isRecovery) {
        [void]$sb.AppendLine("没有 /tmp/fox_spu.log：SPU 准备从未被请求（更早就失败了）。")
    } else {
        [void]$sb.AppendLine("当前不在 REC，/tmp 不是 REC 的 tmpfs，fox_spu.log 不适用。")
    }
}
if ($spuErrors.Count -gt 0) {
    [void]$sb.AppendLine("fox_spu.log 报错:")
    foreach ($e in $spuErrors) { [void]$sb.AppendLine("  " + $e) }
}
if ($missingIfaces.Count -gt 0) {
    [void]$sb.AppendLine("未发布的 AIDL 服务:")
    foreach ($m in $missingIfaces) { [void]$sb.AppendLine("  " + $m) }
}
[void]$sb.AppendLine("")
[void]$sb.AppendLine("== 安全服务进程 ==")
[void]$sb.AppendLine("在跑: " + (($running | Sort-Object) -join ", "))
[void]$sb.AppendLine("没跑: " + (($notRunning | Sort-Object) -join ", "))
[void]$sb.AppendLine("")
[void]$sb.AppendLine("== recovery.log 最后 30 行 ==")
$tailLines = @()
if ($gotRecovery) {
    $tailLines = (Get-Content (Join-Path $workDir "recovery.log") -Tail 30 -Encoding UTF8)
}
foreach ($l in $tailLines) { [void]$sb.AppendLine($l) }

$summaryPath = Join-Path $workDir "summary.txt"
$sb.ToString() | Set-Content -Path $summaryPath -Encoding UTF8

# ---------- 7. 打包 ----------
$zipPath = Join-Path $OutDir ("yarp-rec-logs-" + $safeSerial + "-" + $stamp + ".zip")
if (Test-Path $zipPath) { Remove-Item $zipPath -Force }
try {
    Compress-Archive -Path (Join-Path $workDir "*") -DestinationPath $zipPath -CompressionLevel Optimal -ErrorAction Stop
    Write-Ok ("已打包: " + $zipPath)
} catch {
    Write-Warn2 ("打包失败（文件仍保留在目录里）: " + $_.Exception.Message)
    $zipPath = "(未打包)"
}

# ---------- 8. 控制台输出 ----------
Write-Host ""
Write-Host "================= 诊断摘要 =================" -ForegroundColor White
Get-Content $summaryPath -Encoding UTF8 | Write-Host
Write-Host "============================================" -ForegroundColor White
Write-Host ""
Write-Ok ("日志目录: " + $workDir)
Write-Ok ("压缩包  : " + $zipPath)
Write-Host "把这个 zip 发回即可（里面只有日志和属性，不含个人数据）。" -ForegroundColor Yellow
