<#
.SYNOPSIS
    Locate OBS Studio log files on Windows (read-only).

.DESCRIPTION
    Prints JSON with the searched locations and the newest 3 log files.
    Paths are printed with %APPDATA% / %USERPROFILE% / %USERNAME% placeholders instead of the
    real user name; analyze_obs_log.py expands them, so a printed path can be passed to it unchanged.
    "has_output_stats" tells whether a log contains a stopped stream/recording (needed for frame stats).
    Works with Windows PowerShell 5.1 and PowerShell 7+.

    Exit codes: 0 = at least one log found, 1 = no logs found or fatal error.

.EXAMPLE
    powershell -NoProfile -ExecutionPolicy Bypass -File find_obs_logs.ps1
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Continue'
Remove-TypeData -TypeName System.Array -ErrorAction SilentlyContinue

function Hide-UserPath {
    param([string]$Path)
    $p = $Path
    if ($env:APPDATA -and $p.StartsWith($env:APPDATA, [StringComparison]::OrdinalIgnoreCase)) {
        $p = '%APPDATA%' + $p.Substring($env:APPDATA.Length)
    } elseif ($env:USERPROFILE -and $p.StartsWith($env:USERPROFILE, [StringComparison]::OrdinalIgnoreCase)) {
        $p = '%USERPROFILE%' + $p.Substring($env:USERPROFILE.Length)
    }
    if ($env:USERNAME -and $env:USERNAME.Length -ge 3) {
        $p = $p -replace ('(?i)\\' + [regex]::Escape($env:USERNAME) + '\\'), '\%USERNAME%\'
    }
    return $p
}

function Test-HasOutputStat {
    param([string]$Path)
    try {
        return [bool](Select-String -Path $Path -Pattern "Output '[^']+': stopping|skipped frames due to encoding lag" -Quiet -ErrorAction Stop)
    } catch {
        return $false  # OBS may hold the current log open; treat as unknown
    }
}

function Main {
    $candidates = New-Object System.Collections.Generic.List[object]
    if ($env:APPDATA) {
        $c = [ordered]@{ type = 'installed'; dir = (Join-Path $env:APPDATA 'obs-studio\logs') }
        $candidates.Add($c)
    }

    # Portable installs keep their config next to the program.
    $roots = @()
    foreach ($key in @('HKLM:\SOFTWARE\OBS Studio', 'HKLM:\SOFTWARE\WOW6432Node\OBS Studio')) {
        try {
            $v = (Get-ItemProperty -Path $key -ErrorAction Stop).'(default)'
            if ($v) { $roots += [string]$v }
        } catch {
            Write-Verbose "no OBS install key at $key"
        }
    }
    foreach ($root in ($roots | Select-Object -Unique)) {
        if ((Test-Path (Join-Path $root 'portable_mode.txt')) -or (Test-Path (Join-Path $root 'obs_portable_mode.txt'))) {
            $c = [ordered]@{ type = 'portable'; dir = (Join-Path $root 'config\obs-studio\logs') }
            $candidates.Add($c)
        }
    }

    $searched = New-Object System.Collections.Generic.List[object]
    $files = New-Object System.Collections.Generic.List[object]
    foreach ($c in $candidates) {
        $exists = Test-Path -LiteralPath $c.dir -PathType Container
        $s = [ordered]@{ install_type = $c.type; path = (Hide-UserPath $c.dir); exists = $exists }
        $searched.Add($s)
        if ($exists) {
            foreach ($f in @(Get-ChildItem -LiteralPath $c.dir -Filter '*.txt' -File -ErrorAction SilentlyContinue)) {
                $item = [pscustomobject]@{ File = $f; Type = $c.type }
                $files.Add($item)
            }
        }
    }

    $sorted = @($files | Sort-Object -Property { $_.File.LastWriteTime } -Descending)
    $logs = New-Object System.Collections.Generic.List[object]
    $newestWithStats = $null
    foreach ($entry in $sorted) {
        $stats = Test-HasOutputStat $entry.File.FullName
        if ($logs.Count -lt 3) {
            $log = [ordered]@{
                path             = (Hide-UserPath $entry.File.FullName)
                install_type     = $entry.Type
                modified         = $entry.File.LastWriteTime.ToString('yyyy-MM-ddTHH:mm:ss')
                size_bytes       = $entry.File.Length
                has_output_stats = $stats
            }
            $logs.Add($log)
        }
        if ($stats -and $null -eq $newestWithStats) { $newestWithStats = Hide-UserPath $entry.File.FullName }
        if ($logs.Count -ge 3 -and $null -ne $newestWithStats) { break }
    }

    # Windows PowerShell 5.1 throws "Argument types do not match" for @(...) values inside [ordered]@{}
    $searchedArray = $searched.ToArray()
    $logArray = $logs.ToArray()
    $result = [ordered]@{
        os                           = 'windows'
        searched                     = $searchedArray
        logs                         = $logArray
        newest_log_with_output_stats = $newestWithStats
    }
    return [pscustomobject]@{ Json = ($result | ConvertTo-Json -Depth 4); Found = $sorted.Count }
}

try {
    $r = Main
    Write-Output $r.Json
    if ($r.Found -eq 0) {
        [Console]::Error.WriteLine('error: no OBS log files found. Start OBS once (Help > Log Files shows the folder) or ask the user for the log.')
        exit 1
    }
    exit 0
} catch {
    [Console]::Error.WriteLine("error: log search failed: $($_.Exception.Message)")
    [Console]::Error.WriteLine($_.InvocationInfo.PositionMessage)
    exit 1
}
