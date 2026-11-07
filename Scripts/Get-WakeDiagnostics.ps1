<#
  Get-WakeDiagnostics.ps1  -  gathers what Windows recorded around the last sleep/wake (or failed
  wake) so a resume problem can be narrowed down to: Windows crash, GPU driver failure, or the
  firmware resume path never handing control back to Windows.

  Run in an ELEVATED PowerShell (needed to read crash dumps):
    powershell -ExecutionPolicy Bypass -File .\Get-WakeDiagnostics.ps1
    powershell -ExecutionPolicy Bypass -File .\Get-WakeDiagnostics.ps1 -Hours 48 -RunVramTest

  -Hours        how far back to look (default 24)
  -RunVramTest  also run Test-HostVisibleVram.ps1 if it sits in the same folder
  -Save         also write the output to WakeDiagnostics-<date>.txt next to this script

  Read-only: it only reads event logs, dump headers, device resources and firmware status.
#>
param(
  [int]$Hours = 24,
  [switch]$RunVramTest,
  [switch]$Save
)

$ErrorActionPreference = 'Continue'
$here  = Split-Path -Parent $MyInvocation.MyCommand.Path
$since = (Get-Date).AddHours(-$Hours)
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
             [Security.Principal.WindowsBuiltInRole]::Administrator)
if ($Save) { $log = Join-Path $here ("WakeDiagnostics-{0:yyyyMMdd-HHmmss}.txt" -f (Get-Date)); Start-Transcript -Path $log | Out-Null }

function Section($t) { Write-Host ""; Write-Host ("=" * 78); Write-Host $t; Write-Host ("=" * 78) }

function Get-EvData($e) {
  $h = [ordered]@{}
  try { foreach ($d in ([xml]$e.ToXml()).Event.EventData.Data) { if ($d.Name) { $h[$d.Name] = $d.'#text' } } } catch {}
  return $h
}

$powerStates = @{ '1'='S0 working'; '2'='S1'; '3'='S2'; '4'='S3 sleep'; '5'='S4 hibernate'; '6'='S5 shutdown' }
$bugNames = @{
  0x116='VIDEO_TDR_FAILURE'; 0x117='VIDEO_TDR_TIMEOUT_DETECTED'; 0x141='VIDEO_ENGINE_TIMEOUT_DETECTED'
  0x9F='DRIVER_POWER_STATE_FAILURE'; 0xA0='INTERNAL_POWER_ERROR'; 0x124='WHEA_UNCORRECTABLE_ERROR'
  0x101='CLOCK_WATCHDOG_TIMEOUT'; 0x133='DPC_WATCHDOG_VIOLATION'; 0x1D4='UCMUCSI_LIVEDUMP'
  0xD1='DRIVER_IRQL_NOT_LESS_OR_EQUAL'; 0x50='PAGE_FAULT_IN_NONPAGED_AREA'; 0x3B='SYSTEM_SERVICE_EXCEPTION'
}

Write-Host ("Wake diagnostics  {0}   (looking back {1} h, since {2})" -f (Get-Date), $Hours, $since)
if (-not $isAdmin) { Write-Host "NOTE: not elevated - crash dumps and firmware status will be skipped." }

# ---------------------------------------------------------------------------------------------
Section "1. Sleep states this system supports (powercfg /a)"
powercfg /a

# ---------------------------------------------------------------------------------------------
Section "2. Power, boot, crash and GPU events (System log, oldest first)"
$queries = @(
  @{ P='Microsoft-Windows-Kernel-Power';          Ids=@(41,42,107,109,506,507) },
  @{ P='Microsoft-Windows-Power-Troubleshooter'; Ids=@(1) },
  @{ P='EventLog';                               Ids=@(6008) },
  @{ P='Microsoft-Windows-Kernel-Boot';          Ids=@(27) },
  @{ P='Microsoft-Windows-Kernel-General';       Ids=@(12,13) },
  @{ P='Microsoft-Windows-WER-SystemErrorReporting'; Ids=@(1001) },
  @{ P='Microsoft-Windows-WHEA-Logger';          Ids=$null },
  @{ P='nvlddmkm';                               Ids=$null },
  @{ P='Display';                                Ids=$null }
)
$meaning = @{
  'Kernel-Power/41'='rebooted WITHOUT a clean shutdown (crash, hang, power loss or failed resume)'
  'Kernel-Power/42'='entering sleep'
  'Kernel-Power/107'='resumed from sleep'
  'Kernel-Power/109'='shutdown/restart initiated'
  'Kernel-Power/506'='entering Modern Standby'
  'Kernel-Power/507'='leaving Modern Standby'
  'Power-Troubleshooter/1'='returned from a low-power state (successful wake)'
  'EventLog/6008'='previous shutdown was unexpected'
  'Kernel-Boot/27'='boot type recorded'
  'Kernel-General/12'='operating system started'
  'Kernel-General/13'='operating system shutting down'
  'WER-SystemErrorReporting/1001'='bugcheck (blue screen) recorded'
  'Display/4101'='display driver stopped responding and recovered'
}

