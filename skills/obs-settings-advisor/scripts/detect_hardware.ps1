<#
.SYNOPSIS
    Read-only hardware detection for obs-settings-advisor (Windows).

.DESCRIPTION
    Prints one JSON object to stdout. Writes no files and changes no settings.
    Never prints the user name, computer name, home paths, serial numbers, MAC or IP addresses.
    Every source is optional: failures become null fields plus an entry in "warnings".
    Works with Windows PowerShell 5.1 and PowerShell 7+.

    Exit codes: 0 = JSON printed (check "warnings"), 1 = fatal error.

.EXAMPLE
    powershell -NoProfile -ExecutionPolicy Bypass -File detect_hardware.ps1
#>
[CmdletBinding()]
param()

# Native tools (nvidia-smi) write to stderr; 'Stop' would turn that into terminating errors on 5.1.
$ErrorActionPreference = 'Continue'
# Windows PowerShell 5.1 can serialize arrays as {"value":[...],"Count":n} when this type data is loaded.
Remove-TypeData -TypeName System.Array -ErrorAction SilentlyContinue

$warnings = New-Object System.Collections.Generic.List[string]

function Get-Cim {
    param([string]$Class)
    try {
        return @(Get-CimInstance -ClassName $Class -ErrorAction Stop)
    } catch {
        $warnings.Add("Get-CimInstance $Class failed: $($_.Exception.Message)")
        return @()
    }
}

function Get-RegValue {
    param([string]$Path, [string]$Name)
    try {
        $item = Get-ItemProperty -Path $Path -ErrorAction Stop
        if ($item.PSObject.Properties[$Name]) { return $item.$Name }
    } catch {
        return $null  # key missing or not readable
    }
    return $null
}

function Get-Vendor {
    param([string]$Text)
    $t = $Text.ToLowerInvariant()
    if ($t -match 'nvidia') { return 'NVIDIA' }
    if ($t -match 'advanced micro|\bamd\b|radeon') { return 'AMD' }
    if ($t -match 'intel') { return 'Intel' }
    return 'Unknown'
}

# Returns @(codecs, note). codecs: comma list, '' = no hardware encoder, '?' = unknown.
# Heuristic from the model name only; keep in sync with infer_codecs in detect_hardware.sh.
function Get-CodecGuess {
    param([string]$Vendor, [string]$Model)
    $n = $Model.ToLowerInvariant()
    switch ($Vendor) {
        'NVIDIA' {
            if ($n -match 'gt 1030') { return @('', 'GT 1030 has no NVENC') }
            if ($n -match 'mx\d{3}|gt \d{3}') { return @('?', 'many MX/GT models have no NVENC') }
            if ($n -match 'rtx (50|40)\d\d') { return @('h264,hevc,av1', '') }
            if ($n -match 'rtx (30|20)\d\d|gtx 16\d\d') { return @('h264,hevc', '') }
            if ($n -match 'gtx 10[5-8]0|gtx 9[5-8]0') { return @('h264,hevc', 'older NVENC generation, lower quality per bit than RTX') }
        }
        'AMD' {
            if ($n -match 'rx 6[45]\d\d') { return @('', 'RX 6400/6500 (Navi 24) have no hardware encoder') }
            if ($n -match 'rx [79]\d{3}|radeon [78]\d0m|radeon 8\d\d0s') { return @('h264,hevc,av1', '') }
            if ($n -match 'rx [56]\d{3}|radeon 6\d0m') { return @('h264,hevc', '') }
            if ($n -match 'rx [45]\d0|vega') { return @('h264,hevc', 'older AMD encoder generation') }
        }
        'Intel' {
            if ($n -match '\barc\b') { return @('h264,hevc,av1', '') }
            if ($n -match 'iris(\(r\))? ?xe|uhd graphics|iris(\(r\))? (plus|pro)') { return @('h264,hevc', 'AV1 is decode-only on this iGPU generation') }
            if ($n -match 'hd graphics') { return @('h264', 'older iGPU, HEVC depends on generation') }
        }
    }
    return @('?', 'model not in the built-in table')
}

