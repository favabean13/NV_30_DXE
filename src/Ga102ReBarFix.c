/** @file
  Ga102ReBarFix v0.2 - self-contained Resizable BAR enabler for the memory-modded
  RTX 3080 20GB (10de:2206). Does NOT need NvStrapsReBar.

  What it does, for each matching GPU, during PCI enumeration:
    1. Identify the card (vendor 10DE, display class, device ID + subsystem from a table).
    2. Write the GA102 frame-buffer size override (config dword 0x610, bits 11:7) so the
       card's Resizable BAR capability lists sizes up to 32 GiB instead of 256 MiB.
    3. Walk the PCIe extended capability list, find the Resizable BAR capability, and
       program the size field of the BAR1 entry to the largest advertised size that is
       <= the wanted size (default 32 GiB, optional NVRAM override).
    4. Publish a small status record (variable "Ga102ReBarFixStatus", RAM only) so the
       result can be read from Windows (see Read-Ga102Status.ps1).

  Hook point: like ReBarDxe, it replaces PreprocessController() of
  EFI_PCI_HOST_BRIDGE_RESOURCE_ALLOCATION_PROTOCOL. For an endpoint such as a GPU,
  PciBus calls it with EfiPciBeforeResourceCollection, i.e. before BAR sizes are
  collected, which is the moment a BAR can still be resized safely. The register
  write and the resize are both done before the original function is called.

  Do not run this together with another module that also resizes this GPU's BAR
  (NvStrapsReBar / ReBarDxe): whichever writes last would win.

  STATUS: UNTESTED on hardware. Based on the register values published for this card
  and on the EDK2/PCIe specifications. Keep a recovery path before flashing.

  Licence: MIT.
**/

#include <Uefi.h>
#include <Library/BaseLib.h>
#include <Library/DebugLib.h>
#include <Library/UefiBootServicesTableLib.h>
#include <Library/UefiRuntimeServicesTableLib.h>
#include <Protocol/PciHostBridgeResourceAllocation.h>
#include <Protocol/PciRootBridgeIo.h>

//
// ---- Card identification ---------------------------------------------------
// Vendor must be 10DE and the class must be "display controller" (0x03xxxx).
// SubVendor/SubDevice of 0xFFFF acts as a wildcard. Add rows for other cards.
//
#define NV_VENDOR_ID  0x10DE

typedef struct {
  UINT16  DeviceId;
  UINT16  SubVendorId;
  UINT16  SubDeviceId;
} GPU_ID;

STATIC CONST GPU_ID  mTargets[] = {
  { 0x2206, 0x10DE, 0x146D },   // RTX 3080 20GB (memory-modded)
};

//
// ---- GA102 frame-buffer size override (extended config space) ---------------
// Bits 11:7: bit 11 = enable, bits 10:7 = 9  -> value 0xC80 under mask 0xF80.
//
#define FB_SIZE_OVERRIDE   0x610
#define FB_OVERRIDE_MASK   0x00000F80
#define FB_OVERRIDE_VALUE  0x00000C80

//
// ---- Resizable BAR capability (PCIe extended capability ID 0x0015) ----------
// Header at Cap; entry i has capability register at Cap+4+8*i and control
// register at Cap+8+8*i. Size index n means 1 MiB << n; capability bit (n + 4).
//
#define EXT_CAP_START        0x100
#define EXT_CAP_ID_REBAR     0x0015
#define REBAR_CTRL_IDX_MASK  0x00000007
#define REBAR_CTRL_NUM_SHIFT 5
#define REBAR_CTRL_SZ_SHIFT  8
#define REBAR_CTRL_SZ_MASK   0x00003F00
#define TARGET_BAR_INDEX     1        // BAR1 = the VRAM aperture (config offset 0x14)
#define DEFAULT_SIZE_INDEX   15       // 1 MiB << 15 = 32 GiB. Use 14 = 16 GiB, 13 = 8 GiB.
#define MAX_SIZE_INDEX       19       // capability bits 4..23