$events = @()
foreach ($q in $queries) {
  $f = @{ LogName='System'; ProviderName=$q.P; StartTime=$since }
  if ($q.Ids) { $f.Id = $q.Ids }
  try { $events += Get-WinEvent -FilterHashtable $f -ErrorAction Stop } catch {}
}
$events = $events | Sort-Object TimeCreated

if (-not $events) { Write-Host "No matching events in this window." }
foreach ($e in $events) {
  $short = ($e.ProviderName -replace '^Microsoft-Windows-','')
  $key = "$short/$($e.Id)"
  $what = $meaning[$key]
  if (-not $what) { $what = (($e.Message -split "`r?`n")[0]); if ($what.Length -gt 90) { $what = $what.Substring(0,90) + '...' } }
  Write-Host ("{0:yyyy-MM-dd HH:mm:ss}  {1,-34} {2}" -f $e.TimeCreated, $key, $what)

  $d = Get-EvData $e
  switch ($key) {
    'Kernel-Power/41' {
      $code = [uint64]0; [void][uint64]::TryParse([string]$d['BugcheckCode'], [ref]$code)
      $sip = [string]$d['SleepInProgress']
      Write-Host ("{0,22}BugcheckCode=0x{1:X}  SleepInProgress={2}  PowerButtonTimestamp={3}" -f '', $code, $sip, $d['PowerButtonTimestamp'])
    }
    'Kernel-Power/42' {
      $ts = [string]$d['TargetState']
      Write-Host ("{0,22}TargetState={1} ({2})  Reason={3}" -f '', $ts, $powerStates[$ts], $d['Reason'])
    }
    'Power-Troubleshooter/1' {
      Write-Host ("{0,22}SleepTime={1}  WakeTime={2}  WakeSource={3}" -f '', $d['SleepTime'], $d['WakeTime'], $d['WakeSourceText'])
    }
    'Kernel-Boot/27' {
      $pairs = ($d.GetEnumerator() | ForEach-Object { "$($_.Key)=$($_.Value)" }) -join '  '
      Write-Host ("{0,22}{1}   (0x0 = cold boot, 0x1 = fast startup, 0x2 = resume from hibernate)" -f '', $pairs)
    }
  }
}

# ---------------------------------------------------------------------------------------------
Section "3. Crash dumps written in this window"
$dumpDirs = @("$env:SystemRoot\Minidump", "$env:SystemRoot\LiveKernelReports", "$env:SystemRoot")
$dumps = @()
if ($isAdmin) {
  foreach ($dir in $dumpDirs) {
    if (Test-Path $dir) {
      $rec = ($dir -ne $env:SystemRoot)
      $dumps += Get-ChildItem -Path $dir -Filter *.dmp -Recurse:$rec -ErrorAction SilentlyContinue |
                Where-Object { $_.LastWriteTime -ge $since }
    }
  }
}
if (-not $isAdmin) { Write-Host "Skipped (needs an elevated PowerShell)." }
elseif (-not $dumps) { Write-Host "None." }
foreach ($f in ($dumps | Sort-Object LastWriteTime)) {
  $desc = "unknown dump format"
  try {
    $fs = [IO.File]::OpenRead($f.FullName); $b = New-Object byte[] 0x60; [void]$fs.Read($b, 0, 0x60); $fs.Close()
    if ([Text.Encoding]::ASCII.GetString($b, 0, 8) -eq 'PAGEDU64') {
      $code = [BitConverter]::ToUInt32($b, 0x38)
      $p = 0..3 | ForEach-Object { '0x{0:X}' -f [BitConverter]::ToUInt64($b, 0x40 + 8 * $_) }
      $name = $bugNames[[int]$code]; if (-not $name) { $name = 'see Microsoft bug check reference' }
      $desc = "bugcheck 0x{0:X} {1}  args {2}" -f $code, $name, ($p -join ' ')
    }
  } catch { $desc = "could not read: $($_.Exception.Message)" }
  Write-Host ("{0:yyyy-MM-dd HH:mm:ss}  {1}" -f $f.LastWriteTime, $f.FullName)
  Write-Host ("{0,22}{1}" -f '', $desc)
}

