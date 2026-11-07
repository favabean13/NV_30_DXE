# Third-party notices and credits

## Credits

Ga102ReBarFix builds on research and techniques published by:

- **[noon-at-cgn](https://github.com/noon-at-cgn)**: [3080-20gb-rebar](https://github.com/noon-at-cgn/3080-20gb-rebar),
  [geforce-bar1-resize](https://github.com/noon-at-cgn/geforce-bar1-resize) and
  [geforce-dynbar1-p2p](https://github.com/noon-at-cgn/geforce-dynbar1-p2p). They discovered the GA102
  frame-buffer size override at PCI config `0x610` and its values for the RTX 3080 20GB.
- **[Timothy Madden (@terminatorul)](https://github.com/terminatorul)**: [NvStrapsReBar](https://github.com/terminatorul/NvStrapsReBar).
  This project takes its S3 resume-script approach: restore the bridge path to the GPU before writing to it.
- **[xCuri0](https://github.com/xCuri0)**: [ReBarUEFI](https://github.com/xCuri0/ReBarUEFI). This project
  takes its `PreprocessController` hook technique and its method for inserting a DXE module into a UEFI image.

No source code from those projects is included. See "Credits and code provenance" in `README.md`.

## TianoCore EDK II

The compiled module (`Ga102ReBarFix.ffs` / `.efi`) is built with the TianoCore EDK II BaseTools and
statically links EDK II library code: UefiDriverEntryPoint, BaseLib, BaseMemoryLib,
UefiBootServicesTableLib, UefiRuntimeServicesTableLib and DebugLib. That code is licensed under the
BSD-2-Clause-Patent license below, which must accompany binary redistributions.

```text
Copyright (c) 2019, TianoCore and contributors.  All rights reserved.

SPDX-License-Identifier: BSD-2-Clause-Patent

Redistribution and use in source and binary forms, with or without
modification, are permitted provided that the following conditions are met:

1. Redistributions of source code must retain the above copyright notice,
   this list of conditions and the following disclaimer.

2. Redistributions in binary form must reproduce the above copyright notice,
   this list of conditions and the following disclaimer in the documentation
   and/or other materials provided with the distribution.

Subject to the terms and conditions of this license, each copyright holder
and contributor hereby grants to those receiving rights under this license
a perpetual, worldwide, non-exclusive, no-charge, royalty-free, irrevocable
(except for failure to satisfy the conditions of this license) patent
license to make, have made, use, offer to sell, sell, import, and otherwise
transfer this software, where such license applies only to those patent
claims, already acquired or hereafter acquired, licensable by such copyright
holder or contributor that are necessarily infringed by:

(a) their Contribution(s) (the licensed copyrights of copyright holders and
    non-copyrightable additions of contributors, in source or binary form)
    alone; or

(b) combination of their Contribution(s) with the work of authorship to
    which such Contribution(s) was added by such copyright holder or
    contributor, if, at the time the Contribution is added, such addition
    causes such combination to be necessarily infringed. The patent license
    shall not apply to any other combinations which include the
    Contribution.

Except as expressly stated above, no rights or licenses from any copyright
holder or contributor is granted under this license, whether expressly, by
implication, estoppel or otherwise.

DISCLAIMER

THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS"
AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE
ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDERS OR CONTRIBUTORS BE
LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR
CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF
SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS
INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN
CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE)
ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE
POSSIBILITY OF SUCH DAMAGE.
```