# NVIDIA's Windows driver version 32.0.15.6614 corresponds to the GeForce version 566.14.
function ConvertTo-NvidiaVersion {
    param([string]$WinVersion)
    $p = $WinVersion.Split('.')
    if ($p.Count -ne 4) { return $null }
    $d = $p[2] + $p[3]
    if ($d.Length -lt 5) { return $null }
    $d = $d.Substring($d.Length - 5)
    return '{0}.{1}' -f $d.Substring(0, 3), $d.Substring(3)
}

function Get-VramMap {
    # Win32_VideoController.AdapterRAM is a uint32 and caps at 4 GB; the registry has the real size.
    $map = @{}
    $base = 'HKLM:\SYSTEM\CurrentControlSet\Control\Class\{4d36e968-e325-11ce-bfc1-08002be10318}'
    foreach ($key in @(Get-ChildItem -Path $base -ErrorAction SilentlyContinue)) {
        if ($key.PSChildName -notmatch '^\d{4}$') { continue }
        $p = Get-ItemProperty -Path $key.PSPath -ErrorAction SilentlyContinue
        if ($null -eq $p) { continue }
        $size = $p.PSObject.Properties['HardwareInformation.qwMemorySize']
        $desc = $p.PSObject.Properties['DriverDesc']
        if ($size -and $desc) {
            try { $map[[string]$desc.Value] = [int64]([double]$size.Value / 1MB) } catch { continue }
        }
    }
    return $map
}