# ---------------------------------------------------------------------------------------------
Section "4. GPU memory ranges right now (should include a 32 GiB range for BAR1)"
try {
  $gpu = Get-CimInstance Win32_PnPEntity | Where-Object { $_.PNPDeviceID -like 'PCI\VEN_10DE&DEV_2206*' } | Select-Object -First 1
  if (-not $gpu) { Write-Host "No 10DE:2206 device found." }
  else {
    Write-Host ("Device : {0}   status {1}  (ConfigManagerErrorCode {2})" -f $gpu.Name, $gpu.Status, $gpu.ConfigManagerErrorCode)
    $ranges = Get-CimAssociatedInstance -InputObject $gpu -ResultClassName Win32_DeviceMemoryAddress -ErrorAction Stop
    if (-not $ranges) { Write-Host "Windows returned no memory ranges here - check Device Manager > Resources instead." }
    foreach ($r in ($ranges | Sort-Object StartingAddress -Unique)) {
      $size = [decimal]$r.EndingAddress - [decimal]$r.StartingAddress + 1
      $txt = if ($size -ge 1GB) { "{0:N0} GiB" -f ($size / 1GB) } else { "{0:N0} MiB" -f ($size / 1MB) }
      Write-Host ("  0x{0:X} - 0x{1:X}   {2}" -f [uint64]$r.StartingAddress, [uint64]$r.EndingAddress, $txt)
    }
  }
  Write-Host "NOTE: this Windows interface can leave out ranges larger than 4 GiB, so a missing 32 GiB range"
  Write-Host "      here is NOT evidence of a problem. Device Manager > Resources is the authoritative view."
} catch { Write-Host "Could not read device resources: $($_.Exception.Message). Check Device Manager > Resources." }

# ---------------------------------------------------------------------------------------------
Section "5. Ga102ReBarFix status (from the last COLD boot - the module does not run on resume)"
$statusScript = Join-Path $here 'Read-Ga102Status.ps1'
if (-not $isAdmin) { Write-Host "Skipped (needs an elevated PowerShell)." }
elseif (Test-Path $statusScript) { & $statusScript }
else { Write-Host "Read-Ga102Status.ps1 not found next to this script; skipped." }

# ---------------------------------------------------------------------------------------------
Section "6. Sleep/wake outcomes in this window"
# A failed wake is identified by Kernel-Power 41 with SleepInProgress <> 0: the machine restarted while a
# sleep transition was in progress. (Kernel-Power 42 is not reliable here: a crashing wake often never
# flushes it, and fast-startup shutdowns also log 42 with target S5.)
$good = $events | Where-Object { $_.ProviderName -eq 'Microsoft-Windows-Power-Troubleshooter' -and $_.Id -eq 1 }
$failed = @()
foreach ($e in ($events | Where-Object { $_.ProviderName -eq 'Microsoft-Windows-Kernel-Power' -and $_.Id -eq 41 })) {
  $d = Get-EvData $e
  if ([string]$d['SleepInProgress'] -and [string]$d['SleepInProgress'] -ne '0') { $failed += $e }
}
foreach ($e in $good) { Write-Host ("{0:yyyy-MM-dd HH:mm:ss}  successful wake" -f $e.TimeCreated) }
foreach ($e in $failed) {
  $d = Get-EvData $e
  $code = [uint64]0; [void][uint64]::TryParse([string]$d['BugcheckCode'], [ref]$code)
  $sip = [string]$d['SleepInProgress']
  $live = $dumps | Where-Object { $_.LastWriteTime -le $e.TimeCreated -and $_.LastWriteTime -ge $e.TimeCreated.AddMinutes(-10) } |
          Sort-Object LastWriteTime | Select-Object -Last 1
  Write-Host ("{0:yyyy-MM-dd HH:mm:ss}  FAILED wake from {1}" -f $e.TimeCreated, $powerStates[$sip])
  if ($code -ne 0) {
    Write-Host ("{0,22}Windows was running again and then bugchecked 0x{1:X}, so the firmware resume itself finished." -f '', $code)
    if ($code -eq 0x116 -or $code -eq 0x141) { Write-Host ("{0,22}0x116/0x141 = the GPU did not respond after waking (display driver timeout)." -f '') }
  } else {
    Write-Host ("{0,22}No bugcheck: Windows never regained control - the reset happened in the firmware resume path." -f '')
  }
  if ($live) { Write-Host ("{0,22}Nearest dump before it: {1}" -f '', $live.Name) }
}
if (-not $good -and -not $failed) { Write-Host "No S3 wake (successful or failed) found in this window. Try a larger -Hours value." }

# ---------------------------------------------------------------------------------------------
if ($RunVramTest) {
  Section "7. CPU-visible VRAM test"
  $t = Join-Path $here 'Test-HostVisibleVram.ps1'
  if (Test-Path $t) { powershell -NoProfile -ExecutionPolicy Bypass -File $t }
  else { Write-Host "Test-HostVisibleVram.ps1 not found next to this script; skipped." }
}

if ($Save) { Stop-Transcript | Out-Null; Write-Host ""; Write-Host "Saved to $log" }
