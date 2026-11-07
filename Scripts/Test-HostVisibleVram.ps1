<#
  Test-HostVisibleVram.ps1  -  measures how much of the GPU's VRAM the CPU can actually map.

  Why: nvidia-smi's BAR1 "Used" figure is useless once BAR1 is large, and there is no public API
  that reports whether the NVIDIA driver runs BAR1 "static" or "dynamic". So instead of reading
  the driver's internal flag, this measures the effect that matters: how much CPU-visible VRAM
  (Vulkan memory type DEVICE_LOCAL | HOST_VISIBLE | HOST_COHERENT) can be allocated, mapped,
  written and read back at the same time.

    - No ReBAR (256 MiB BAR1)      -> the CPU-visible VRAM heap is only ~200-250 MiB.
    - ~10 GiB ceiling              -> matches the static-BAR1 limit measured on Linux for this card.
    - Full CPU access to VRAM      -> keeps going to near the heap size (~19-20 GiB).

  To confirm the memory is in VRAM, run with -HoldSeconds 30 and watch Task Manager > Performance >
  GPU: 'Dedicated GPU memory' should fill while 'Shared GPU memory' stays at zero.

  No admin rights, compilers or SDK needed: it uses vulkan-1.dll, which the NVIDIA driver installs.
  Close games and other GPU-heavy programs first. All memory is freed when the script ends.

  Usage:
    powershell -ExecutionPolicy Bypass -File .\Test-HostVisibleVram.ps1
    powershell -ExecutionPolicy Bypass -File .\Test-HostVisibleVram.ps1 -ChunkMiB 512 -MaxGiB 18

  UNTESTED on hardware. Read-only with respect to firmware and registry.
#>
param(
  [int]$ChunkMiB = 256,     # allocation size per step
  [double]$MaxGiB = 0,      # stop after this much (0 = up to the heap size)
  [int]$HoldSeconds = 0     # keep everything allocated this long at the peak, to check Task Manager
)

$src = @"
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Runtime.InteropServices;

public static class VkBarTest {
  const string L = "vulkan-1.dll";
  [DllImport(L)] static extern int  vkCreateInstance(IntPtr ci, IntPtr a, out IntPtr inst);
  [DllImport(L)] static extern void vkDestroyInstance(IntPtr inst, IntPtr a);
  [DllImport(L)] static extern int  vkEnumeratePhysicalDevices(IntPtr inst, ref uint n, [Out] IntPtr[] d);
  [DllImport(L)] static extern void vkGetPhysicalDeviceProperties(IntPtr pd, IntPtr p);
  [DllImport(L)] static extern void vkGetPhysicalDeviceMemoryProperties(IntPtr pd, IntPtr p);
  [DllImport(L)] static extern int  vkCreateDevice(IntPtr pd, IntPtr ci, IntPtr a, out IntPtr dev);
  [DllImport(L)] static extern void vkDestroyDevice(IntPtr dev, IntPtr a);
  [DllImport(L)] static extern int  vkAllocateMemory(IntPtr dev, IntPtr ai, IntPtr a, out ulong mem);
  [DllImport(L)] static extern void vkFreeMemory(IntPtr dev, ulong mem, IntPtr a);
  [DllImport(L)] static extern int  vkMapMemory(IntPtr dev, ulong mem, ulong off, ulong size, uint flags, out IntPtr p);
  [DllImport(L)] static extern void vkUnmapMemory(IntPtr dev, ulong mem);

  const uint DEVICE_LOCAL = 1, HOST_VISIBLE = 2, HOST_COHERENT = 4, HOST_CACHED = 8;
  const long MiB = 1L << 20;

  static IntPtr Z(int n) {
    IntPtr p = Marshal.AllocHGlobal(n);
    for (int i = 0; i < n; i++) Marshal.WriteByte(p, i, 0);
    return p;
  }

  static string R(int r) {
    switch (r) {
      case 0: return "VK_SUCCESS";
      case -1: return "VK_ERROR_OUT_OF_HOST_MEMORY";
      case -2: return "VK_ERROR_OUT_OF_DEVICE_MEMORY";
      case -3: return "VK_ERROR_INITIALIZATION_FAILED";
      case -4: return "VK_ERROR_DEVICE_LOST";
      case -5: return "VK_ERROR_MEMORY_MAP_FAILED";
      case -9: return "VK_ERROR_INCOMPATIBLE_DRIVER";
      default: return "VkResult " + r;
    }
  }

  static string Flags(uint f) {
    string s = "";
    if ((f & DEVICE_LOCAL) != 0) s += "DEVICE_LOCAL ";
    if ((f & HOST_VISIBLE) != 0) s += "HOST_VISIBLE ";
    if ((f & HOST_COHERENT) != 0) s += "HOST_COHERENT ";
    if ((f & HOST_CACHED) != 0) s += "HOST_CACHED ";
    return s.Length == 0 ? "-" : s.Trim();
  }