function Main {
    # ---------------------------------------------------------------- OS / machine
    $os = Get-Cim 'Win32_OperatingSystem' | Select-Object -First 1
    $cs = Get-Cim 'Win32_ComputerSystem' | Select-Object -First 1
    $ntKey = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion'

    $model = $null
    $virt = $null
    if ($cs) {
        $model = (('{0} {1}' -f $cs.Manufacturer, $cs.Model).Trim())
        if ($model -match 'To Be Filled|System Product Name|Default string|System manufacturer') { $model = $null }
        if ($cs.Model -match 'Virtual Machine|VMware|VirtualBox|KVM|QEMU|HVM domU|Parallels') {
            $virt = [string]$cs.Model
            $warnings.Add("running in a virtual machine ($virt): results may not describe the user's PC")
        }
    }

    $isLaptop = $false
    if (@(Get-Cim 'Win32_Battery').Count -gt 0) { $isLaptop = $true }
    foreach ($enc in @(Get-Cim 'Win32_SystemEnclosure')) {
        foreach ($t in @($enc.ChassisTypes)) { if (@(8, 9, 10, 14, 31, 32) -contains [int]$t) { $isLaptop = $true } }
    }

    # ---------------------------------------------------------------- CPU / RAM
    $cpus = @(Get-Cim 'Win32_Processor')
    $cpu = [ordered]@{ model = $null; cores = $null; threads = $null; max_mhz = $null }
    if ($cpus.Count -gt 0) {
        $cpu.model = ([string]$cpus[0].Name).Trim()
        $cpu.cores = [int](($cpus | Measure-Object -Property NumberOfCores -Sum).Sum)
        $cpu.threads = [int](($cpus | Measure-Object -Property NumberOfLogicalProcessors -Sum).Sum)
        $cpu.max_mhz = [int]$cpus[0].MaxClockSpeed
    }
    $ramMb = $null
    if ($cs -and $cs.TotalPhysicalMemory) { $ramMb = [int64]([double]$cs.TotalPhysicalMemory / 1MB) }

    # ---------------------------------------------------------------- GPUs and displays
    $smi = @()
    $smiCmd = Get-Command nvidia-smi -ErrorAction SilentlyContinue
    if ($smiCmd) {
        try {
            $smi = @(& $smiCmd.Source --query-gpu=name,driver_version,memory.total --format=csv,noheader,nounits 2>$null |
                Where-Object { $_ -and $_.Trim() })
        } catch { $warnings.Add('nvidia-smi is installed but failed to run') }
    }
    $vram = Get-VramMap
    $sys32 = Join-Path $env:SystemRoot 'System32'

    $gpus = New-Object System.Collections.Generic.List[object]
    $displays = New-Object System.Collections.Generic.List[object]
    $smiIndex = 0
    foreach ($vc in @(Get-Cim 'Win32_VideoController')) {
        $name = ([string]$vc.Name).Trim()
        if ($name -match 'Microsoft Basic Display') {
            $warnings.Add('Microsoft Basic Display Adapter found: the GPU driver is missing, hardware encoding will not work')
        } elseif ($name -match 'Remote Display|Virtual|Indirect|Parsec|IddDriver|Meta Monitor|Hyper-V') {
            continue
        }
        $vendor = Get-Vendor ('{0} {1}' -f $vc.AdapterCompatibility, $name)
        $driver = [string]$vc.DriverVersion
        $vramMb = $null
        if ($vram.ContainsKey($name)) { $vramMb = $vram[$name] }
        elseif ($vc.AdapterRAM) { $vramMb = [int64]([double]$vc.AdapterRAM / 1MB) }

        $api = $null
        $runtime = $null
        switch ($vendor) {
            'NVIDIA' {
                $api = 'NVENC'
                $runtime = Test-Path (Join-Path $sys32 'nvEncodeAPI64.dll')
                $nv = ConvertTo-NvidiaVersion $driver
                if ($smiIndex -lt $smi.Count) {
                    $f = $smi[$smiIndex].Split(',')
                    $smiIndex++
                    $mb = [int64]0
                    if ($f.Count -ge 2) { $nv = $f[1].Trim() }
                    if ($f.Count -ge 3 -and [int64]::TryParse($f[2].Trim(), [ref]$mb)) { $vramMb = $mb }
                }
                if ($nv) { $driver = "$driver (GeForce $nv)" }
            }
            'AMD' { $api = 'AMF'; $runtime = Test-Path (Join-Path $sys32 'amfrt64.dll') }
            'Intel' { $api = 'QSV' }
        }
        $guess = Get-CodecGuess $vendor $name
        $codecs = $null
        if ($guess[0] -ne '?') { $codecs = @($guess[0].Split(',') | Where-Object { $_ }) }
        $note = $guess[1]
        if ($runtime -eq $false) { $note = (@($note, "$api runtime DLL not found in System32: driver problem?") | Where-Object { $_ }) -join '; ' }

        $source = 'inferred_from_model'
        if ($null -eq $codecs) { $source = 'unknown' }
        if (-not $note) { $note = $null }
        $encoder = [ordered]@{
            api             = $api
            codecs          = $codecs
            source          = $source
            runtime_present = $runtime
            note            = $note
        }
        $gpu = [ordered]@{
            vendor     = $vendor
            model      = $name
            driver     = $driver
            vram_mb    = $vramMb
            hw_encoder = $encoder
        }
        $gpus.Add($gpu)
        if ($vc.CurrentHorizontalResolution -and $vc.CurrentVerticalResolution) {
            $refresh = $null
            if ($vc.CurrentRefreshRate -gt 1) { $refresh = [int]$vc.CurrentRefreshRate }  # 0/1 = hardware default
            $display = [ordered]@{
                name       = "display on $name"
                resolution = ('{0}x{1}' -f $vc.CurrentHorizontalResolution, $vc.CurrentVerticalResolution)
                refresh_hz = $refresh
                note       = 'Win32_VideoController reports one active mode per adapter; extra monitors are not listed'
            }
            $displays.Add($display)
        }
    }
    if ($gpus.Count -eq 0) { $warnings.Add('no GPU found via Win32_VideoController; ask the user for the GPU model') }
    if ($displays.Count -eq 0) { $warnings.Add('could not read display resolution/refresh rate; ask the user') }

    # ---------------------------------------------------------------- Windows gaming features
    $hags = Get-RegValue 'HKLM:\SYSTEM\CurrentControlSet\Control\GraphicsDrivers' 'HwSchMode'
    $gameMode = Get-RegValue 'HKCU:\Software\Microsoft\GameBar' 'AutoGameModeEnabled'
    $hagsText = 'unknown'
    if ($hags -eq 2) { $hagsText = 'on' } elseif ($hags -eq 1) { $hagsText = 'off' }
    $gameModeText = 'default (on)'
    if ($gameMode -eq 1) { $gameModeText = 'on' } elseif ($null -ne $gameMode -and $gameMode -eq 0) { $gameModeText = 'off' }
    $gaming = [ordered]@{ hardware_gpu_scheduling = $hagsText; game_mode = $gameModeText }

    # ---------------------------------------------------------------- OBS
    $obs = New-Object System.Collections.Generic.List[object]
    $uninstallRoots = @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*'
    )
    foreach ($root in $uninstallRoots) {
        foreach ($e in @(Get-ItemProperty -Path $root -ErrorAction SilentlyContinue)) {
            if ($e.PSObject.Properties['DisplayName'] -and [string]$e.DisplayName -like 'OBS Studio*') {
                $ver = $null
                if ($e.PSObject.Properties['DisplayVersion']) { $ver = [string]$e.DisplayVersion }
                $entry = [ordered]@{ source = 'installer (registry)'; version = $ver }
                $obs.Add($entry)
            }
        }
    }
    if ($obs.Count -eq 0) {
        $exe = Join-Path $env:ProgramFiles 'obs-studio\bin\64bit\obs64.exe'
        if (Test-Path $exe) {
            $entry = [ordered]@{ source = 'Program Files'; version = [string](Get-Item $exe).VersionInfo.ProductVersion }
            $obs.Add($entry)
        } else {
            $warnings.Add('OBS Studio installation not found (Steam and portable installs are not detected)')
        }
    }

    $osInfo = [ordered]@{ platform = 'windows'; name = $null; version = $null; build = $null; display_version = $null; arch = $null }
    if ($os) {
        $osInfo.name = [string]$os.Caption
        $osInfo.version = [string]$os.Version
        $osInfo.build = [string]$os.BuildNumber
        $osInfo.arch = [string]$os.OSArchitecture
    }
    $osInfo.display_version = Get-RegValue $ntKey 'DisplayVersion'

    # Windows PowerShell 5.1 throws "Argument types do not match" for @(...) values inside [ordered]@{}
    $gpuArray = $gpus.ToArray()
    $displayArray = $displays.ToArray()
    $warningArray = $warnings.ToArray()
    $notes = New-Object 'string[]' 1
    $notes[0] = 'hw_encoder.codecs with source inferred_from_model is a heuristic; the encoder list in an OBS log (analyze_obs_log.py available_video_encoders) is authoritative'
    $obsArray = $obs.ToArray()
    $obsInfo = [ordered]@{ installs = $obsArray }

    $result = [ordered]@{
        schema   = 'obs-settings-advisor/hardware/v1'
        os       = $osInfo
        machine  = [ordered]@{ model = $model; is_laptop = $isLaptop; virtualization = $virt }
        cpu      = $cpu
        memory   = [ordered]@{ total_mb = $ramMb }
        gpus     = $gpuArray
        displays = $displayArray
        windows  = $gaming
        obs      = $obsInfo
        notes    = $notes
        warnings = $warningArray
    }

    $json = $result | ConvertTo-Json -Depth 6
    # last line of defence: no user profile paths in the output
    $json = $json -replace '(?i)([a-z]:\\\\Users\\\\)[^\\"]+', '$1<user>'
    Write-Output $json
}

try {
    Main
    exit 0
} catch {
    [Console]::Error.WriteLine("error: hardware detection failed: $($_.Exception.Message)")
    [Console]::Error.WriteLine($_.InvocationInfo.PositionMessage)
    exit 1
}
