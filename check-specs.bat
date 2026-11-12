<# : batch portion
@echo off
setlocal
set "BAT_DIR=%~dp0"
powershell -NoProfile -ExecutionPolicy Bypass -Command "iex (${%~f0} | Out-String)"
echo.
pause
exit /b
#>

# Compares the specs announced in the listing against what Windows reports.
# Run as administrator for the SSD usage line. Unplug external screens and USB drives first.

$ErrorActionPreference = 'SilentlyContinue'
$results = New-Object System.Collections.ArrayList
$lines = New-Object System.Collections.ArrayList

function Say($text, $color = 'Gray') {
    Write-Host $text -ForegroundColor $color
    [void]$lines.Add($text)
}

function Check($name, $expected, $real, $ok) {
    if (-not $real) { $real = 'not found' }
    $status = if ($ok) { 'OK' } else { 'NOT OK' }
    [void]$results.Add([pscustomobject]@{ Name = $name; Ok = [bool]$ok })
    Say ("[{0,-6}] {1,-20} expected: {2}  |  real: {3}" -f $status, $name, $expected, $real) $(if ($ok) { 'Green' } else { 'Red' })
}

Say 'Dell Pro 14 (PC14250) - spec check' 'Cyan'
Say ('Date: ' + (Get-Date -Format 'yyyy-MM-dd HH:mm')) 'Cyan'
Say ''

$pnp = Get-PnpDevice -PresentOnly

# Model
$cs = Get-CimInstance Win32_ComputerSystem
Check 'Model' 'Dell Pro 14 (PC14250)' "$($cs.Manufacturer) $($cs.Model)" ($cs.Manufacturer -match 'Dell' -and $cs.Model -match 'Pro 14|PC14250')

# CPU
$cpu = Get-CimInstance Win32_Processor | Select-Object -First 1
Check 'CPU' 'Intel Core Ultra 7 265U' ("$($cpu.Name)".Trim()) ($cpu.Name -match 'Ultra 7 265U')
Check 'CPU cores' '12' $cpu.NumberOfCores ($cpu.NumberOfCores -eq 12)

$npu = $pnp | Where-Object { $_.FriendlyName -match 'AI Boost|NPU' } | Select-Object -First 1
Check 'NPU' 'Intel AI Boost' $npu.FriendlyName ([bool]$npu)

# RAM
$mem = @(Get-CimInstance Win32_PhysicalMemory)
$memGB = [math]::Round(($mem | Measure-Object Capacity -Sum).Sum / 1GB)
$memType = switch ($mem[0].SMBIOSMemoryType) { 34 { 'DDR5' } 35 { 'LPDDR5' } 26 { 'DDR4' } default { "type code $_" } }
Check 'RAM size' '16 GB' "$memGB GB ($($mem.Count) stick(s), $($mem[0].ConfiguredClockSpeed) MT/s)" ($memGB -eq 16)
Check 'RAM type' 'DDR5' $memType ($memType -eq 'DDR5')

# Storage (largest internal disk)
$disk = Get-PhysicalDisk | Where-Object { $_.BusType -ne 'USB' } | Sort-Object Size -Descending | Select-Object -First 1
$diskGB = [math]::Round($disk.Size / 1e9)
Check 'SSD size' '512 GB' "$diskGB GB ($($disk.FriendlyName))" ($diskGB -ge 480 -and $diskGB -le 530)
Check 'SSD type' 'NVMe (not UFS)' "$($disk.BusType)" ("$($disk.BusType)" -eq 'NVMe')

# Display
$mon = Get-CimInstance -Namespace root\wmi WmiMonitorBasicDisplayParams | Select-Object -First 1
$w = $mon.MaxHorizontalImageSize; $h = $mon.MaxVerticalImageSize
$diag = if ($w) { [math]::Round([math]::Sqrt($w * $w + $h * $h) / 2.54, 1) } else { $null }
Check 'Screen size' '14 inch' $(if ($diag) { "$diag inch" }) ($diag -ge 13.5 -and $diag -le 14.5)

$gpu = Get-CimInstance Win32_VideoController | Select-Object -First 1
$resX = $gpu.CurrentHorizontalResolution; $resY = $gpu.CurrentVerticalResolution
Check 'Screen resolution' 'FHD 1920x1080 (or 1920x1200)' "${resX}x${resY}" ($resX -eq 1920 -and $resY -in 1080, 1200)