//
// ---- Status record -----------------------------------------------------------
//
#define RESULT_NONE           0
#define RESULT_RESIZED        1
#define RESULT_ALREADY        2
#define RESULT_NO_REBAR_CAP   3
#define RESULT_SIZE_UNAVAIL   4
#define RESULT_ACCESS_ERROR   5
#define RESULT_NO_BAR1_ENTRY  6
#define RESULT_CLOCK_GUARD    7   // system date older than MIN_YEAR: module did nothing

#pragma pack(1)
typedef struct {
  UINT32  Signature;        // 'G2RB'
  UINT8   Version;          // 2
  UINT8   Bus;
  UINT8   Device;
  UINT8   Function;
  UINT32  Fb610Before;
  UINT32  Fb610After;
  UINT32  RebarCapOffset;   // 0 = capability not found
  UINT32  SupportedMask;    // capability register of the BAR1 entry (after the 0x610 write)
  UINT8   SizeBefore;       // size index in the control register before
  UINT8   SizeWanted;
  UINT8   SizeAfter;        // size index read back after writing
  UINT8   Result;           // RESULT_*
} STATUS_RECORD;
#pragma pack()

STATIC EFI_GUID  mVarGuid = {
  0x2080A345, 0x07AB, 0x4FE9, { 0x8E, 0x56, 0x1D, 0xBB, 0x17, 0xFA, 0x21, 0xAE }
};

//
// ---- CMOS-clear failsafe ----------------------------------------------------
// Clearing CMOS resets the RTC date. If the date is older than MIN_YEAR the module does
// nothing, so a CMOS clear gets a board that fails to POST with the large BAR booting again.
// Set MIN_YEAR to a year no later than the one your clock is set to (it is 2026 now). If
// your RTC battery dies the module will quietly stop acting; that is intended.
//
#define MIN_YEAR  2026

#define MAX_HOST_BRIDGES  8

typedef struct {
  EFI_PCI_HOST_BRIDGE_RESOURCE_ALLOCATION_PROTOCOL                        *Protocol;
  EFI_PCI_HOST_BRIDGE_RESOURCE_ALLOCATION_PROTOCOL_PREPROCESS_CONTROLLER  Original;
} HOOK_ENTRY;

STATIC HOOK_ENTRY  mHooks[MAX_HOST_BRIDGES];
STATIC UINTN       mHookCount = 0;

STATIC
EFI_STATUS
CfgRead32 (
  IN  EFI_PCI_ROOT_BRIDGE_IO_PROTOCOL  *Rb,
  IN  UINT8                            Bus,
  IN  UINT8                            Dev,
  IN  UINT8                            Func,
  IN  UINT32                           Reg,
  OUT UINT32                           *Value
  )
{
  return Rb->Pci.Read (Rb, EfiPciWidthUint32, EFI_PCI_ADDRESS (Bus, Dev, Func, Reg), 1, Value);
}

STATIC
EFI_STATUS
CfgWrite32 (
  IN EFI_PCI_ROOT_BRIDGE_IO_PROTOCOL  *Rb,
  IN UINT8                            Bus,
  IN UINT8                            Dev,
  IN UINT8                            Func,
  IN UINT32                           Reg,
  IN UINT32                           Value
  )
{
  return Rb->Pci.Write (Rb, EfiPciWidthUint32, EFI_PCI_ADDRESS (Bus, Dev, Func, Reg), 1, &Value);
}

