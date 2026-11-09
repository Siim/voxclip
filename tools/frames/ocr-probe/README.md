# Windows OCR probe (ADR-R48 Windows, W4's native check)

W4 owes a native check of Windows OCR on phone screens: whether `WindowsFrameText` returns line boxes, how `FrameScreenScan`
judges them, and how fast it is at 1,280 px. `Windows.Media.Ocr` needs the App's Windows target framework, and every test
project is portable `net10.0`, so there is no `RequiresWindows` xUnit test for it. This console tool runs the App's own
`WindowsFrameText.cs` (linked, not copied) with Core's `QuadFinder` and `FrameScreenScan`. It is a developer tool: not part
of the solution, and it never ships.

| File | What it is |
| --- | --- |
| `OcrProbe.csproj`, `Program.cs` | The probe (`voxclip-ocr-probe`). |
| `render_text_frames.py` | Three 1,280 × 720 phone frames with real rendered text (5 lines at 22 px, 7 at 16 px, 3 at 24 px turned 3°), as PNGs. |

## Run it

On the Mac (Pillow, the system Helvetica):

```sh
python3 -I tools/frames/ocr-probe/render_text_frames.py /tmp/voxclip-ocr-frames
```

Copy the PNG folder and the source to the Windows PC, then from the repo root there:

```powershell
dotnet build tools/frames/ocr-probe/OcrProbe.csproj -c Release -r win-arm64 -m:1 -nodeReuse:false -p:UseSharedCompilation=false
tools/frames/ocr-probe/bin/Release/net10.0-windows10.0.26100.0/win-arm64/voxclip-ocr-probe.exe shared C:\path\to\ocr-frames 20
```

(`-r win-x64` on an x64 PC.) On the Mac it compiles with `-p:EnableWindowsTargeting=true`, but it runs only on Windows.

## What it prints

- The OCR languages installed (`OcrEngine.AvailableRecognizerLanguages`) and the user-profile engine's language.
  With none installed, `WindowsFrameText` finds no text, and so no screen.
- For `frame-quad-cases.json`'s `phone-upright`, `phone-tilted` and `laptop` frames (words drawn as bars: OCR is expected to
  find no lines there) and for each rendered PNG:
  - the line boxes, the quads and the screens with and without the quads;
  - what `ScanAsync` returns;
  - the median, minimum and maximum OCR time and the median `QuadFinder` time over the runs, after three warm-up runs.

It prints rects and times only, never the recognised text.
