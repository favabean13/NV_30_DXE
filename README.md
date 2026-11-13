# RTX 3080 20GB ReBarFix "AKA" NV_30_DXE

**Resizable BAR for the memory-modified RTX 3080 20GB on Windows, including sleep and resume.**

Confirmed, working with GPU_UNLOCKER: https://github.com/physicsdolphin/nv-uefi-unlocker

Ga102ReBarFix.ffs (NV_30_DXE) is a small UEFI firmware module (a DXE driver) that you insert into your motherboard's
BIOS image. On every boot it unlocks the full 32 GiB BAR1 on the RTX 3080 20GB (PCI ID `10DE:2206`,
subsystem `10DE:146D`). Windows and the NVIDIA driver then see Resizable BAR as active, and the CPU can
reach all of the card's VRAM instead of a 256 MiB window. From v0.5 it also restores this after
**S3 sleep**, so waking from sleep works.

You don't need to modify the card's VBIOS, patch the NVIDIA driver, or change any registry settings.

> [!WARNING]
> **Use at your own risk.** This project modifies motherboard firmware. The author is **not
> responsible for any damage** to hardware, firmware, software or data resulting from its use, including
> a board that won't boot or any subsequent unforeseen damages associated with this project. The project is provided **as is** and will **not be maintained or updated**.
> See [Disclaimer and project status](#12-disclaimer-and-project-status).

---

## Contents

1. [The short of it](#1-the-short-of-it)
2. [Tested hardware and results](#2-tested-hardware-and-results)
3. [Before you start](#3-before-you-start)
4. [Installation](#4-installation)
5. [Verifying it works](#5-verifying-it-works)
6. [Troubleshooting and recovery](#6-troubleshooting-and-recovery)
7. [How it works (detailed)](#7-how-it-works-detailed)
8. [Building from source](#8-building-from-source)
9. [Version history](#9-version-history)
10. [Credits and code provenance](#10-credits-and-code-provenance)
11. [License](#11-license)
12. [Disclaimer and project status](#12-disclaimer-and-project-status)

---

## 1. The short of it

**The problem.** 

These modified RTX 3080 have 20 GB of VRAM, but its VBIOS only advertises a 256 MiB BAR1, the
window the CPU uses to reach VRAM. NVIDIA doesn't publish a Resizable BAR VBIOS for these cards, and
tools such as NvStrapsReBar only support Turing GPUs. This was a passion project created from necessity. 

**The key discovery.** 

Ampere GA102 GPUs have a frame-buffer size override at PCI configuration
register `0x610`. Writing the right bits there makes the card advertise BAR1 sizes up to 32 GiB. This
was found and documented for Linux by **[noon-at-cgn](https://github.com/noon-at-cgn)**.

**What this project adds.** 

A firmware module that does that write **during the motherboard's PCI
enumeration**, before Windows starts:

1. Find the RTX 3080 20GB.
2. Set the `0x610` override, so the card advertises up to 32 GiB.
3. Resize BAR1 to 32 GiB through the standard PCIe Resizable BAR capability.
4. Record the steps needed to repeat this when the PC wakes from S3 sleep.
5. Leave a small status record that you can read from Windows.

The firmware then assigns address space for the 32 GiB BAR as normal, and Windows and the NVIDIA driver
treat it like any Resizable BAR card.

---

## 2. Tested hardware and results

| Item | Tested |
|---|---|
| GPU | RTX 3080 20GB, memory-modded engineering sample, `10DE:2206` / `10DE:146D`, VBIOS 94.02.27.00.14, PCIe 4.0 x16 |
| Motherboard | MSI Z690 EDGE (MS-7D31), BIOS image E7D31IMS |
| OS | Windows 11, build 26300 |
| NVIDIA driver | 617.42 |
| Module version | v0.5 |

| Check | Result |
|---|---|
| BAR1 size (Device Manager → Resources) | **32 GiB** memory range |
| NVIDIA Control Panel → System Information | **Resizable BAR: Yes** |
| CPU-visible VRAM heap (Vulkan) | 19.63 GiB, the whole usable VRAM |
| VRAM held mapped by the CPU at once (`Test-HostVisibleVram.ps1`) | **~19.25 GiB**, confirmed in *dedicated* GPU memory by Task Manager |
| Sleep (S3) and wake | **Works** (v0.5) |
| `RMForceStaticBar1` registry key | Not needed. Results were identical with the key set to `0` and with it absent. |

This has been tested on one motherboard and one card. Other boards may handle PCIe state on resume
differently. The project isn't maintained, so results from other systems are best shared in your own
forks or write-ups.

---

## 3. Before you start

**Risk.** You will be flashing a modified BIOS. A bad flash, or a module your board doesn't like,
can leave the PC unable to POST. Make sure you have a recovery route first, such as MSI's Flash BIOS
Button (USB BIOS Flashback), a second BIOS, or an external SPI programmer. **Keep a copy of your
current, working BIOS image.**

**You need:**
- An RTX 3080 20GB with ID `10DE:2206`, subsystem `10DE:146D`. Other cards are ignored.
- A UEFI motherboard with these settings:
  - **Above 4G Decoding**: Enabled
  - **Re-Size BAR Support**: Enabled, if your board has this option
  - **CSM**: Disabled (pure UEFI boot)
- [UEFITool](https://github.com/LongSoft/UEFITool) to insert the module.
- `Ga102ReBarFix.ffs`, either a release build or one you built yourself (see [section 8](#8-building-from-source)).

**Don't combine it with NvStrapsReBar or ReBarUEFI's ReBarDxe** on the same card. Both would try to
resize the same BAR, and whichever runs last wins. Remove the other module first.

---

## 4. Installation

These steps follow ReBarUEFI's guide,
[Adding FFS module](https://github.com/xCuri0/ReBarUEFI/wiki/Adding-FFS-module), with
`Ga102ReBarFix.ffs` in place of `ReBarDxe.ffs`.

1. **Get a clean BIOS image.** Start from the stock image for your board, ideally the latest version
   from the manufacturer's website.
2. **Open it in UEFITool 0.28 (the non-NE version).** The NE versions can't insert modules.
3. **Find the PCI bus driver.** Go to **File → Search**, choose **GUID**, tick **Header only**, and
   search for `3C1DE39F-D207-408A-AACC-731CFB7F1DD7` (PciBus). The result is in the DXE volume to
   insert into. The module name may not be displayed.
   - **No results?** Try a **hex** search for `CF8034BE`, or a **text (Unicode)** search for `PciBus`.
   - **Two results?** Insert the module into **both** volumes.
4. **Insert the module.** Scroll to the end of that volume, right-click the **last** module, choose
   **Insert after…**, and select `Ga102ReBarFix.ffs`.
   - **Upgrading from an earlier Ga102ReBarFix:** the GUID is always
     `04BCD678-E6A6-4598-A1AA-29F99E7850C2`. Search for it and use **Replace as is…** on the old module
     instead of inserting a second copy.
5. **Confirm** that `Ga102ReBarFix` now appears in the list.
6. **Save** with **File → Save image file**.
7. **Flash** the image the way your board supports. On MSI boards that's M-Flash or Flash BIOS Button.
8. **Check the BIOS settings** listed in [section 3](#3-before-you-start). Flashing may reset them.
9. **Boot Windows** and run the checks below.

**If UEFITool doesn't work for your image**, the same guide describes an alternative using AMI's
MMTool (Aptio V boards usually need 5.02.0025): **Load Image**, **Browse** to the `.ffs`, select
**PciBus** so that **Vol. Index** is filled in, **Insert**, then **Save Image as…**. Check the MMTool
version and file hashes against the guide.

---

## 5. Verifying it works

PowerShell scripts for these checks are included. Run them from an **elevated** PowerShell, with all of
them in the same folder:

```powershell
powershell -ExecutionPolicy Bypass -File .\Read-Ga102Status.ps1
powershell -ExecutionPolicy Bypass -File .\Test-HostVisibleVram.ps1 -HoldSeconds 30
powershell -ExecutionPolicy Bypass -File .\Get-WakeDiagnostics.ps1 -Save
```

### Why not just use `nvidia-smi`?

`nvidia-smi -q` is fine for one thing: **BAR1 Memory Usage → Total** shows the aperture size, and
it reads **32768 MiB** with this module. Beyond that, it can't confirm that ReBAR is working:

- **"Used" is meaningless with a large BAR1.** On the tested system it reads about **32739 of 32768
  MiB used** (29 MiB free) at an idle desktop, whatever the configuration. The driver reserves the
  aperture's address range for its own bookkeeping. That doesn't mean 32 GB of anything is in use, and
  it doesn't mean the BAR is full. noon-at-cgn's Linux project reports the same behaviour.
- **"Total" only gives the window size.** It doesn't show whether the CPU can actually reach the VRAM
  behind it. On Linux, the static BAR1 mode leaves only ~10 of 20 GB CPU-accessible, even with a large
  BAR1. A healthy setup and a limited one can show the same `nvidia-smi` numbers.
- **It doesn't show the firmware side or sleep/resume:** whether the `0x610` override was applied,
  whether the resume steps were recorded, or why a wake failed.

The scripts below measure those things directly:
- `Read-Ga102Status.ps1` reports what the module did at boot.
- `Test-HostVisibleVram.ps1` measures how much VRAM the CPU can really map at once. Task Manager
  confirms that memory is in VRAM.
- `Get-WakeDiagnostics.ps1` shows whether waking from sleep succeeded.

### 5.1 Quick checks (no scripts)

- **Device Manager** → Display adapters → RTX 3080 → Properties → **Resources**. One memory range
  should be **32 GiB**. On the tested system it is `0x6000000000–0x67FFFFFFFF`.
- **NVIDIA Control Panel** → Help → System Information: **Resizable BAR: Yes**.

### 5.2 `Read-Ga102Status.ps1`: what the module did at boot

The module writes a small status record on every full boot. Expected v0.5 output:

| Field | Expected | Meaning |
|---|---|---|
| Record version | `5` | Module v0.5 is running |
| 0x610 before → after | `0x00001001` → `0x00001C81` | Override enabled |
| Size before → after | index 8 (256 MiB) → index 15 (32 GiB) | BAR1 resized |
| Result | `1` (RESIZED) or `2` (already at wanted size) | Success |
| S3 entries | `3` for a GPU directly on a CPU root port | Bridge restore + 0x610 + BAR1 size recorded for resume |
| Upstream bridge | for example `00:01.0` | The root port the GPU is attached to |

The other result codes are: `3` no Resizable BAR capability found, `4` wanted size not advertised,
`5` config access error, `6` no BAR1 entry, `7` clock guard (see [6.3](#63-cmos-clear-failsafe)).

### 5.3 `Test-HostVisibleVram.ps1`: can the CPU actually reach the VRAM?

Through Vulkan, this script allocates the GPU's *CPU-visible VRAM* in 256 MiB chunks and keeps every
chunk mapped. It writes to each one, reads it back, and continues until the driver refuses. It needs no
SDK, compiler or admin rights.

- **Without ReBAR**, the CPU-visible VRAM heap is only ~200–250 MiB.
- **With this module**, you should see a heap close to the full VRAM, and roughly 19+ GiB mapped at once.

To confirm the memory is really in VRAM, run it with `-HoldSeconds 30` and watch Task Manager →
Performance → GPU. **Dedicated GPU memory** should fill, and **Shared GPU memory** should stay at 0.

### 5.4 `Get-WakeDiagnostics.ps1`: sleep and wake

After a sleep/wake test, this script collects:
- the sleep states your system supports,
- power, boot, crash and GPU events,
- crash-dump bugcheck codes,
- the module's status record,

and then reports each recent wake as successful or failed, with the likely reason.

---

## 6. Troubleshooting and recovery

### 6.1 Common situations

| Symptom | Likely cause / fix |
|---|---|
| `Read-Ga102Status.ps1` says "No status record" | The module didn't run or didn't find the card. Check it's in the same DXE volume as PciBus, that the BIOS boots in UEFI mode, and that the card's subsystem is `10DE:146D`. |
| Result `4` (size not advertised) | The `0x610` override didn't take effect. The card may not be the 20GB GA102 variant this was made for. |
| BAR is still 256 MiB in Device Manager | Above 4G Decoding is off, or another ReBAR module is overriding this one. |
| PC restarts when waking from sleep | You're running v0.4 or earlier. Upgrade to v0.5. Run `Get-WakeDiagnostics.ps1` for details. |
| `RMForceStaticBar1=1` → Windows won't boot | Forcing static BAR1 makes the NVIDIA driver fail to start on this card (live dump `0x1B0`, "insufficient resources"). Delete the value from Safe Mode. It isn't needed. |

### 6.2 Recovery

If the PC won't POST after flashing, use your board's recovery path, such as Flash BIOS Button or a
programmer, to restore the stock or previous working image.

### 6.3 CMOS-clear failsafe

The module only acts if the real-time clock year is **2026 or later** (`MIN_YEAR` in the source).
Clearing CMOS usually resets the clock to an earlier year. The module then does nothing, and the board
boots with the stock 256 MiB BAR. That gives you a way back in without reflashing. When you set the
clock correctly again, the module turns itself back on. A dead RTC battery has the same effect, which
is intended.

---

## 7. How it works (detailed)

### 7.1 Where it runs

During boot, the firmware's PCI bus driver (PciBus) enumerates devices. For each device it calls
`PreprocessController()` on the platform's `EFI_PCI_HOST_BRIDGE_RESOURCE_ALLOCATION_PROTOCOL`, once per
phase. Ga102ReBarFix replaces that function pointer on every host bridge with its own hook, then calls
the original. This is the same technique ReBarUEFI by [xCuri0](https://github.com/xCuri0) uses.

When the hook is called for the target GPU in the **`EfiPciBeforeResourceCollection`** phase, BAR sizes
haven't been read yet. That makes it the right moment to change BAR1's size, because the firmware will
then assign address space for the new size. The module's dependency expression
(`gEfiPciHostBridgeResourceAllocationProtocolGuid`) makes it load only once that protocol exists.
Inserting it into the same DXE volume as PciBus lets it hook the protocol before enumeration starts.

### 7.2 Identifying the card

A device must match all of the following, or it's left untouched:
- vendor `10DE`,
- PCI class `03` (display controller),
- device `2206`,
- subsystem `10DE:146D`.

The table `mTargets[]` in the source can be extended for other cards.

### 7.3 The frame-buffer size override (`0x610`)

GA102 has a vendor-specific register at PCI config dword `0x610`. Bits 11:7 control a frame-buffer size
override:
- bit 11 enables it,
- bits 10:7 hold the size code.

The module performs a **masked write**: value `0xC80` under mask `0xF80`. Only bits 11:7 change. Other
bits, such as bit 0 and bit 12, are preserved. On the tested card this changes `0x610` from
`0x00001001` to `0x00001C81`, and the card's Resizable BAR capability then lists sizes up to 32 GiB. The
register values come from [noon-at-cgn](https://github.com/noon-at-cgn)'s Linux work. The Linux script performs the same masked write.

### 7.4 Resizing BAR1

The module walks the PCIe extended capability list from `0x100` to find the Resizable BAR capability
(ID `0x0015`). It doesn't hardcode the offset. In that capability it finds the entry for **BAR1**, the VRAM
aperture, and picks the largest advertised size that is ≤ the wanted size. The default is index 15,
1 MiB << 15 = **32 GiB**. It writes that into the entry's control register and reads it back to confirm.

*Advanced:* an optional UEFI variable `Ga102ReBarSize` (one byte, a size index, vendor GUID
`2080A345-07AB-4FE9-8E56-1DBB17FA21AE`) overrides the wanted size without rebuilding. For example,
14 = 16 GiB and 13 = 8 GiB.

### 7.5 The status record

At the end the module publishes `Ga102ReBarFixStatus`, under the same vendor GUID. It's a volatile UEFI
variable, readable at runtime and lost at power-off. It contains:
- the device location,
- `0x610` before and after,
- the capability offset and advertised sizes,
- BAR1 size before, wanted and after,
- a result code,
- the number of S3 entries recorded,
- the upstream bridge.

`Read-Ga102Status.ps1` reads it with `GetFirmwareEnvironmentVariable`.

### 7.6 Sleep and resume (S3)

In S3 the GPU loses power completely. When the system wakes, firmware doesn't run the full boot
sequence, so this module doesn't run again. Instead the firmware replays a **boot script**, a list of
register writes recorded during boot. Without help, the card wakes with `0x610` cleared. It then
advertises only 256 MiB while Windows and the driver expect 32 GiB, and the driver times out
(bugchecks `0x141` → `0x116`).

The module records these steps through `EFI_S3_SAVE_STATE_PROTOCOL`, in this order:

1. **Restore the bus numbers of every bridge between the root bus and the GPU** (config `0x18`:
   primary, secondary and subordinate bus), root side first, keeping the top byte. After S3, those
   bridges wake with their bus numbers cleared. Until they're restored, config writes to the GPU's bus
   aren't routed anywhere and are dropped silently. **This was the missing piece in v0.4.** The
   technique comes from NvStrapsReBar by [Timothy Madden (@terminatorul)](https://github.com/terminatorul), which restores the bridge path before touching the GPU.
2. **Stall 100 ms**, so the PCIe link and the GPU are ready to accept config requests.
3. **Re-apply the `0x610` override.**
4. **Stall 1 ms.**
5. **Re-apply the BAR1 size.**

All entries use `EFI_BOOT_SCRIPT_PCI_CONFIG2_READ_WRITE_OPCODE`. That's a segment-aware masked
read-modify-write: bits set in the mask keep their current value, and the other bits take the recorded
value. Each register is recorded once per boot. Nothing else is recorded: no BAR addresses, bridge
windows, command registers or MMIO writes. Windows restores BAR addresses and windows itself when the
system wakes.

### 7.7 What it deliberately does not do

- It doesn't modify the GPU's VBIOS or any persistent GPU state. Everything is redone on every boot and
  wake.
- It doesn't change any setting on any device other than the matching GPU and, only in the resume
  script, the bus-number registers of the bridges above it.
- It doesn't need any Windows-side component, driver patch or registry change.

---

## 8. Building from source

Requirements: [TianoCore EDK II](https://github.com/tianocore/edk2) (tested with tag
`edk2-stable202402`), GCC (the `GCC5` toolchain tag), NASM and Python 3. The build in this repository
runs on GitHub Actions (`ubuntu-latest`).

```bash
git clone --branch edk2-stable202402 https://github.com/tianocore/edk2
cd edk2 && git submodule update --init --recursive   # see the workflow for a dead-submodule fix
make -C BaseTools
mkdir -p MdeModulePkg/Universal/Ga102ReBarFix
cp /path/to/Ga102ReBarFix.c /path/to/Ga102ReBarFix.inf MdeModulePkg/Universal/Ga102ReBarFix/
# add "MdeModulePkg/Universal/Ga102ReBarFix/Ga102ReBarFix.inf" under [Components.X64] in MdeModulePkg/MdeModulePkg.dsc
source edksetup.sh
build -p MdeModulePkg/MdeModulePkg.dsc -m MdeModulePkg/Universal/Ga102ReBarFix/Ga102ReBarFix.inf \
      -a X64 -t GCC5 -b RELEASE
```

Then wrap the driver into an FFS file:

1. Set the PE `NX_COMPAT` flag (`DllCharacteristics |= 0x0100`) on `Ga102ReBarFix.efi`. Some
   firmware requires it, and the workflow does it with a few lines of Python.
2. Build the three sections:
   ```bash
   GenSec -s EFI_SECTION_DXE_DEPEX      -o dep.sec Build/.../OUTPUT/Ga102ReBarFix.depex
   GenSec -s EFI_SECTION_PE32           -o pe.sec  Ga102ReBarFix.efi
   GenSec -s EFI_SECTION_USER_INTERFACE -n "Ga102ReBarFix" -o ui.sec
   ```
3. Combine them:
   ```bash
   GenFfs -t EFI_FV_FILETYPE_DRIVER -g 04BCD678-E6A6-4598-A1AA-29F99E7850C2 \
          -o Ga102ReBarFix.ffs -i dep.sec -i pe.sec -i ui.sec
   ```

---

## 9. Version history

| Version | Change |
|---|---|
| v0.2 | `0x610` override and BAR1 resize during PCI enumeration, status variable, optional size override, CMOS-clear failsafe. **First confirmed working build (cold boot).** |
| v0.3 | First attempt at S3 resume recording (full-dword writes). Never flashed. |
| v0.4 | S3 entries switched to masked, segment-aware read-modify-write and recorded once per boot. Waking still failed: the entries had no effect without the bridge restore. |
| v0.5 | **Bridge bus-number restore and 100 ms stall before the GPU entries. S3 sleep/resume works.** Status record v5 (adds the upstream bridge). Proper `BaseMemoryLib` dependency. |

---

## 10. Credits and code provenance

This project wouldn't exist without the following work. For transparency, here is exactly what was
used from each:

| Project and author | License | What this project uses | Code copied? |
|---|---|---|---|
| **[3080-20gb-rebar](https://github.com/noon-at-cgn/3080-20gb-rebar)**, **[geforce-bar1-resize](https://github.com/noon-at-cgn/geforce-bar1-resize)**, **[geforce-dynbar1-p2p](https://github.com/noon-at-cgn/geforce-dynbar1-p2p)** by **[noon-at-cgn](https://github.com/noon-at-cgn)** | see their repositories | The discovery and documentation of the GA102 `0x610` frame-buffer size override, its value and mask (`0xC80`/`0xF80`), the expected register values for this card, and the background on static vs. dynamic BAR1. | **No.** Those are shell scripts for Linux. This project reimplements the same register write in C for UEFI. |
| **[NvStrapsReBar](https://github.com/terminatorul/NvStrapsReBar)** by **[Timothy Madden (@terminatorul)](https://github.com/terminatorul)** | MIT | The S3 approach: record a restore of the upstream bridge's bus numbers (masked, keeping the top byte) *before* writing to the GPU (its `pciSaveAndRemapBridgeConfig`). Also the general use of `EFI_S3_SAVE_STATE_PROTOCOL` and of a status UEFI variable. | **No.** The technique was studied in its source and written independently. The register, value layout and mask are the same because they're defined by the PCI specification. |
| **[ReBarUEFI](https://github.com/xCuri0/ReBarUEFI)** by **[xCuri0](https://github.com/xCuri0)** | MIT | The technique of hooking `PreprocessController` on `EFI_PCI_HOST_BRIDGE_RESOURCE_ALLOCATION_PROTOCOL` to resize BARs before resource collection, and the FFS-insertion procedure from its wiki. | **No.** The hook was written independently. Its structure is similar because it uses the same standard EDK II interfaces. |
| **[TianoCore EDK II](https://github.com/tianocore/edk2)** by **TianoCore and contributors** | BSD-2-Clause-Patent | Headers, libraries and build tools. | **Yes, in the compiled binary.** `Ga102ReBarFix.ffs`/`.efi` statically links EDK II library code (UefiDriverEntryPoint, BaseLib, BaseMemoryLib, UefiBootServicesTableLib, UefiRuntimeServicesTableLib, DebugLib). Its license notice is in [`THIRD-PARTY-NOTICES.md`](THIRD-PARTY-NOTICES.md) and must accompany binary redistributions. |

**Development note:** parts of the source code and the PowerShell tools were drafted with AI
assistance (Anthropic Claude and OpenAI ChatGPT). They were reviewed, built and tested on real hardware
by the author.

---

## 11. License

**MIT.** See [`LICENSE`](LICENSE).

You may use, modify, fork, sell and redistribute this project, in source or binary form, as long as the
copyright notice **and the credits in it** are kept. That credits the author of this project and the
authors listed above. Binary redistributions must also include the TianoCore EDK II notice found in
[`THIRD-PARTY-NOTICES.md`](THIRD-PARTY-NOTICES.md).

---

## 12. Disclaimer and project status

**No liability.** This software is provided "as is", without warranty of any kind, as stated in the
MIT license. The author is **not responsible for any damage or loss** arising from using, building,
flashing or modifying this project, including:
- damaged or unbootable motherboards, BIOS chips or GPUs,
- corrupted firmware, data loss, instability or crashes,
- voided warranties.

Flashing a modified BIOS is risky. You do it entirely at your own risk, and you're responsible for
having a working backup and a recovery method.

**Not maintained.** This project is published as is and **will not be maintained, updated or
supported**.

**Forks and reuse are welcome.** Anyone may modify, fork, extend or integrate this project into their
own work for their own use cases, including commercial use, under the terms of the MIT license, as long
as the copyright notice in `LICENSE` and the credits in it are kept. If you adapt it to other cards or boards, please publish your
changes so others can benefit.

*This project is not affiliated with or endorsed by NVIDIA, MSI or any of the credited authors.*
