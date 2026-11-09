# Face golden images (Windows face models, ADR-R48 Windows)

The Windows face path (`OnnxFrameFaces`: YuNet, the rotated crop and Face Mesh V2 on ONNX Runtime 1.19.2) is pinned on these
images, within tolerance, by `apps/windows/tests/VoxClip.Media.Tests/Frames/OnnxFrameFacesTests.cs`. They are test fixtures
only: the apps never ship them.

Each photograph is a self-portrait that the person in it dedicated to the public domain on Wikimedia Commons, either with
`{{PD-self}}` or with `{{self|Cc-zero}}` (CC0 1.0). No agency, celebrity or user footage is used. Each file was downloaded
in full (its Commons SHA-1 checked), turned upright by its EXIF orientation, converted to 8-bit RGB and scaled with Lanczos
so its long side is at most 640 px, then saved as PNG (lossless, so every platform decodes the same pixels).

| File | Source (file page) | Author (the person photographed) | Licence | Changes |
|---|---|---|---|---|
| `kaminix.png` (458 × 387) | https://commons.wikimedia.org/wiki/File:Kaminix_2010-12-09.jpg | Kaminix (Commons user Kaminix), "Self-portrait", own work, 2010-12-09 | Public domain (`{{PD-self}}`) | none beyond PNG |
| `saurabh.png` (399 × 640) | https://commons.wikimedia.org/wiki/File:SaurabhMehta.jpg | Saurabh Mehta (Commons user MehtaSaurabh), "Clicked by Saurabh Mehta himself", own work, 2011-12-06 | Public domain (`{{PD-self}}`) | cropped to x 560–1333, y 0–1240 of the 1333 × 1365 original, which removes a bystander in the background, then scaled |
| `amblard.png` (460 × 640) | https://commons.wikimedia.org/wiki/File:Olivier.amblard.JPG | Olivier Amblard (Commons user Olivieram), "Autoportrait", 2004-01-14 | CC0 1.0 (`{{self\|Cc-zero}}`) | scaled |
| `parham.png` (429 × 640) | https://commons.wikimedia.org/wiki/File:ReidParham_bwPortrait.jpg | Reid Parham (Commons user Parhamr), "Self-portrait", own work, 2005-08 | Public domain (`{{PD-self}}`) | scaled; the black-and-white original stored as RGB |
| `kaminix-blurred.png` (458 × 387) | derived from `kaminix.png` above | Kaminix | Public domain (`{{PD-self}}`) | Gaussian blur, radius 8 (Pillow `GaussianBlur(8)`): YuNet still finds a box (score 0.83) but Face Mesh V2 says no face (presence logit −7.1), so it is not counted |
| `no-face.png` (640 × 360) | made for VoxClip | VoxClip | CC0 1.0 | synthetic: colour gradients, a framed panel of text bars, a disc and stripes; no face |

Commons notes: `ReidParham_bwPortrait.jpg` carries the `{{personality rights}}` reminder, as photographs of identifiable
people do. These images are used only as test inputs to check that a face is measured the same way on every platform.