/**
  Return TRUE if this controller is one of the cards in mTargets.
**/
STATIC
BOOLEAN
IsTargetGpu (
  IN EFI_PCI_ROOT_BRIDGE_IO_PROTOCOL  *Rb,
  IN UINT8                            Bus,
  IN UINT8                            Dev,
  IN UINT8                            Func
  )
{
  UINT32  Id;
  UINT32  ClassRev;
  UINT32  Subsys;
  UINTN   Index;

  if (EFI_ERROR (CfgRead32 (Rb, Bus, Dev, Func, 0x00, &Id)) || ((Id & 0xFFFF) != NV_VENDOR_ID)) {
    return FALSE;
  }

  if (EFI_ERROR (CfgRead32 (Rb, Bus, Dev, Func, 0x08, &ClassRev)) || ((ClassRev >> 24) != 0x03)) {
    return FALSE;
  }

  if (EFI_ERROR (CfgRead32 (Rb, Bus, Dev, Func, 0x2C, &Subsys))) {
    return FALSE;
  }

  for (Index = 0; Index < ARRAY_SIZE (mTargets); Index++) {
    if ((UINT16)(Id >> 16) != mTargets[Index].DeviceId) {
      continue;
    }

    if ((mTargets[Index].SubVendorId != 0xFFFF) && ((UINT16)Subsys != mTargets[Index].SubVendorId)) {
      continue;
    }

    if ((mTargets[Index].SubDeviceId != 0xFFFF) && ((UINT16)(Subsys >> 16) != mTargets[Index].SubDeviceId)) {
      continue;
    }

    return TRUE;
  }

  return FALSE;
}

/**
  Offset of the Resizable BAR extended capability header, or 0 if absent.
**/
STATIC
UINT32
FindRebarCap (
  IN EFI_PCI_ROOT_BRIDGE_IO_PROTOCOL  *Rb,
  IN UINT8                            Bus,
  IN UINT8                            Dev,
  IN UINT8                            Func
  )
{
  UINT32  Offset;
  UINT32  Header;
  UINTN   Guard;

  Offset = EXT_CAP_START;
  for (Guard = 0; Guard < 64; Guard++) {
    if ((Offset < EXT_CAP_START) || (Offset >= 0x1000)) {
      return 0;
    }

    if (EFI_ERROR (CfgRead32 (Rb, Bus, Dev, Func, Offset, &Header)) || (Header == 0) || (Header == 0xFFFFFFFF)) {
      return 0;
    }

    if ((Header & 0xFFFF) == EXT_CAP_ID_REBAR) {
      return Offset;
    }

    Offset = (Header >> 20) & 0xFFC;
  }

  return 0;
}

/**
  Wanted size index: optional NVRAM variable "Ga102ReBarSize" (UINT8) or the default.
**/
STATIC
UINT8
GetWantedSizeIndex (
  VOID
  )
{
  UINT8   Value;
  UINTN   Size;
  UINT32  Attr;

  Size = sizeof (Value);
  if (!EFI_ERROR (gRT->GetVariable (L"Ga102ReBarSize", &mVarGuid, &Attr, &Size, &Value)) &&
      (Size == sizeof (Value)) && (Value <= MAX_SIZE_INDEX))
  {
    return Value;
  }

  return DEFAULT_SIZE_INDEX;
}

STATIC
VOID
PublishStatus (
  IN STATUS_RECORD  *Rec
  )
{
  gRT->SetVariable (
         L"Ga102ReBarFixStatus",
         &mVarGuid,
         EFI_VARIABLE_BOOTSERVICE_ACCESS | EFI_VARIABLE_RUNTIME_ACCESS,
         sizeof (*Rec),
         Rec
         );
}