  static double G(long b) { return b / (double)(1L << 30); }

  public static void Run(int chunkMiB, double maxGiB, int holdSeconds) {
    IntPtr inst;
    IntPtr app = Z(48);
    Marshal.WriteInt32(app, 0, 0);                                         // VK_STRUCTURE_TYPE_APPLICATION_INFO
    Marshal.WriteIntPtr(app, 16, Marshal.StringToHGlobalAnsi("Ga102BarTest"));
    Marshal.WriteInt32(app, 44, 1 << 22);                                  // apiVersion 1.0
    IntPtr ici = Z(64);
    Marshal.WriteInt32(ici, 0, 1);                                         // VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO
    Marshal.WriteIntPtr(ici, 24, app);
    int r = vkCreateInstance(ici, IntPtr.Zero, out inst);
    if (r != 0) { Console.WriteLine("vkCreateInstance failed: " + R(r)); return; }

    uint n = 0;
    vkEnumeratePhysicalDevices(inst, ref n, null);
    IntPtr[] pds = new IntPtr[n];
    vkEnumeratePhysicalDevices(inst, ref n, pds);

    IntPtr pd = IntPtr.Zero;
    IntPtr props = Z(4096);
    foreach (IntPtr d in pds) {
      vkGetPhysicalDeviceProperties(d, props);
      uint vendor = (uint)Marshal.ReadInt32(props, 8);
      if (vendor == 0x10DE) {
        pd = d;
        uint drv = (uint)Marshal.ReadInt32(props, 4);
        Console.WriteLine(string.Format("GPU     : {0}  (10DE:{1:X4})  driver {2}.{3:D2}",
          Marshal.PtrToStringAnsi(new IntPtr(props.ToInt64() + 20)),
          Marshal.ReadInt32(props, 12), drv >> 22, (drv >> 14) & 0xFF));
        break;
      }
    }
    if (pd == IntPtr.Zero) { Console.WriteLine("No NVIDIA GPU found through Vulkan."); vkDestroyInstance(inst, IntPtr.Zero); return; }

    // VkPhysicalDeviceMemoryProperties: count@0, types[32]{flags,heap}@4, heapCount@260, heaps[16]{size,flags,pad}@264
    IntPtr mp = Z(1024);
    vkGetPhysicalDeviceMemoryProperties(pd, mp);
    int typeCount = Marshal.ReadInt32(mp, 0);
    int heapCount = Marshal.ReadInt32(mp, 260);
    Console.WriteLine();
    Console.WriteLine("Memory heaps:");
    for (int h = 0; h < heapCount; h++)
      Console.WriteLine(string.Format("  heap {0}: {1,8:F2} GiB  {2}", h, G(Marshal.ReadInt64(mp, 264 + 16 * h)),
        (Marshal.ReadInt32(mp, 272 + 16 * h) & 1) != 0 ? "DEVICE_LOCAL (VRAM)" : "system RAM"));
    Console.WriteLine("Memory types:");
    int pick = -1; long pickHeap = 0;
    for (int t = 0; t < typeCount; t++) {
      uint f = (uint)Marshal.ReadInt32(mp, 4 + 8 * t);
      int h = Marshal.ReadInt32(mp, 8 + 8 * t);
      long hs = Marshal.ReadInt64(mp, 264 + 16 * h);
      Console.WriteLine(string.Format("  type {0,2}: heap {1}  {2}", t, h, Flags(f)));
      uint want = DEVICE_LOCAL | HOST_VISIBLE | HOST_COHERENT;
      if ((f & want) == want && hs > pickHeap) { pick = t; pickHeap = hs; }
    }
    Console.WriteLine();
    if (pick < 0) {
      Console.WriteLine("RESULT: no DEVICE_LOCAL + HOST_VISIBLE memory type. The driver is not exposing VRAM to the CPU (ReBAR inactive).");
      vkDestroyInstance(inst, IntPtr.Zero); return;
    }
    Console.WriteLine(string.Format("CPU-visible VRAM type {0} lives in a {1:F2} GiB heap.", pick, G(pickHeap)));
    if (pickHeap < 1024 * MiB)
      Console.WriteLine("  -> That heap is small: the driver is treating BAR1 as a small (non-ReBAR) window.");
    else
      Console.WriteLine("  -> That heap is the whole VRAM: the driver advertises full CPU access (ReBAR active).");

    // Device with one queue from family 0 (needed only to allocate memory).
    IntPtr prio = Marshal.AllocHGlobal(4);
    Marshal.Copy(new float[] { 1.0f }, 0, prio, 1);
    IntPtr qci = Z(40);
    Marshal.WriteInt32(qci, 0, 2);       // VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO
    Marshal.WriteInt32(qci, 20, 0);      // queueFamilyIndex
    Marshal.WriteInt32(qci, 24, 1);      // queueCount
    Marshal.WriteIntPtr(qci, 32, prio);
    IntPtr dci = Z(72);
    Marshal.WriteInt32(dci, 0, 3);       // VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO
    Marshal.WriteInt32(dci, 20, 1);
    Marshal.WriteIntPtr(dci, 24, qci);
    IntPtr dev;
    r = vkCreateDevice(pd, dci, IntPtr.Zero, out dev);
    if (r != 0) { Console.WriteLine("vkCreateDevice failed: " + R(r)); vkDestroyInstance(inst, IntPtr.Zero); return; }

    Console.WriteLine();

    long chunk = chunkMiB * MiB;
    long cap = pickHeap;
    if (maxGiB > 0 && (long)(maxGiB * 1024) * MiB < cap) cap = (long)(maxGiB * 1024) * MiB;
    Console.WriteLine(string.Format("Allocating, mapping and verifying {0} MiB chunks, up to {1:F2} GiB ...", chunkMiB, G(cap)));
    Console.WriteLine();

    List<ulong> mems = new List<ulong>();
    IntPtr ai = Z(32);
    long total = 0; int bad = 0; string stop = "reached the cap";
    while (total + chunk <= cap) {
      Marshal.WriteInt32(ai, 0, 5);                // VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO
      Marshal.WriteInt64(ai, 16, chunk);
      Marshal.WriteInt32(ai, 24, pick);
      ulong mem;
      r = vkAllocateMemory(dev, ai, IntPtr.Zero, out mem);
      if (r != 0) { stop = "vkAllocateMemory returned " + R(r); break; }
      IntPtr p;
      r = vkMapMemory(dev, mem, 0, ulong.MaxValue, 0, out p);
      if (r != 0) { stop = "vkMapMemory returned " + R(r); vkFreeMemory(dev, mem, IntPtr.Zero); break; }
      mems.Add(mem);                               // keep it allocated AND mapped

      int idx = mems.Count;
      long b = p.ToInt64();
      for (long off = 0; off < chunk; off += MiB)
        Marshal.WriteInt32(new IntPtr(b + off), (int)(0x5A000000 ^ (idx << 12) ^ (off >> 20)));
      Marshal.WriteInt32(new IntPtr(b + chunk - 4), 0x0DDBA11 ^ idx);

      for (long off = 0; off < chunk; off += MiB)
        if (Marshal.ReadInt32(new IntPtr(b + off)) != (int)(0x5A000000 ^ (idx << 12) ^ (off >> 20))) bad++;
      if (Marshal.ReadInt32(new IntPtr(b + chunk - 4)) != (0x0DDBA11 ^ idx)) bad++;

      total += chunk;
      if ((total % (1L << 30)) == 0 || total + chunk > cap)
        Console.WriteLine(string.Format("  {0,6:F2} GiB mapped and verified", G(total)));
    }

    Console.WriteLine();
    Console.WriteLine(string.Format("Stopped     : {0}", stop));
    Console.WriteLine(string.Format("Mapped      : {0:F2} GiB of CPU-visible VRAM held mapped at once", G(total)));
    Console.WriteLine(string.Format("Verify      : {0}", bad == 0 ? "all writes read back correctly" : bad + " MISMATCHES"));
    if (G(total) >= 16)
      Console.WriteLine("RESULT      : the CPU can map nearly all VRAM. No ~10 GiB static-BAR1 ceiling.");
    else if (G(total) >= 8)
      Console.WriteLine("RESULT      : stopped near the ~10 GiB static-BAR1 ceiling measured on Linux for this card.");
    else
      Console.WriteLine("RESULT      : stopped early. Close other GPU programs and run again before drawing conclusions.");

    if (holdSeconds > 0) {
      Console.WriteLine();
      Console.WriteLine(string.Format("Holding all {0:F2} GiB for {1} s. Look at Task Manager > Performance > GPU now:", G(total), holdSeconds));
      Console.WriteLine("  'Dedicated GPU memory' near full  -> the chunks are in VRAM.");
      Console.WriteLine("  'Shared GPU memory' grew instead   -> Windows put them in system RAM.");
      System.Threading.Thread.Sleep(holdSeconds * 1000);
    }

    foreach (ulong m in mems) { vkUnmapMemory(dev, m); vkFreeMemory(dev, m, IntPtr.Zero); }
    vkDestroyDevice(dev, IntPtr.Zero);
    vkDestroyInstance(inst, IntPtr.Zero);
    Console.WriteLine("All test memory freed.");
  }
}
"@

try {
  Add-Type -TypeDefinition $src -Language CSharp
} catch {
  Write-Host "Could not compile the test helper: $_"
  exit 1
}

try {
  [VkBarTest]::Run($ChunkMiB, $MaxGiB, $HoldSeconds)
} catch [System.DllNotFoundException] {
  Write-Host "vulkan-1.dll not found. Reinstall the NVIDIA driver (it ships the Vulkan runtime)."
}