# Keyboard (software layout only; check the keys physically too)
Add-Type -AssemblyName System.Windows.Forms
$kb = [System.Windows.Forms.InputLanguage]::CurrentInputLanguage.LayoutName
Check 'Keyboard layout' 'French AZERTY' $kb ($kb -match 'Fran')

# Connectivity
$tb = $pnp | Where-Object { $_.FriendlyName -match 'USB4|Thunderbolt' } | Select-Object -First 1
Check 'Thunderbolt / USB4' 'present' $tb.FriendlyName ([bool]$tb)

$wifi = Get-NetAdapter -Physical | Where-Object { $_.InterfaceDescription -match 'Wi-?Fi|Wireless|802\.11' } | Select-Object -First 1
Check 'Wi-Fi' 'Wi-Fi 6E or newer' $wifi.InterfaceDescription ($wifi.InterfaceDescription -match '6E|Wi-Fi 7|BE2\d\d')

$bt = $pnp | Where-Object { $_.Class -eq 'Bluetooth' } | Select-Object -First 1
Check 'Bluetooth' 'present' $(if ($bt) { 'present' }) ([bool]$bt)

# Options from the listing
$fp = $pnp | Where-Object { $_.Class -eq 'Biometric' } | Select-Object -First 1
Check 'Fingerprint reader' 'present (option)' $fp.FriendlyName ([bool]$fp)

$ir = $pnp | Where-Object { $_.FriendlyName -match 'IR Camera|Infrared' } | Select-Object -First 1
Check 'IR camera' 'present (option)' $ir.FriendlyName ([bool]$ir)

# Windows
$os = Get-CimInstance Win32_OperatingSystem
Check 'Windows edition' 'Windows 11 Pro' $os.Caption ($os.Caption -match 'Windows 11 Pro')

$lic = Get-CimInstance SoftwareLicensingProduct -Filter "Name like 'Windows%' and PartialProductKey is not null" | Select-Object -First 1
Check 'Windows activated' 'licensed' $(if ($lic.LicenseStatus -eq 1) { 'licensed' } else { "status $($lic.LicenseStatus)" }) ($lic.LicenseStatus -eq 1)

$oem = (Get-CimInstance SoftwareLicensingService).OA3xOriginalProductKey
Check 'OEM key in firmware' 'present (license tied to this PC)' $(if ($oem) { 'present' } else { 'none' }) ([bool]$oem)

# Battery health
$design = (Get-CimInstance -Namespace root\wmi BatteryStaticData | Select-Object -First 1).DesignedCapacity
$full = (Get-CimInstance -Namespace root\wmi BatteryFullChargedCapacity | Select-Object -First 1).FullChargedCapacity
$health = if ($design) { [math]::Round(100 * $full / $design) } else { $null }
Check 'Battery health' '80% or more' $(if ($health) { "$health% ($full / $design mWh)" }) ($health -ge 80)

# Summary
$okCount = @($results | Where-Object Ok).Count
$bad = @($results | Where-Object { -not $_.Ok } | ForEach-Object Name)
Say ''
Say '==================== SUMMARY ====================' 'Cyan'
Say "$okCount / $($results.Count) checks OK" $(if ($bad.Count -eq 0) { 'Green' } else { 'Yellow' })
if ($bad.Count) { Say ('NOT OK: ' + ($bad -join ', ')) 'Red' }

# Extra info for judging new vs used
$tag = (Get-CimInstance Win32_BIOS).SerialNumber
Say ''
Say '---------------- Info (not checks) ----------------' 'Cyan'
Say "Service tag: $tag  ->  warranty: https://www.dell.com/support/home/product-support/servicetag/$tag"
Say ('Windows installed on: ' + $os.InstallDate.ToString('yyyy-MM-dd'))
$rel = $disk | Get-StorageReliabilityCounter
if ($rel.PowerOnHours) { Say "SSD power-on hours: $($rel.PowerOnHours)  (a new laptop has only a few)" }
else { Say 'SSD power-on hours: run as administrator to see this' }

Say ''
Say '---------------- Check by hand ----------------' 'Cyan'
Say '- Keyboard backlight turns on, and keys are physically AZERTY'
Say '- HDMI port works with an external screen'
Say '- Charger is USB-C 65 W (label on the brick)'
Say '- Every USB port works'

$report = Join-Path $env:BAT_DIR "specs-report-$env:COMPUTERNAME.txt"
$lines | Set-Content -Path $report -Encoding UTF8
Write-Host ''
Write-Host "Report saved to: $report" -ForegroundColor Cyan