/**
  Steps 2 and 3 for one matching GPU. Idempotent.
**/
STATIC
VOID
EnableLargeBar (
  IN EFI_PCI_ROOT_BRIDGE_IO_PROTOCOL  *Rb,
  IN UINT8                            Bus,
  IN UINT8                            Dev,
  IN UINT8                            Func,
  IN BOOLEAN                          DoResize
  )
{
  STATUS_RECORD  Rec;
  EFI_TIME       Now;
  UINT32         Fb;
  UINT32         NewFb;
  UINT32         FbAfter;
  UINT32         Cap;
  UINT32         Ctrl0;
  UINT32         EntryCap;
  UINT32         EntryCtrl;
  UINT32         NumBars;
  UINT32         Index;
  INTN           Best;
  INTN           N;
  UINT8          Wanted;

  ZeroMem (&Rec, sizeof (Rec));
  Rec.Signature = SIGNATURE_32 ('G', '2', 'R', 'B');
  Rec.Version   = 2;
  Rec.Bus       = Bus;
  Rec.Device    = Dev;
  Rec.Function  = Func;

  if (!EFI_ERROR (gRT->GetTime (&Now, NULL)) && (Now.Year < MIN_YEAR)) {
    if (DoResize) {
      Rec.Result = RESULT_CLOCK_GUARD;
      PublishStatus (&Rec);
    }

    return;
  }

  //
  // Step 2: frame-buffer size override.
  //
  if (EFI_ERROR (CfgRead32 (Rb, Bus, Dev, Func, FB_SIZE_OVERRIDE, &Fb))) {
    Rec.Result = RESULT_ACCESS_ERROR;
    PublishStatus (&Rec);
    return;
  }

  Rec.Fb610Before = Fb;
  if ((Fb & FB_OVERRIDE_MASK) != FB_OVERRIDE_VALUE) {
    NewFb = (Fb & ~FB_OVERRIDE_MASK) | FB_OVERRIDE_VALUE;
    CfgWrite32 (Rb, Bus, Dev, Func, FB_SIZE_OVERRIDE, NewFb);
    gBS->Stall (1000);   // give the capability a moment to update
  }

  if (EFI_ERROR (CfgRead32 (Rb, Bus, Dev, Func, FB_SIZE_OVERRIDE, &FbAfter))) {
    FbAfter = 0xFFFFFFFF;
  }

  Rec.Fb610After = FbAfter;

  if (!DoResize) {
    return;   // endpoints reach us in EfiPciBeforeResourceCollection; resize only there
  }

  //
  // Step 3: find the Resizable BAR capability and program the BAR1 entry.
  //
  Cap = FindRebarCap (Rb, Bus, Dev, Func);
  Rec.RebarCapOffset = Cap;
  if (Cap == 0) {
    Rec.Result = RESULT_NO_REBAR_CAP;
    PublishStatus (&Rec);
    return;
  }

  if (EFI_ERROR (CfgRead32 (Rb, Bus, Dev, Func, Cap + 8, &Ctrl0))) {
    Rec.Result = RESULT_ACCESS_ERROR;
    PublishStatus (&Rec);
    return;
  }

  NumBars = (Ctrl0 >> REBAR_CTRL_NUM_SHIFT) & 0x7;
  if ((NumBars == 0) || (NumBars > 6)) {
    NumBars = 1;
  }

  Wanted         = GetWantedSizeIndex ();
  Rec.SizeWanted = Wanted;
  Rec.Result     = RESULT_NO_BAR1_ENTRY;

  for (Index = 0; Index < NumBars; Index++) {
    if (EFI_ERROR (CfgRead32 (Rb, Bus, Dev, Func, Cap + 4 + 8 * Index, &EntryCap)) ||
        EFI_ERROR (CfgRead32 (Rb, Bus, Dev, Func, Cap + 8 + 8 * Index, &EntryCtrl)))
    {
      Rec.Result = RESULT_ACCESS_ERROR;
      break;
    }

    if ((EntryCtrl & REBAR_CTRL_IDX_MASK) != TARGET_BAR_INDEX) {
      continue;
    }

    Rec.SupportedMask = EntryCap & 0xFFFFFFF0;
    Rec.SizeBefore    = (UINT8)((EntryCtrl & REBAR_CTRL_SZ_MASK) >> REBAR_CTRL_SZ_SHIFT);

    Best = -1;
    for (N = Wanted; N >= 0; N--) {
      if ((EntryCap & (1U << (N + 4))) != 0) {
        Best = N;
        break;
      }
    }

    if (Best < 0) {
      Rec.Result = RESULT_SIZE_UNAVAIL;
      break;
    }

    if (Rec.SizeBefore == (UINT8)Best) {
      Rec.SizeAfter = Rec.SizeBefore;
      Rec.Result    = RESULT_ALREADY;
      break;
    }

    EntryCtrl = (EntryCtrl & ~REBAR_CTRL_SZ_MASK) | ((UINT32)Best << REBAR_CTRL_SZ_SHIFT);
    CfgWrite32 (Rb, Bus, Dev, Func, Cap + 8 + 8 * Index, EntryCtrl);

    if (!EFI_ERROR (CfgRead32 (Rb, Bus, Dev, Func, Cap + 8 + 8 * Index, &EntryCtrl))) {
      Rec.SizeAfter = (UINT8)((EntryCtrl & REBAR_CTRL_SZ_MASK) >> REBAR_CTRL_SZ_SHIFT);
    }

    Rec.Result = (Rec.SizeAfter == (UINT8)Best) ? RESULT_RESIZED : RESULT_ACCESS_ERROR;
    break;
  }

  DEBUG ((
    DEBUG_INFO,
    "Ga102ReBarFix: %02x:%02x.%x 0x610 %08x->%08x cap@%x mask %08x size %d->%d (want %d) result %d\n",
    Bus, Dev, Func, Rec.Fb610Before, Rec.Fb610After, Rec.RebarCapOffset,
    Rec.SupportedMask, Rec.SizeBefore, Rec.SizeAfter, Rec.SizeWanted, Rec.Result
    ));
  PublishStatus (&Rec);
}

