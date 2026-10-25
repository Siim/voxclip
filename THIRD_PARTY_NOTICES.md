# Third-party notices

VoxClip is MIT-licensed (see `LICENSE`). It bundles or links the third-party components below, each under its own licence. This is the single notices file: `bundle.sh` copies it into `VoxClip.app/Contents/Resources/` and the Windows release copies it into the install folder (doc/release.md), and both apps show it in About → Licences. Every new dependency, font, data file or model adds its section here in the same change, with the exact licence text from the pinned package.

Sections: Fonts; Data (Unicode Character Database); Application components (macOS, Windows); Models (downloaded at the user's request, never bundled); licence texts.

## Fonts

Caption fonts and emoji images in `shared/fonts/`, bundled unmodified with both apps (doc/spec/captions.md section 4). Each family's licence file ships next to its fonts. Source URLs are pinned to the commit the files were taken from; `shared/fonts/fonts.json` records the sha256 of every file.

### Anton

- Files: `anton/Anton-Regular.ttf`
- Licence: SIL Open Font License 1.1 (`shared/fonts/anton/OFL.txt`)
- Source: https://github.com/google/fonts/tree/e0a8124cf36bb7c32ca68e5d46d6acdbc3df866a/ofl/anton
- Notice:

  ```text
  Copyright 2020 The Anton Project Authors (https://github.com/googlefonts/AntonFont.git)
  ```

### DM Sans

- Files: `dm-sans/DMSans-Black.ttf`, `dm-sans/DMSans-Bold.ttf`, `dm-sans/DMSans-Medium.ttf`
- Licence: SIL Open Font License 1.1 (`shared/fonts/dm-sans/OFL.txt`)
- Source: https://github.com/googlefonts/dm-fonts/tree/4412393b7d2de9fe7a92064c2dce9b5af5d7fd26/Sans/fonts/ttf
- Notice:

  ```text
  Copyright 2014 The DM Sans Project Authors (https://github.com/googlefonts/dm-fonts)
  ```

### DM Serif Display

- Files: `dm-serif-display/DMSerifDisplay-Italic.ttf`
- Licence: SIL Open Font License 1.1 (`shared/fonts/dm-serif-display/OFL.txt`)
- Source: https://github.com/google/fonts/tree/5bdc59521ab95d387c82a1543277fddab4aa7a8b/ofl/dmserifdisplay
- Notice:

  ```text
  Copyright 2014-2018 Adobe (http://www.adobe.com/), with Reserved Font Name 'Source'. All Rights Reserved. Source is a trademark of Adobe in the United States and/or other countries. Copyright 2019 Google LLC.
  ```

### JetBrains Mono

- Files: `jetbrains-mono/JetBrainsMono-SemiBold.ttf`
- Licence: SIL Open Font License 1.1 (`shared/fonts/jetbrains-mono/OFL.txt`)
- Source: https://github.com/JetBrains/JetBrainsMono/tree/02bb50b082dad9ef8a0f33ac393839202b760223/fonts/ttf
- Notice:

  ```text
  Copyright 2020 The JetBrains Mono Project Authors (https://github.com/JetBrains/JetBrainsMono)
  ```

### Montserrat

- Files: `montserrat/Montserrat-Black.ttf`, `montserrat/Montserrat-ExtraBold.ttf`
- Licence: SIL Open Font License 1.1 (`shared/fonts/montserrat/OFL.txt`)
- Source: https://github.com/JulietaUla/Montserrat/tree/679ead9bcd0d6cef6d3712369dc49fe72e8bd8d7/fonts/ttf
- Notice:

  ```text
  Copyright 2024 The Montserrat.Git Project Authors (https://github.com/JulietaUla/Montserrat.git)
  ```

### Noto Sans

- Files: `noto-sans/NotoSans-Black.ttf`, `noto-sans/NotoSans-Bold.ttf`, `noto-sans/NotoSans-Regular.ttf`, `noto-sans/NotoSans-SemiBold.ttf`
- Licence: SIL Open Font License 1.1 (`shared/fonts/noto-sans/OFL.txt`)
- Source: https://github.com/notofonts/notofonts.github.io/tree/28b15b4b43b7bed62b5cf6e6b0b5ff5846270535/fonts/NotoSans/unhinted/ttf
- Notice:

  ```text
  Copyright 2022 The Noto Project Authors (https://github.com/notofonts/)
  ```

### Paytone One

- Files: `paytone-one/PaytoneOne-Regular.ttf`
- Licence: SIL Open Font License 1.1 (`shared/fonts/paytone-one/OFL.txt`)
- Source: https://github.com/google/fonts/tree/579c9b51ec0203ed051b6165e314b97b409fbbae/ofl/paytoneone
- Notice:

  ```text
  Copyright 2011 The Paytone Project Authors (https://github.com/googlefonts/paytoneFont),
  with Reserved Font Names "Paytone" and "Paytone One".
  ```

### Poppins

- Files: `poppins/Poppins-Black.ttf`, `poppins/Poppins-Bold.ttf`, `poppins/Poppins-ExtraBold.ttf`
- Licence: SIL Open Font License 1.1 (`shared/fonts/poppins/OFL.txt`)
- Source: https://github.com/google/fonts/tree/7dc16b7de42db624b902f2292b68ed9e489e5053/ofl/poppins
- Notice:

  ```text
  Copyright 2020 The Poppins Project Authors (https://github.com/itfoundry/Poppins)
  ```

### Righteous

- Files: `righteous/Righteous-Regular.ttf`
- Licence: SIL Open Font License 1.1 (`shared/fonts/righteous/OFL.txt`)
- Source: https://github.com/google/fonts/tree/90abd17b4f97671435798b6147b698aa9087612f/ofl/righteous
- Notice:

  ```text
  Copyright (c) 2011 by Brian J. Bonislawsky DBA Astigmatic (AOETI)
  (astigma@astigmatic.com), with Reserved Font Names "Righteous"
  ```

### Sora

- Files: `sora/Sora-ExtraBold.ttf`
- Licence: SIL Open Font License 1.1 (`shared/fonts/sora/OFL.txt`)
- Source: https://github.com/sora-xor/sora-font/tree/345772cfcc247cdb5c54f2f3b51d908799fc5538/fonts/ttf
- Notice:

  ```text
  Copyright 2019 The Sora Project Authors (https://github.com/sora-xor/sora-font)
  ```

### VT323

- Files: `vt323/VT323-Regular.ttf`
- Licence: SIL Open Font License 1.1 (`shared/fonts/vt323/OFL.txt`)
- Source: https://github.com/google/fonts/tree/eb8781e516576b414603df8cd267c0f21c9b4ee2/ofl/vt323
- Notice:

  ```text
  Copyright 2011, The VT323 Project Authors (peter.hull@oikoi.com)
  ```

### Noto Emoji (images)

- Files: `noto-emoji/png128/emoji_u*.png` (50 images, unmodified)
- Licence: Apache License 2.0 (`shared/fonts/noto-emoji/LICENSE`)
- Source: https://github.com/googlefonts/noto-emoji/tree/41e31b110b4eb929dffb410264694a06205b7ad7/png/128 (the last commit before the repository's root licence file changed to OFL-1.1; at this commit the README states that the image resources are under the Apache license)
- Notice:

  ```text
  Copyright 2013 Google Inc.
  ```

### SIL Open Font License 1.1

The following licence applies to every font family listed above, with the copyright and Reserved Font Name notices given for each family.

```text
This Font Software is licensed under the SIL Open Font License, Version 1.1.
This license is copied below, and is also available with a FAQ at:
http://scripts.sil.org/OFL


-----------------------------------------------------------
SIL OPEN FONT LICENSE Version 1.1 - 26 February 2007
-----------------------------------------------------------

PREAMBLE
The goals of the Open Font License (OFL) are to stimulate worldwide
development of collaborative font projects, to support the font creation
efforts of academic and linguistic communities, and to provide a free and
open framework in which fonts may be shared and improved in partnership
with others.

The OFL allows the licensed fonts to be used, studied, modified and
redistributed freely as long as they are not sold by themselves. The
fonts, including any derivative works, can be bundled, embedded, 
redistributed and/or sold with any software provided that any reserved
names are not used by derivative works. The fonts and derivatives,
however, cannot be released under any other type of license. The
requirement for fonts to remain under this license does not apply
to any document created using the fonts or their derivatives.

DEFINITIONS
"Font Software" refers to the set of files released by the Copyright
Holder(s) under this license and clearly marked as such. This may
include source files, build scripts and documentation.

"Reserved Font Name" refers to any names specified as such after the
copyright statement(s).

"Original Version" refers to the collection of Font Software components as
distributed by the Copyright Holder(s).

"Modified Version" refers to any derivative made by adding to, deleting,
or substituting -- in part or in whole -- any of the components of the
Original Version, by changing formats or by porting the Font Software to a
new environment.

"Author" refers to any designer, engineer, programmer, technical
writer or other person who contributed to the Font Software.

PERMISSION & CONDITIONS
Permission is hereby granted, free of charge, to any person obtaining
a copy of the Font Software, to use, study, copy, merge, embed, modify,
redistribute, and sell modified and unmodified copies of the Font
Software, subject to the following conditions:

1) Neither the Font Software nor any of its individual components,
in Original or Modified Versions, may be sold by itself.

2) Original or Modified Versions of the Font Software may be bundled,
redistributed and/or sold with any software, provided that each copy
contains the above copyright notice and this license. These can be
included either as stand-alone text files, human-readable headers or
in the appropriate machine-readable metadata fields within text or
binary files as long as those fields can be easily viewed by the user.

3) No Modified Version of the Font Software may use the Reserved Font
Name(s) unless explicit written permission is granted by the corresponding
Copyright Holder. This restriction only applies to the primary font name as
presented to the users.

4) The name(s) of the Copyright Holder(s) or the Author(s) of the Font
Software shall not be used to promote, endorse or advertise any
Modified Version, except to acknowledge the contribution(s) of the
Copyright Holder(s) and the Author(s) or with their explicit written
permission.

5) The Font Software, modified or unmodified, in part or in whole,
must be distributed entirely under this license, and must not be
distributed under any other license. The requirement for fonts to
remain under this license does not apply to any document created
using the Font Software.

TERMINATION
This license becomes null and void if any of the above conditions are
not met.

DISCLAIMER
THE FONT SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND,
EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO ANY WARRANTIES OF
MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT
OF COPYRIGHT, PATENT, TRADEMARK, OR OTHER RIGHT. IN NO EVENT SHALL THE
COPYRIGHT HOLDER BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY,
INCLUDING ANY GENERAL, SPECIAL, INDIRECT, INCIDENTAL, OR CONSEQUENTIAL
DAMAGES, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING
FROM, OUT OF THE USE OR INABILITY TO USE THE FONT SOFTWARE OR FROM
OTHER DEALINGS IN THE FONT SOFTWARE.
```

### Apache License 2.0

The following licence applies to the Noto Emoji images and to swift-argument-parser (macOS).

```text
Apache License
                           Version 2.0, January 2004
                        http://www.apache.org/licenses/

   TERMS AND CONDITIONS FOR USE, REPRODUCTION, AND DISTRIBUTION

   1. Definitions.

      "License" shall mean the terms and conditions for use, reproduction,
      and distribution as defined by Sections 1 through 9 of this document.

      "Licensor" shall mean the copyright owner or entity authorized by
      the copyright owner that is granting the License.

      "Legal Entity" shall mean the union of the acting entity and all
      other entities that control, are controlled by, or are under common
      control with that entity. For the purposes of this definition,
      "control" means (i) the power, direct or indirect, to cause the
      direction or management of such entity, whether by contract or
      otherwise, or (ii) ownership of fifty percent (50%) or more of the
      outstanding shares, or (iii) beneficial ownership of such entity.

      "You" (or "Your") shall mean an individual or Legal Entity
      exercising permissions granted by this License.

      "Source" form shall mean the preferred form for making modifications,
      including but not limited to software source code, documentation
      source, and configuration files.

      "Object" form shall mean any form resulting from mechanical
      transformation or translation of a Source form, including but
      not limited to compiled object code, generated documentation,
      and conversions to other media types.

      "Work" shall mean the work of authorship, whether in Source or
      Object form, made available under the License, as indicated by a
      copyright notice that is included in or attached to the work
      (an example is provided in the Appendix below).

      "Derivative Works" shall mean any work, whether in Source or Object
      form, that is based on (or derived from) the Work and for which the
      editorial revisions, annotations, elaborations, or other modifications
      represent, as a whole, an original work of authorship. For the purposes
      of this License, Derivative Works shall not include works that remain
      separable from, or merely link (or bind by name) to the interfaces of,
      the Work and Derivative Works thereof.

      "Contribution" shall mean any work of authorship, including
      the original version of the Work and any modifications or additions
      to that Work or Derivative Works thereof, that is intentionally
      submitted to Licensor for inclusion in the Work by the copyright owner
      or by an individual or Legal Entity authorized to submit on behalf of
      the copyright owner. For the purposes of this definition, "submitted"
      means any form of electronic, verbal, or written communication sent
      to the Licensor or its representatives, including but not limited to
      communication on electronic mailing lists, source code control systems,
      and issue tracking systems that are managed by, or on behalf of, the
      Licensor for the purpose of discussing and improving the Work, but
      excluding communication that is conspicuously marked or otherwise
      designated in writing by the copyright owner as "Not a Contribution."

      "Contributor" shall mean Licensor and any individual or Legal Entity
      on behalf of whom a Contribution has been received by Licensor and
      subsequently incorporated within the Work.

   2. Grant of Copyright License. Subject to the terms and conditions of
      this License, each Contributor hereby grants to You a perpetual,
      worldwide, non-exclusive, no-charge, royalty-free, irrevocable
      copyright license to reproduce, prepare Derivative Works of,
      publicly display, publicly perform, sublicense, and distribute the
      Work and such Derivative Works in Source or Object form.

   3. Grant of Patent License. Subject to the terms and conditions of
      this License, each Contributor hereby grants to You a perpetual,
      worldwide, non-exclusive, no-charge, royalty-free, irrevocable
      (except as stated in this section) patent license to make, have made,
      use, offer to sell, sell, import, and otherwise transfer the Work,
      where such license applies only to those patent claims licensable
      by such Contributor that are necessarily infringed by their
      Contribution(s) alone or by combination of their Contribution(s)
      with the Work to which such Contribution(s) was submitted. If You
      institute patent litigation against any entity (including a
      cross-claim or counterclaim in a lawsuit) alleging that the Work
      or a Contribution incorporated within the Work constitutes direct
      or contributory patent infringement, then any patent licenses
      granted to You under this License for that Work shall terminate
      as of the date such litigation is filed.

   4. Redistribution. You may reproduce and distribute copies of the
      Work or Derivative Works thereof in any medium, with or without
      modifications, and in Source or Object form, provided that You
      meet the following conditions:

      (a) You must give any other recipients of the Work or
          Derivative Works a copy of this License; and

      (b) You must cause any modified files to carry prominent notices
          stating that You changed the files; and

      (c) You must retain, in the Source form of any Derivative Works
          that You distribute, all copyright, patent, trademark, and
          attribution notices from the Source form of the Work,
          excluding those notices that do not pertain to any part of
          the Derivative Works; and

      (d) If the Work includes a "NOTICE" text file as part of its
          distribution, then any Derivative Works that You distribute must
          include a readable copy of the attribution notices contained
          within such NOTICE file, excluding those notices that do not
          pertain to any part of the Derivative Works, in at least one
          of the following places: within a NOTICE text file distributed
          as part of the Derivative Works; within the Source form or
          documentation, if provided along with the Derivative Works; or,
          within a display generated by the Derivative Works, if and
          wherever such third-party notices normally appear. The contents
          of the NOTICE file are for informational purposes only and
          do not modify the License. You may add Your own attribution
          notices within Derivative Works that You distribute, alongside
          or as an addendum to the NOTICE text from the Work, provided
          that such additional attribution notices cannot be construed
          as modifying the License.

      You may add Your own copyright statement to Your modifications and
      may provide additional or different license terms and conditions
      for use, reproduction, or distribution of Your modifications, or
      for any such Derivative Works as a whole, provided Your use,
      reproduction, and distribution of the Work otherwise complies with
      the conditions stated in this License.

   5. Submission of Contributions. Unless You explicitly state otherwise,
      any Contribution intentionally submitted for inclusion in the Work
      by You to the Licensor shall be under the terms and conditions of
      this License, without any additional terms or conditions.
      Notwithstanding the above, nothing herein shall supersede or modify
      the terms of any separate license agreement you may have executed
      with Licensor regarding such Contributions.

   6. Trademarks. This License does not grant permission to use the trade
      names, trademarks, service marks, or product names of the Licensor,
      except as required for reasonable and customary use in describing the
      origin of the Work and reproducing the content of the NOTICE file.

   7. Disclaimer of Warranty. Unless required by applicable law or
      agreed to in writing, Licensor provides the Work (and each
      Contributor provides its Contributions) on an "AS IS" BASIS,
      WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or
      implied, including, without limitation, any warranties or conditions
      of TITLE, NON-INFRINGEMENT, MERCHANTABILITY, or FITNESS FOR A
      PARTICULAR PURPOSE. You are solely responsible for determining the
      appropriateness of using or redistributing the Work and assume any
      risks associated with Your exercise of permissions under this License.

   8. Limitation of Liability. In no event and under no legal theory,
      whether in tort (including negligence), contract, or otherwise,
      unless required by applicable law (such as deliberate and grossly
      negligent acts) or agreed to in writing, shall any Contributor be
      liable to You for damages, including any direct, indirect, special,
      incidental, or consequential damages of any character arising as a
      result of this License or out of the use or inability to use the
      Work (including but not limited to damages for loss of goodwill,
      work stoppage, computer failure or malfunction, or any and all
      other commercial damages or losses), even if such Contributor
      has been advised of the possibility of such damages.

   9. Accepting Warranty or Additional Liability. While redistributing
      the Work or Derivative Works thereof, You may choose to offer,
      and charge a fee for, acceptance of support, warranty, indemnity,
      or other liability obligations and/or rights consistent with this
      License. However, in accepting such obligations, You may act only
      on Your own behalf and on Your sole responsibility, not on behalf
      of any other Contributor, and only if You agree to indemnify,
      defend, and hold each Contributor harmless for any liability
      incurred by, or claims asserted against, such Contributor by reason
      of your accepting any such warranty or additional liability.

   END OF TERMS AND CONDITIONS

   APPENDIX: How to apply the Apache License to your work.

      To apply the Apache License to your work, attach the following
      boilerplate notice, with the fields enclosed by brackets "[]"
      replaced with your own identifying information. (Don't include
      the brackets!)  The text should be enclosed in the appropriate
      comment syntax for the file format. We also recommend that a
      file or class name and description of purpose be included on the
      same "printed page" as the copyright notice for easier
      identification within third-party archives.

   Copyright [yyyy] [name of copyright owner]

   Licensed under the Apache License, Version 2.0 (the "License");
   you may not use this file except in compliance with the License.
   You may obtain a copy of the License at

       http://www.apache.org/licenses/LICENSE-2.0

   Unless required by applicable law or agreed to in writing, software
   distributed under the License is distributed on an "AS IS" BASIS,
   WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
   See the License for the specific language governing permissions and
   limitations under the License.
```

## Data

### Unicode Character Database

- Files: `shared/caption-styles/casemap.json`, derived from `UnicodeData.txt` 16.0.0 (simple case mappings) by `tools/captions/build_casemap.py`; shipped with both apps.
- Licence: Unicode License v3 (SPDX `Unicode-3.0`)
- Source: https://www.unicode.org/Public/16.0.0/ucd/UnicodeData.txt
- Notice:

```text
UNICODE LICENSE V3

COPYRIGHT AND PERMISSION NOTICE

Copyright © 1991-2024 Unicode, Inc.

NOTICE TO USER: Carefully read the following legal agreement. BY
DOWNLOADING, INSTALLING, COPYING OR OTHERWISE USING DATA FILES, AND/OR
SOFTWARE, YOU UNEQUIVOCALLY ACCEPT, AND AGREE TO BE BOUND BY, ALL OF THE
TERMS AND CONDITIONS OF THIS AGREEMENT. IF YOU DO NOT AGREE, DO NOT
DOWNLOAD, INSTALL, COPY, DISTRIBUTE OR USE THE DATA FILES OR SOFTWARE.

Permission is hereby granted, free of charge, to any person obtaining a
copy of data files and any associated documentation (the "Data Files") or
software and any associated documentation (the "Software") to deal in the
Data Files or Software without restriction, including without limitation
the rights to use, copy, modify, merge, publish, distribute, and/or sell
copies of the Data Files or Software, and to permit persons to whom the
Data Files or Software are furnished to do so, provided that either (a)
this copyright and permission notice appear with all copies of the Data
Files or Software, or (b) this copyright and permission notice appear in
associated Documentation.

THE DATA FILES AND SOFTWARE ARE PROVIDED "AS IS", WITHOUT WARRANTY OF ANY
KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF
MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT OF
THIRD PARTY RIGHTS.

IN NO EVENT SHALL THE COPYRIGHT HOLDER OR HOLDERS INCLUDED IN THIS NOTICE
BE LIABLE FOR ANY CLAIM, OR ANY SPECIAL INDIRECT OR CONSEQUENTIAL DAMAGES,
OR ANY DAMAGES WHATSOEVER RESULTING FROM LOSS OF USE, DATA OR PROFITS,
WHETHER IN AN ACTION OF CONTRACT, NEGLIGENCE OR OTHER TORTIOUS ACTION,
ARISING OUT OF OR IN CONNECTION WITH THE USE OR PERFORMANCE OF THE DATA
FILES OR SOFTWARE.

Except as contained in this notice, the name of a copyright holder shall
not be used in advertising or otherwise to promote the sale, use or other
dealings in these Data Files or Software without prior written
authorization of the copyright holder.
```

## Application components

Libraries linked into or shipped with the apps. The version of each is pinned in `apps/macos/Package.resolved` / `Package.swift` or `apps/windows/Directory.Packages.props` and `apps/windows/build/ffmpeg.json`. The track that pins or first ships a component (doc/plan.md) adds its full licence text and copyright lines below, copied from the pinned package, before the first release that contains it (doc/release.md section 4 step 3b). Identifiers marked "confirm" are to be checked against the pinned package's own licence file.

### macOS

| Component | Use | Licence |
|---|---|---|
| whisper.cpp / ggml (xcframework, release b5454) | on-device transcription | MIT (The ggml authors) |
| swift-argument-parser | `voxclip-cli` argument parsing | Apache-2.0 (text above) |

### Windows

| Component | Use | Licence |
|---|---|---|
| .NET runtime (self-contained) | runtime | MIT (.NET Foundation and contributors) |
| Windows App SDK runtime (self-contained) | WinUI 3 | Microsoft license terms shipped in the package (confirm redistribution notice) |
| CommunityToolkit.Mvvm, CommunityToolkit.WinUI.Controls.SettingsControls | view models, settings rows | MIT (.NET Foundation and contributors) |
| SkiaSharp and HarfBuzzSharp (with their native libSkiaSharp and libHarfBuzzSharp) | caption rendering and shaping | MIT (Microsoft); the natives embed Skia (BSD-3-Clause, Google) and HarfBuzz (MIT-style "Old MIT"), confirm |
| Whisper.net and its runtimes (whisper.cpp / ggml natives) | on-device transcription | MIT |
| NAudio.Wasapi | audio output | MIT (Mark Heath and contributors) |
| Velopack | installer and updates | MIT |
| System.CommandLine | `voxclip-cli.exe` argument parsing | MIT (.NET Foundation and contributors) |
| FFmpeg.AutoGen | FFmpeg bindings | LGPL-3.0, confirm; dynamically linked managed assembly, source at the pinned tag of github.com/Ruslan-B/FFmpeg.AutoGen |
| FFmpeg (BtbN LGPL shared build: avcodec, avformat, avutil, swresample, swscale, avfilter) | decode, encode, mux | LGPL-2.1-or-later (or LGPLv3 when the pinned build says so); `licenses\FFmpeg-LICENSE.txt` and `licenses\FFmpeg-BUILD.txt` in the install folder; corresponding source in the release asset `VoxClip-win-ffmpeg-source.tar.xz` (doc/architecture.md section 6.1) |

## Models

Transcription models are downloaded from their publishers only when the user asks, after a confirmation that names the publisher and licence, and are never bundled. Their licence, attribution and citation come from `shared/catalog/transcription-models.json` and are shown in About → Licences for every installed model (doc/spec/transcription.md section 12.4). All v1 models are MIT: the TalTech Estonian Whisper fine-tune and its GGML conversions, OpenAI Whisper large-v3-turbo, small.en and base.en GGML files, and Silero VAD.
