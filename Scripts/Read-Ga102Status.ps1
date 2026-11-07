# Reads the "Ga102ReBarFixStatus" record published by Ga102ReBarFix. UNTESTED.
# Run in an ELEVATED PowerShell on a UEFI-booted Windows.
Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
public static class Fw {
  [DllImport("kernel32.dll", SetLastError=true, CharSet=CharSet.Unicode)]
  public static extern uint GetFirmwareEnvironmentVariableW(string lpName, string lpGuid, byte[] pBuffer, uint nSize);
  [DllImport("advapi32.dll", SetLastError=true)]
  static extern bool OpenProcessToken(IntPtr h, uint acc, out IntPtr tok);
  [DllImport("advapi32.dll", SetLastError=true, CharSet=CharSet.Unicode)]
  static extern bool LookupPrivilegeValueW(string sys, string name, out long luid);
  [StructLayout(LayoutKind.Sequential, Pack=1)]
  struct TP { public int Count; public long Luid; public int Attr; }
  [DllImport("advapi32.dll", SetLastError=true)]
  static extern bool AdjustTokenPrivileges(IntPtr tok, bool dis, ref TP tp, int len, IntPtr prev, IntPtr ret);
  [DllImport("kernel32.dll")]
  static extern IntPtr GetCurrentProcess();
  public static bool EnablePriv() {
    IntPtr tok;
    if (!OpenProcessToken(GetCurrentProcess(), 0x28, out tok)) return false;
    TP tp = new TP(); tp.Count = 1; tp.Attr = 2;
    if (!LookupPrivilegeValueW(null, "SeSystemEnvironmentPrivilege", out tp.Luid)) return false;
    return AdjustTokenPrivileges(tok, false, ref tp, 0, IntPtr.Zero, IntPtr.Zero);
  }
}
"@

[void][Fw]::EnablePriv()
$buf = New-Object byte[] 64
$n = [Fw]::GetFirmwareEnvironmentVariableW("Ga102ReBarFixStatus", "{2080A345-07AB-4FE9-8E56-1DBB17FA21AE}", $buf, 64)
if ($n -lt 28) {
  $err = [Runtime.InteropServices.Marshal]::GetLastWin32Error()
  Write-Host "No status record (win32 error $err). The module did not run, found no matching GPU, or this is not a UEFI boot."
  exit 1
}
$results = @{0='none';1='RESIZED';2='already at wanted size';3='no Resizable BAR capability found';
             4='wanted size not advertised by the card';5='config access error / write did not stick';6='no BAR1 entry in capability';7='clock guard: system date older than MIN_YEAR, module did nothing'}
$sz = { param($i) if ($i -le 19) { "{0} MiB" -f ([math]::Pow(2,$i)) } else { "?" } }
"Device         : {0:x2}:{1:x2}.{2}" -f $buf[5], $buf[6], $buf[7]
"0x610 before  : 0x{0:X8}" -f [BitConverter]::ToUInt32($buf, 8)
"0x610 after   : 0x{0:X8}" -f [BitConverter]::ToUInt32($buf, 12)
"ReBAR cap @    : 0x{0:X}" -f [BitConverter]::ToUInt32($buf, 16)
"Cap size mask  : 0x{0:X8}" -f [BitConverter]::ToUInt32($buf, 20)
"Size before    : index {0} ({1})" -f $buf[24], (& $sz $buf[24])
"Size wanted    : index {0} ({1})" -f $buf[25], (& $sz $buf[25])
"Size after     : index {0} ({1})" -f $buf[26], (& $sz $buf[26])
"Result         : {0} ({1})" -f $buf[27], $results[[int]$buf[27]]
if ($n -ge 5)  { "Record version  : {0}" -f $buf[4] }
if ($n -ge 29) { "S3 entries     : {0} (S3 boot-script records made; 0 = S3 save-state protocol unavailable or nothing to record)" -f $buf[28] }
if ($n -ge 33) {
  if ($buf[29] -gt 0) { "Upstream bridge: {0:x2}:{1:x2}.{2}  ({3} bridge(s) between the root bus and the GPU)" -f $buf[30], $buf[31], $buf[32], $buf[29] }
  else { "Upstream bridge: none found (GPU on a root bus, or bridge scan failed)" }
  "  v0.5 expected S3 entries = bridges + 2 (e.g. 3 for a GPU directly on a CPU root port)"
}