STATIC
EFI_STATUS
EFIAPI
PreprocessControllerHook (
  IN EFI_PCI_HOST_BRIDGE_RESOURCE_ALLOCATION_PROTOCOL  *This,
  IN EFI_HANDLE                                        RootBridgeHandle,
  IN EFI_PCI_ROOT_BRIDGE_IO_PROTOCOL_PCI_ADDRESS       PciAddress,
  IN EFI_PCI_CONTROLLER_RESOURCE_ALLOCATION_PHASE      Phase
  )
{
  EFI_PCI_ROOT_BRIDGE_IO_PROTOCOL  *Rb;
  UINTN                            Index;

  if (!EFI_ERROR (gBS->HandleProtocol (RootBridgeHandle, &gEfiPciRootBridgeIoProtocolGuid, (VOID **)&Rb))) {
    if (IsTargetGpu (Rb, PciAddress.Bus, PciAddress.Device, PciAddress.Function)) {
      EnableLargeBar (
        Rb,
        PciAddress.Bus,
        PciAddress.Device,
        PciAddress.Function,
        (BOOLEAN)(Phase == EfiPciBeforeResourceCollection)
        );
    }
  }

  for (Index = 0; Index < mHookCount; Index++) {
    if (mHooks[Index].Protocol == This) {
      return mHooks[Index].Original (This, RootBridgeHandle, PciAddress, Phase);
    }
  }

  return EFI_UNSUPPORTED;
}

EFI_STATUS
EFIAPI
Ga102ReBarFixEntry (
  IN EFI_HANDLE        ImageHandle,
  IN EFI_SYSTEM_TABLE  *SystemTable
  )
{
  EFI_STATUS                                        Status;
  EFI_HANDLE                                        *Handles;
  UINTN                                             Count;
  UINTN                                             Index;
  EFI_PCI_HOST_BRIDGE_RESOURCE_ALLOCATION_PROTOCOL  *HostBridge;

  Status = gBS->LocateHandleBuffer (
                  ByProtocol,
                  &gEfiPciHostBridgeResourceAllocationProtocolGuid,
                  NULL,
                  &Count,
                  &Handles
                  );
  if (EFI_ERROR (Status)) {
    return EFI_SUCCESS;   // never block boot
  }

  for (Index = 0; (Index < Count) && (mHookCount < MAX_HOST_BRIDGES); Index++) {
    Status = gBS->HandleProtocol (
                    Handles[Index],
                    &gEfiPciHostBridgeResourceAllocationProtocolGuid,
                    (VOID **)&HostBridge
                    );
    if (EFI_ERROR (Status)) {
      continue;
    }

    mHooks[mHookCount].Protocol      = HostBridge;
    mHooks[mHookCount].Original      = HostBridge->PreprocessController;
    HostBridge->PreprocessController = PreprocessControllerHook;
    mHookCount++;
  }

  gBS->FreePool (Handles);
  return EFI_SUCCESS;
}
