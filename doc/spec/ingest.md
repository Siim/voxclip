# Wireless ingest

Status: normative design for **M2**. Section 3.1 lists the one M1 item (camera file compatibility tests). Sections 6 to 18 are implementer-ready; parts of section 9 (live clipping) are scheduled for M2.x (section 9.14). Anything marked **[HW]** depends on a hardware test in section 19 and must not be advertised as "works with Osmo Pocket 4" until that test passes. Written 2026-10-25.

This spec covers how footage from a DJI Osmo Pocket 4 (and any other camera or phone app that streams RTMP) gets into VoxClip without a cable. It covers:

- what the camera can and cannot do;
- the chosen paths: live receive over RTMP / Enhanced RTMP, a phone upload page reached by QR code, a watched camera inbox, and wired fallbacks;
- live clipping while the camera streams: "clip that" triggers, an optional rolling AI clip finder, and clips rendered before the stream ends;
- protocol details, type sketches, UX states and exact copy;
- security rules, macOS and Windows network permissions, and the Info.plist and installer changes they need;
- milestone placement and an automated test plan built on locally generated FFmpeg RTMP streams.

Related documents:

| Topic | Owner |
|---|---|
| Module boundaries, data locations, concurrency, CLI, error codes, logging, secrets | `doc/architecture.md` (wins on placement, paths, threading, CLI flags and error codes) |
| Window layouts, the Record view, state copy style, tokens | `doc/design.md` |
| Project file, source references, `contentKey` | `doc/spec/editing.md`, `shared/schemas/project.schema.json` |
| Transcription of the finished take | `doc/spec/transcription.md` |
| Connectors, the clip finder pipeline, `finalizeClips`, presets (reused by live clipping, section 9) | `doc/spec/ai.md`, `shared/prompts/clip-finder.json` |
| Clip range layer, edit plan, time mapping (live drafts and project clips, section 9) | `doc/spec/editing.md` |
| Caption styles and rendering (live drafts) | `doc/spec/captions.md` |
| Share helpers and publishing (never automatic for live clips) | `doc/publishing.md` |
| Locked decisions (ADR-007 entitlements, ADR-011/015 Windows packaging, ADR-027 milestones) | `doc/decisions.md` |
| Signing, Info.plist, bundle contents, Windows release | `doc/release.md` |

Key words: **must**, **must not**, **should** and **may** are used in their RFC 2119 sense. Constants in section 5 are part of the contract. If an implementation needs a different value, change this document in the same commit.

Provenance: the planning reports `osmo-device.md` (camera side, date-checked 2026-10-25) and `osmo-receiver.md` (receiver side, with prototypes measured on macOS 27.0.1 with FFmpeg 6.1.1 as the test publisher). Implementers do not need to read them. Facts are cited inline with URLs; all were accessed on 2026-10-25. "Measured" means a result from those prototypes.

---

## 1. Summary

### 1.1 The ask

"Pro bonus if we find a way to stream Osmo Pocket 4 from local WiFi wirelessly, also just upload it to VoxClip for processing."

Both halves are possible without extra hardware, with limits:

- **Stream.** DJI Mimo configures the camera over Bluetooth; the camera then joins the Wi-Fi and pushes RTMP itself to any address, including a LAN address. On the Pocket 4 the stream is HEVC in Enhanced RTMP, at most 1080p30 and 6 Mbps. VoxClip can receive and record it.
- **Upload.** The phone can send files over the LAN to VoxClip through a web page opened from a QR code. In addition, the Pocket 4's official Camera Cloud Service can upload files from the camera to an SMB share with no phone involved; VoxClip can watch that folder **[HW]**.

The follow-up idea: "it can make clips continuously from live stream once something cool is captured". This is possible too (section 9): the take is readable while it is written, so clips render during the stream; a spoken "clip that", a shortcut or a phone button marks the moment, and an optional AI check of the live transcript proposes strong moments. Clips are only ever proposed, never posted.

### 1.2 Recommended v1 path (M2)

1. **Receive from camera**: a built-in, LAN-only RTMP / Enhanced-RTMP receiver written for VoxClip on both platforms. It records the stream to disk as it arrives (video passed through untouched, audio decoded to PCM), shows a live preview, and when the take ends opens it as a normal project and transcribes it with the user's engine. Works with the Pocket 4 (HEVC), the Pocket 3 (H.264) and any RTMP app (OBS, Larix, Moblin).
2. **Send from your phone**: a QR code opens a small page served by VoxClip on the LAN. The page uploads chosen videos with resumable chunks (a tus 1.0 subset).
3. **Import from a connected camera**: USB or microSD import with a "DJI camera connected" prompt. This is the wired fallback and the fastest path for 4K originals.
4. **Camera inbox**: a watched folder. It is generic (AirDrop, iCloud Drive, OneDrive and sync folders all work). The DJI Camera Cloud Service setup guide is shown only after hardware test H8 passes.
5. **Clips while you stream** (section 9): press **Clip that** (⌘K / Ctrl+K), a global shortcut or the phone page's button, or say "clip that" when a live transcript runs, and the last 45 seconds, snapped back to a sentence or a pause, render with captions into a "Clips from this stream" tray while the camera keeps streaming. In M2.x, **AI watching** checks the live transcript about once a minute with the user's API-key or local model and proposes strong, finished moments, within a per-stream budget; it is off until the user turns it on for each stream. Nothing is posted or uploaded automatically.

Not in v1: SRT (no Pocket camera speaks it), phone-free Bluetooth control of the camera, offload from the camera's own Wi-Fi access point, DisplayPort capture, Bonjour discovery, HTTPS on the LAN (section 21).

### 1.3 Non-goals

- Replacing the in-camera file. The live stream is at most 1080p30 and 6 Mbps; the camera's own recording is 4K HEVC at up to 180 Mbps ([DJI Pocket 4 specs](https://www.dji.com/global/osmo-pocket-4/specs)). Live receive is for "it is already in VoxClip when I stop talking", not for final masters.
- Streaming out, restreaming, or playing streams to other clients. VoxClip only receives.
- Any traffic leaving the local network. Nothing in the ingest paths talks to the internet. The one exception in this spec is AI watching (section 9.5): when the user turns it on for a stream, the AI layer (ai.md) sends live transcript text, never audio or video, to the connector the user chose; with a local connector nothing leaves the machine. Clip transcription (section 9.4.4) runs the user's own transcription engine, so with ElevenLabs a clip's audio goes where the whole take goes when it ends, under the consent already given.
- Posting or uploading clips automatically. Live clips are proposals that wait for the user (section 9.9).

---

## 2. What the Osmo Pocket 4 can and cannot do (checked 2026-10-25)

### 2.1 Device facts that shape the design

| Fact | Source |
|---|---|
| Announced 2026-04-16, in stores 2026-04-22. Not officially sold in the US (DJI was added to the FCC Covered List on 2025-12-22), so many US users have a Pocket 3 | [CineD](https://www.cined.com/dji-osmo-pocket-4-announced-4k-240fps-activetrack-7-0-and-built-in-107gb-storage/), [Newsshooter](https://www.newsshooter.com/2026/04/16/dji-osmo-pocket-4-announced-but-not-available-in-the-us-due-to-pending-fcc-authorization/), [PetaPixel](https://petapixel.com/2026/04/16/the-dji-osmo-pocket-4-isnt-available-in-the-us-and-it-might-never-be/) |
| Latest firmware v01.04.12.16 (2026-10-14) | [DJI release notes PDF](https://terra-1-g.djicdn.com/6189933d30024fc1b331bffe4fe41837/osmo-pocket-4/RN/20261014/DJI_Osmo_Pocket_4_Release_Notes_en.pdf) |
| Records MP4 in **HEVC only** ("What video formats does Osmo Pocket 4 support? MP4 (HEVC)."), up to 4K/240 and 180 Mbps, 10-bit D-Log | [DJI Pocket 4 FAQ](https://www.dji.com/global/osmo-pocket-4/faq), [specs](https://www.dji.com/global/osmo-pocket-4/specs) |
| Audio 48 kHz AAC. With a DJI Mic linked, files carry **two audio tracks** (four channels): track 1 is the transmitter(s), track 2 the built-in stereo mics | [DJI Pocket 4 FAQ](https://www.dji.com/global/osmo-pocket-4/faq) |
| Wi-Fi 6 (2.4/5.1/5.8 GHz), BLE 5.4, USB-C 3.1 "up to 800 MB/s" | [specs](https://www.dji.com/global/osmo-pocket-4/specs), [FAQ](https://www.dji.com/global/osmo-pocket-4/faq) |
| Livestream through DJI Mimo: Facebook (not on Pocket 4), YouTube and RTMP. Pocket 4 presets: 480p at 1 or 2 Mbps, 720p at 2 or 4 Mbps, 1080p at 3 or 6 Mbps, all 30 fps | [DJI Mimo livestream guide](https://support.dji.com/help/content?customId=en-us03400006728&spaceId=34&re=US&lang=en) |
| **The camera joins the Wi-Fi itself and pushes RTMP**; the app only sends network, URL and start over BLE. A captured Mimo session writes `rtmp://192.168.0.131:1946/test/stream0/`, so a LAN IP, a custom port, a path and a trailing slash are all accepted | [Osmosis MEDIA_PROTOCOL.md](https://github.com/KonradIT/osmosis/blob/master/MEDIA_PROTOCOL.md), [djictl](https://github.com/xaionaro-go/djictl), [Upstream, 2026-10-06](https://upstream.so/integrations/dji/). One guide claims the phone relays the stream ([IRLServer](https://irlserver.com/guides/connect-dji-osmo-pocket)); the protocol captures contradict it, and the receiver design is the same either way |
| **Pocket 4 live video is HEVC carried in Enhanced RTMP.** H.264-only receivers (nginx-rtmp, older GStreamer, Twitch) show a black picture with working audio | [SRT Mini Server, 2026-09-25](https://srtminiserver.com/blog/dji-osmo-pocket-4-rtmp-hevc/) |
| Live audio is AAC (inferred: Moblin's receiver accepts only AAC and works with Pocket 3 and 4) | [Moblin RTMP server](https://github.com/eerimoq/moblin/tree/main/Moblin/Media/RtmpServer) |
| No SRT, no RTMPS. "Pocket cameras still do not offer SRT" | [SRT Mini Server](https://srtminiserver.com/blog/dji-osmo-pocket-4-rtmp-hevc/), [DJI Mimo livestream guide](https://support.dji.com/help/content?customId=en-us03400006728&spaceId=34&re=US&lang=en) |
| RTMP over Wi-Fi does not degrade; a stall ends the stream | [IRLServer](https://irlserver.com/guides/connect-dji-osmo-pocket), [StreamableRun, 2026-10-22](https://streamable.run/blog/dji-mimo-osmo-action-6-pocket-4-rtmp-streamablerun-setup) |
| **Camera Cloud Service** (fw v01.03.10.05, 2026-08-04): uploads camera files over Wi-Fi to Google Drive, OneDrive or "the user's own NAS". NAS means SMB: IP, a top-level share name, user and password. Uploads start by themselves when a saved Wi-Fi is in range and the camera is idle or off | [DJI release notes 2026-08-04](https://terra-1-g.djicdn.com/6189933d30024fc1b331bffe4fe41837/osmo-pocket-4/RN/20260804/DJI_Osmo_Pocket_4_Release_Notes_en.pdf), [Basic Tutorials, 2026-08-20](https://basic-tutorials.com/news/dji-osmo-pocket-4-and-4p-automatic-upload-to-the-cloud-and-nas-is-here/), [DroneXL (Action 6), 2026-01-12](https://dronexl.co/2026/01/12/dji-osmo-action-6-cloud-backup/) |
| Wi-Fi transfer to the phone in Mimo, up to 90 MB/s | [DJI Pocket 4 FAQ](https://www.dji.com/global/osmo-pocket-4/faq) |
| UVC webcam output 1080p, 4K and vertical at 24/25/30 fps, with internal recording at the same time | [DJI Pocket 4 FAQ](https://www.dji.com/global/osmo-pocket-4/faq), [DJI webcam guide](https://support.dji.com/help/content?customId=en-us03400006962&spaceId=34&re=US&lang=en) |
| USB mass storage: the camera mounts as a volume with `DCIM/DJI_001` | [DJI footage export guide](https://support.dji.com/help/content?customId=en-us03400006849&spaceId=34&re=US&lang=en) |
| Every wireless path needs a one-time activation through Mimo against DJI's servers | [Osmosis protocol map](https://github.com/KonradIT/osmosis/blob/master/docs/01-protocol-map.md) |
| No DJI desktop app or SDK transfers Osmo footage over Wi-Fi. DJI Studio is an Osmo 360 editor; LightCut is mobile-only and unmaintained since September 2026 | [DJI Studio](https://www.dji.com/downloads/softwares/dji-studio), [LightCut](https://www.dji.com/global/lightcut) |

### 2.2 Feasibility of each path

| Path | Feasible? | How it works | Limits |
|---|---|---|---|
| Live stream to VoxClip over the LAN | **Yes** | Mimo → Livestream → RTMP → paste VoxClip's `rtmp://` address. The camera connects to VoxClip | 1080p30 at most, 1–6 Mbps, HEVC, AAC. Camera, phone and computer on one Wi-Fi that lets clients see each other. Whether a network with no internet works is unknown **[HW H2]** |
| Phone → VoxClip file upload over the LAN | **Yes** | Files reach the phone through Mimo; the QR page uploads them to VoxClip | iPhone's photo picker may re-encode unless the user picks the original (section 10.8) |
| Camera → VoxClip with no phone (Camera Cloud Service → SMB) | **Probably** | VoxClip watches the folder that backs a macOS or Windows SMB share | Not confirmed with a plain Mac or Windows share; SMB dialect and encryption unknown **[HW H8]** |
| USB or microSD | **Yes** | The camera or card mounts as a volume | Wired |
| UVC webcam | **Yes** (as the M2 Recording feature) | The camera appears as a camera device | 30 fps at most; whether it carries audio is unknown **[HW H9]** |
| SRT | **No** | Not offered by any Pocket camera | — |
| Live stream above 1080p30 | **No** through Mimo | — | A Bluetooth controller may ask for more bitrate (Osmosis measured 10 Mbps on an Action 4); not in v1 |
| H.264 live from a Pocket 4 | **Not through Mimo** | Mimo has no codec choice. The Pocket 4 start command has a `codec` field (`AVC` or `HEVC`) that only a third-party controller can set ([Moblin DJI integration](https://github.com/eerimoq/moblin/tree/main/Moblin/Integrations/Dji)) | Not needed: VoxClip accepts HEVC |
| Start or stop the stream from VoxClip | **Not in v1** | Possible only through reverse-engineered Bluetooth control (section 21) | — |
| Pull files from the camera's own Wi-Fi access point | **Not in v1** | Reverse-engineered; takes the computer off its Wi-Fi (section 21) | — |

### 2.3 Other Osmo models

The receiver does not care which camera sends. The **Pocket 3** (the US baseline) streams H.264 in classic RTMP and has no Camera Cloud Service ([Pocket 3 release notes to 2025-08-26](https://dl.djicdn.com/downloads/DJI_Osmo_Pocket_3/RN/20250826/DJI_Osmo_Pocket_3_Release_Notes_en.pdf)). The Pocket 4P, Action 6 and Osmo 360 II have Camera Cloud Service; the Pocket 4P, Action 6, Action 5 Pro and Osmo 360 (single-lens mode only) livestream through Mimo; the Osmo Nano does not livestream ([DJI Mimo livestream guide](https://support.dji.com/help/content?customId=en-us03400006728&spaceId=34&re=US&lang=en)).

---

## 3. Chosen paths, milestones and decisions

### 3.1 Milestone placement

| # | Path | Milestone | Gate before release copy may name the Pocket 4 |
|---|---|---|---|
| 1 | **Camera file compatibility.** No new UI. M1 acceptance tests prove that a Pocket-4-like file (HEVC Main 10, two AAC tracks) opens, previews, transcribes the **first** audio track (the DJI Mic track) and exports. The transcription spec already extracts "the first enabled audio track" (transcription.md §4), so no behaviour change is needed | **M1** (trivially cheap: one synthetic fixture and two tests, section 18.9) | H12 |
| 2 | Import from a connected camera (USB, microSD) | M2 | none |
| 3 | Send from your phone (LAN page + QR) | M2 | H11 for the iPhone copy |
| 4 | Receive from camera (RTMP / Enhanced RTMP), record and preview, batch transcription at the end of the take | M2 | H1 to H5 |
| 5 | Live transcript in the Receive window | M2 only if the M2 Recording feature ships a live transcription engine; otherwise later. The Receive window then shows "Words appear when the take ends." | recording spec |
| 6 | Camera inbox (watched folder) | M2 | generic; the DJI setup guide needs H8 |
| 7 | Webcam (UVC) | M2, as part of Recording (design.md §12) | H9 |
| 8 | SRT, Bluetooth camera control, camera access-point offload, in-place original-file swap (live clips have their own path to the camera file, item 12) | not planned (section 21) | — |
| 9 | **"Clip that"** while live from the button, ⌘K / Ctrl+K, a global shortcut and the phone page; drafts rendered during the stream; the "Clips from this stream" tray; clips into the take's project (section 9) | M2, with item 4 | none for the feature (it works with any RTMP app); H14 before release copy quotes its speed |
| 10 | Voice "clip that" (section 9.4.2) | M2 with item 5; later if item 5 is later | recording spec |
| 11 | **AI watching** (the rolling clip finder) and Find clips now (section 9.5) | M2.x | needs item 5; H14 |
| 12 | Live clips onto the camera's own recording (section 9.8.2) | M2.x | H7 |

Inside M2, build in this order: the LAN helper server (section 10, needed by items 3, 4 and 9), then item 3, then item 4 together with item 9, then items 2 and 6. Items 4 and 9 are useful with any RTMP app even before the hardware tests pass. Section 9.14 gives the order inside item 9.

### 3.2 Rejected alternatives

| Alternative | Why not |
|---|---|
| FFmpeg's `-listen 1` RTMP server (Windows) | **Measured:** it records the stream even with a wrong stream key (only a warning), does a plain handshake only, serves one connection and exits, and writes `hev1`, which QuickTime refuses. A dev tool only |
| HaishinKit 2.2.5 (BSD-3, [releases](https://github.com/HaishinKit/HaishinKit.swift/releases)) | Client only (publish and play); no RTMP server |
| Moblin's RTMP server as a dependency ([MIT](https://github.com/eerimoq/moblin)) | Shaped as an iOS app module. It is the best **reference**; VoxClip writes its own. If any code is copied, keep Moblin's MIT notice in `THIRD_PARTY_NOTICES.md` |
| SwiftNIO | A large dependency for one TCP connection |
| Kestrel or `HttpListener` on Windows | `HttpListener` needs an admin URL ACL to bind a LAN address ([MS docs](https://learn.microsoft.com/en-us/dotnet/fundamentals/runtime-libraries/system-net-httplistener)). Kestrel would work but adds the ASP.NET Core framework to a self-contained app and gives Windows a different HTTP stack from macOS. Both apps instead share one small HTTP subset with a pure parser and shared fixtures (ING-5) |
| HTTPS with a self-signed certificate | iOS shows a full-page warning; worse than plain HTTP on a trusted LAN |
| Bonjour advertising | Needs the macOS Local Network permission ([TN3179](https://developer.apple.com/documentation/technotes/tn3179-understanding-local-network-privacy)) and Mimo cannot use it; the QR code and IP address are enough |
| MSIX manifest firewall rules | VoxClip is unpackaged (ADR-011) |
| AAC passthrough into the recording on macOS | **Measured:** with the bare AudioSpecificConfig as the cookie AVFoundation drops the audio track; with a proper ES_Descriptor it trims an assumed 2112-sample priming (about 44 ms) that FFmpeg does not ([TN2258](https://developer.apple.com/library/archive/technotes/tn2258/_index.html)) |

### 3.3 Decisions (to be copied into `doc/decisions.md` as refinements of ADR-027)

| ID | Decision | Rationale |
|---|---|---|
| ING-1 | **Own RTMP / Enhanced-RTMP receiver on both platforms.** The protocol is a sans-I/O state machine in Core `Domain/Ingest` (pure, fixture-tested); sockets and writers live in Media | Same behaviour on both platforms, testable from byte fixtures, no third-party server |
| ING-2 | **Record first.** Video is passed through untouched; audio is decoded and written as 16-bit PCM in a `.mov` on **both** platforms. When the take ends, the file opens as a normal project and batch transcription is the source of truth; live words are display-only and not saved | Sample-exact sync in both AVFoundation and FFmpeg readers (measured on macOS); gaps and overlaps can be filled with exact silence; one fixture expectation for both platforms. Windows deviates from the prototype (AAC passthrough), so test W-3 must confirm it (section 18.9) |
| ING-3 | **One persistent stream key per install** (80 bits), stored with the other secrets (Keychain / DPAPI account `ingest-rtmp-key`), changeable with **Reset address**. Upload and helper-page tokens are 128 bits, in memory only, one per session | A stable address lets users keep it in Mimo; the listener runs only while the user has the Receive window open |
| ING-4 | **Bind one private IPv4 interface address**; accept peers only from that interface's subnet. No `0.0.0.0`, no IPv6 listener, no Bonjour, no UPnP or NAT-PMP | Smallest exposure; matches the Windows Firewall "Local Subnet" recommendation |
| ING-5 | **Own HTTP/1.1 subset** for the LAN helper server on both platforms, with the request parser, router and upload state in Core | Tiny surface, identical status codes, fixture parity |
| ING-6 | Phone upload speaks a **tus 1.0 subset**; the page assets are static files in `shared/ingest/web/` | Resumable over flaky Wi-Fi (measured with curl and Chrome); no secrets inside the page |
| ING-7 | **Windows Firewall:** before the first LAN listen VoxClip checks the policy and, with the user's click, adds an inbound allow rule (TCP, Private profile, Local Subnet) through an elevated helper mode of `VoxClip.exe`. It never listens on a LAN address while the check fails, and never adds a Public rule | The per-user Velopack install cannot elevate; if Windows' own prompt is cancelled, or the user is not an admin, Windows creates block rules that beat any later allow rule ([Microsoft Learn](https://learn.microsoft.com/en-us/windows/security/operating-system-security/network-security/windows-firewall/rules)) |
| ING-8 | **macOS: no new entitlements** (ADR-007 stands). Info.plist gains `NSLocalNetworkUsageDescription` defensively; no `NSBonjourServices` | Listening for incoming TCP does not need the Local Network privilege (TN3179) and a non-sandboxed app needs no network entitlement |
| ING-9 | **One take = one file = one project.** A reconnect within 60 s continues the take and records a marker; a codec or parameter-set change starts a new take | The project format references exactly one source (`media.source`) |
| ING-10 | The **camera inbox** is a generic watched folder; the DJI Camera Cloud Service guide appears only after H8 passes | Useful today for AirDrop and sync folders; no unverified claims in the UI |
| ING-11 | **SRT, Bluetooth camera control and access-point offload are not in v1** | No Pocket speaks SRT; the others are reverse-engineered, fragile and need a legal review |
| ING-12 | Milestones as in section 3.1 | M1 stays the fast cutting loop |
| ING-13 | **Live clips are drafts.** "Clip that" and AI watching work on final live words and the sealed part of the take, and drafts render during the stream. A live clip is stored by take time and becomes a clip range of the take's project, re-anchored to the batch transcript, when the take ends. Live words are never saved (ING-2 stands) | Clips before the stream ends without weakening "batch transcription is the source of truth"; no project-format change in M2 |
| ING-14 | **Nothing is posted automatically, and AI watching is opt-in per stream.** AI watching is off at the start of every stream, uses API-key, local or on-device connectors only (CLI connectors run only on **Find clips now**, ai.md §7.1 rule 5), stops at a per-stream budget and shows "AI watching" while on. "Clip that" is on by default and needs no LLM | Cost, privacy and subscription compliance; the user decides what is published |
| ING-15 | **Live clipping reuses the clip-finder presets unchanged.** There is no live preset; the live rules (stricter score, settled end, dedupe, hourly cap) are deterministic post-processing | One prompt file, one request parity test, VoxConvo provenance intact |

---

## 4. Architecture

### 4.1 Components

```text
 camera / RTMP app ──TCP──▶ RTMPListener (Media) ──bytes──▶ RTMPServerProtocol (Core, sans-I/O) ──events──▶ IngestSession (Media)
                                  ▲    │ send bytes                     │ FLVMedia                    │ IngestSessionReducer (Core)
                                  └────┘                                ▼                             ▼
                                                  TimelineMapper + AudioSampleClock (Core) ──▶ LiveTakeRecorder (Media)
                                                                                                  ├─ mac: AVAssetWriter .mov (video passthrough + LPCM)
                                                                                                  ├─ win: FFmpeg mov muxer + FLV journal
                                                                                                  ├─▶ preview feed (compressed samples)
                                                                                                  └─▶ 16 kHz mono feed (file-time aligned)
 phone browser ──HTTP──▶ LanHttpServer (Media) ──heads/bodies──▶ HTTPRequestParser + LanRouter + UploadSessionStore (Core)
                                                                    └─▶ .part files on disk ──▶ completed file ──▶ normal import
 SMB share folder / sync folder ──▶ InboxWatcher (Media) ──▶ InboxIndex (Core) ──▶ Welcome/Home list ──▶ normal import
 camera volume (USB/SD) ──▶ CameraVolumeWatcher (UI) ──▶ Import sheet ──▶ copy ──▶ normal import
 16 kHz feed ──▶ live engine + LiveSilenceFinder ──▶ LiveClipEngine (Core) ◀── Clip that button / shortcut / phone POST
                                                         ├─▶ LLMRunner (ai.md), AI watching only
                                                         └─▶ LiveClipRenderer (Media) ◀── sealed take ──▶ "Clips from this stream" tray
```

"Normal import" is architecture.md §4 step 1 onwards: probe, untitled project, audio extraction, transcription. Live clipping is section 9.

### 4.2 Module placement

| Concern | macOS | Windows |
|---|---|---|
| Pure protocol and logic (fixture-tested): `IngestConstants`, `IPv4`, `LANInterfaceSelector`, `PeerPolicy`, `IngestSecretFormat`, `AMF0`, `RTMPHandshake`, `RTMPChunkDecoder` / `RTMPChunkEncoder`, `RTMPServerProtocol`, `FLVTagParser`, `CodecConfig` (avcC / hvcC / AudioSpecificConfig), `TimelineMapper`, `AudioSampleClock`, `IngestSessionReducer`, `HTTPRequestParser`, `LanRouter`, `UploadSessionStore`, `UploadFileName`, `InboxIndex` | `VoxClipCore/Domain/Ingest/` | `VoxClip.Core/Domain/Ingest/` |
| HMAC-SHA256 for the digest handshake | protocol `HMACSHA256` in Core; CryptoKit adapter in `VoxClipMedia` | `System.Security.Cryptography.HMACSHA256.HashData` directly in Core (BCL) |
| CSPRNG for keys and tokens | `SystemRandomNumberGenerator` in Core `Services` | `RandomNumberGenerator.GetBytes` in Core `Services` |
| TCP listeners and connections | `VoxClipMedia/Ingest/Transport/` (Network framework `NetworkListener`, macOS 26; an `NWListener` adapter is an allowed fallback) | `VoxClip.Media/Ingest/Transport/` (`System.Net.Sockets`) |
| Take recorder, AAC decoder, preview and 16 kHz feeds | `VoxClipMedia/Ingest/` (AVAssetWriter, AVAudioConverter, AVSampleBufferVideoRenderer) | `VoxClip.Media/Ingest/` (FFmpeg.AutoGen) |
| Interface enumeration and change events | `VoxClipMedia/Ingest/` (`NWPathMonitor` + `getifaddrs`) | `VoxClip.Media/Ingest/` (`NetworkInterface`, `NetworkChange`) |
| Inbox watcher | `VoxClipMedia/Ingest/` (FSEvents) | `VoxClip.Media/Ingest/` (`FileSystemWatcher` + rescan) |
| Camera volume detection | UI (`NSWorkspace` mount notifications) | UI (`DriveInfo` polling) |
| Firewall check and elevated helper | none | `VoxClip.App/Ingest/` (`INetFwPolicy2` COM), `[SupportedOSPlatform("windows")]` |
| QR codes | UI (CoreImage `CIFilter.qrCodeGenerator()`) | App (QRCoder 1.8.1, MIT, [NuGet](https://www.nuget.org/packages/QRCoder), new dependency) |
| Stream key storage | UI (Keychain, account `ingest-rtmp-key`) | App (DPAPI, `<data>\Secrets\ingest-rtmp-key.bin`) |
| Live clipping logic (fixture-tested): `LiveSilenceFinder`, `LiveTriggerMatcher`, `LiveClipSnapper`, `LiveClipEngine`, `LiveTakeIndex` (section 9) | `VoxClipCore/Domain/Ingest/LiveClips/` | `VoxClip.Core/Domain/Ingest/LiveClips/` |
| Sealed take reader, live clip renderer, coordinator | `VoxClipMedia/Ingest/LiveClips/` (`AVFragmentedAsset`, `AVFragmentedAssetMinder`, the export path's `FrameCompositor`) | `VoxClip.Media/Ingest/LiveClips/` (`JournalPacketSource`, the export compose function) |
| Global "clip that" shortcut, live clip notifications | UI (Carbon `RegisterEventHotKey`, `UNUserNotificationCenter`) | App (`RegisterHotKey`, Windows App SDK `AppNotificationManager`) |
| View models | `ReceiveModel`, `PhoneUploadModel`, `CameraInboxModel`, `LiveClipsModel` (`@Observable`, main actor) | `ReceiveViewModel`, `PhoneUploadViewModel`, `CameraInboxViewModel`, `LiveClipsViewModel` (CommunityToolkit.Mvvm) |
| CLI | `voxclip-cli ingest …` (section 17.2) | same |

Core stays free of Network framework, CryptoKit and FFmpeg; Media never depends on UI (architecture.md §2.1).

### 4.3 Data locations

| Item | macOS | Windows |
|---|---|---|
| Received videos (live takes, phone uploads, camera imports) | `~/Movies/VoxClip/Received/` (Settings → Receive) | `%USERPROFILE%\Videos\VoxClip\Received\` |
| Take while recording | `<Received>/<name>.partial.mov` | `<Received>\<name>.partial.mov` plus the journal `<name>.partial.flv` |
| Upload in progress | `<Received>/.voxclip-upload-<id>.part` | same |
| Take sidecar (markers, stats; no key, no peer address) | `<data>/Ingest/Takes/<contentKey>.json` | `<data>\Ingest\Takes\<contentKey>.json` |
| Inbox index | `<data>/Ingest/inbox.json` | `<data>\Ingest\inbox.json` |
| Default camera inbox folder | `~/Movies/VoxClipInbox/` | `%USERPROFILE%\Videos\VoxClipInbox\` |
| Live clip store while a take is live (section 9.10) | `<data>/Ingest/Live/<takeId>.json` | `<data>\Ingest\Live\<takeId>.json` |
| Live clip drafts (section 9.7.5) | `<data>/Cache/LiveClips/<takeId>/` | `<data>\Cache\LiveClips\<takeId>\` |
| Kept live clips | the export folder (`export.folder`, architecture.md §2.5) | same |

Take names: `{yyyy-MM-dd HH.mm} Live take.mov` in local time. Collisions append ` (2)`, ` (3)` before the extension. Phone uploads and camera imports keep the sanitized original name (section 10.5) with the same collision rule.

Take sidecar (`file` is the take's absolute path in the Received folder, written here as `<Received>/…`):

```json
{
  "schema": "voxclip-ingest-take/1",
  "file": "<Received>/2026-10-25 14.03 Live take.mov",
  "contentKey": "<64 hex>",
  "startedAt": "2026-10-25T11:03:11Z",
  "protocol": "rtmp",
  "video": { "codec": "hvc1", "width": 1920, "height": 1080, "nominalFps": 30 },
  "audio": { "codec": "mp4a", "sampleRate": 48000, "channels": 2, "written": "lpcm-s16" },
  "connections": 2,
  "markers": [ { "atSeconds": 6.921, "kind": "reconnect" } ],
  "nudgedFrames": 0,
  "silenceInsertedSeconds": 0.0,
  "droppedAudioSeconds": 0.0,
  "liveClips": [ { "id": "lc3", "title": "Why pricing is a story", "origin": { "kind": "finder", "preset": "best", "score": 9 },
                   "start": 2240.88, "end": 2283.15, "state": "kept", "seen": true } ],
  "liveClipsApplied": false
}
```

The editor reads the sidecar by `contentKey` to draw marker ticks on the timeline strip (section 20) and to turn `liveClips` into clip ranges once (section 9.8.1; `liveClips` entries have the live store's fields, section 9.10). The project file is unchanged in M2.

### 4.4 Settings keys (`settings.json`)

| Key | Type | Default |
|---|---|---|
| `ingest.receivedFolder` | path | see 4.3 |
| `ingest.interface` | `"auto"` or an interface id (`en0`, a Windows interface GUID) | `"auto"` |
| `ingest.rtmpPort` | integer in 1935–1945 | 1935 |
| `ingest.inbox.enabled` | bool | false |
| `ingest.inbox.folder` | path | see 4.3 |
| `ingest.liveClips.voiceTrigger` | bool: listen for "clip that" (section 9.4.2) | true |
| `ingest.liveClips.phoneButton` | bool: Clip that on the stream helper page | true |
| `ingest.liveClips.globalShortcut` | shortcut string (for example `"ctrl+option+cmd+k"`, `"ctrl+shift+f9"`) or null | null |
| `ingest.liveClips.lookbackSeconds` | integer in 15–120 (Settings offers 30, 45, 60, 90) | 45 |
| `ingest.liveClips.presets` | non-empty array of `best`, `hooks`, `quotes` | `["best"]` |
| `ingest.liveClips.minScore` | integer in 6–10 | 8 |
| `ingest.liveClips.maxPerHour` | integer in 1–20 | 6 |
| `ingest.liveClips.budgetCalls` | integer in 10–1000 | 120 |
| `ingest.liveClips.budgetTokens` | integer in 50,000–5,000,000 | 400,000 |
| `ingest.liveClips.notify` | bool | true |
| `ingest.liveClips.cloudConsent.<connectorId>` | bool | false |

The stream key is a secret and is never in `settings.json`. Whether AI watching is on is per stream and never stored (section 9.5.1).

### 4.5 Concurrency

- **macOS.** `RTMPReceiver`, `LanHttpServer` and `InboxWatcher` are actors. Each TCP connection runs in one child task that owns its `RTMPServerProtocol` value. `LiveTakeRecorder` is an actor; the `AVAssetWriter` and its inputs are created and used only inside it (architecture.md §7.1). The preview renderer (`AVSampleBufferVideoRenderer`) is created on the main actor and handed to the recorder as the only shared AVFoundation object; that hand-off needs the invariant comment that architecture.md §7.1 requires (section 20). Events reach the main actor through an `AsyncStream`, coalesced to at most 10 Hz.
- **Windows.** One `Task` per connection reads through a `BufferedStream` and writes to the raw `NetworkStream`. **Measured:** one `BufferedStream` cannot interleave reads and writes. The recorder owns its `AVFormatContext` and codec contexts on a dedicated thread `vc-ingest-mux`, fed by a bounded `Channel<IngestPacket>` (capacity 512, `FullMode = Wait`, so TCP backpressure reaches the camera). Preview decoding runs on `vc-ingest-preview`. UI updates go through `IProgress<T>` or `DispatcherQueue.TryEnqueue`.
- **Live clipping** (section 9.7.3). macOS: `LiveClipCoordinator` and `LiveClipRenderer` are actors; renders run at `.utility` priority and each opens its own `AVFragmentedAsset`. Windows: renders run on `vc-live-render` at `ThreadPriority.BelowNormal`; `LiveTakeIndex` is written on `vc-ingest-mux` and read through immutable snapshots. The `LiveClipEngine` value is owned by the coordinator. Nothing in live clipping can block the recorder.
- Every loop observes cancellation. Closing the Receive window cancels the session after finalizing the take.

### 4.6 Logging

New log category `ingest`. The stream key, the upload token and the helper token are registered with the `Redactor` when created (architecture.md §11.2 rule 1). In addition, the publish name and the last path segment of `app` and `tcUrl` are **never** logged, because a wrong or old key is not registered. Allowed at `info`: interface name, bound port, codec, dimensions, take duration and bytes, reconnect count, rejected-publisher count. Peer IPv4 addresses and phone file names only at `debug`. Live clipping logs metadata only (section 9.10): never transcript text, clip titles, reasons, trigger phrases or the stream's instruction.

---

## 5. Constants

| Name | Value |
|---|---|
| `rtmpPorts` | 1935, then 1936…1945 in order (first free) |
| `httpPorts` | 8765, then 8766…8775 |
| `keyAlphabet` | `0123456789abcdefghjkmnpqrstvwxyz` (32 symbols, no `i l o u`) |
| `streamKey` | 10 random bytes → 16 symbols, shown as `vox-xxxx-xxxx-xxxx-xxxx` |
| `token` (upload, helper page) | 16 random bytes → 26 symbols |
| `handshakeTimeout` | 10 s from accept to C2 |
| `prePublishTimeout` | 10 s from C2 to an accepted `publish` |
| `readIdleTimeout` | 10 s with no bytes from an accepted publisher |
| `tcpKeepalive` | idle 10 s, interval 5 s, count 3 |
| `reconnectWindow` | 60 s |
| `unpublishGrace` | 0 s (revisit after H4/H5) |
| `noVideoNotice` | 15 s after `publish` with no keyframe and no audio |
| `waitingAutoOff` | 15 min with no accepted publisher |
| `noClientHint` | 30 s with no TCP connection |
| `maxPendingConnections` | 4 not-yet-publishing connections |
| `maxMessageBytes` | 16 MiB (media); 64 KiB (command and data messages) |
| `amfMaxDepth` / `amfMaxProperties` | 32 / 1024 per object |
| `maxCommandsPerSecond` | 100 per connection |
| `maxPrePublishMessages` | 64 |
| `failedPublishLimit` | 10 rejected publishes from one peer within 60 s → refuse that peer for 10 min |
| `outChunkSize` | 4096 |
| `windowAckSize` / `peerBandwidth` | 5,000,000 / 5,000,000 with limit type 2 (dynamic) |
| `preBufferMax` | 2 s of media while waiting for both sequence headers |
| `videoTimescale` | 90,000 |
| `dtsNudge` | 1 tick of 90 kHz |
| `jumpBackwardMs` / `jumpForwardMs` | 1 / 5,000 |
| `audioReanchorMs` | 40 |
| `feedRate` | 16,000 Hz mono Float32 |
| `movieFragmentInterval` (macOS writer) | 10 s (the CLI without `--clip-at`); the app uses `liveFragmentInterval` |
| `journalFlushInterval` (Windows) | 1 s |
| `freeDiskToStart` / `freeDiskToContinue` | 3 GB / 2 GB on the Received volume |
| `statsWindow` | 2 s (UI refresh at most 1 Hz) |
| `uploadChunk` (page) | 8 MiB |
| `maxPatchBody` | 16 MiB |
| `maxUploadBytes` | 64 GB |
| `uploadDiskReserve` | 2 GB |
| `maxActiveUploads` | 4 per session |
| `uploadSessionIdle` | 10 min with no requests and no incomplete upload |
| `uploadSessionIdleWithPartial` | 60 min with no requests |
| `uploadPausedAfter` | 15 s with no bytes (UI shows "paused") |
| `httpHeadMax` | 16 KiB in total, request line 4 KiB, 64 header fields |
| `httpHeadTimeout` / `httpBodyIdle` / `httpKeepAliveIdle` | 10 s / 30 s / 30 s |
| `httpMaxConnections` | 16 in total, 8 per peer |
| `httpMaxRequestsPerConnection` | 1000 |
| `inboxStable` / `inboxRecheck` / `inboxRescan` | 10 s / 5 s / 60 s |
| `volumePoll` (Windows) | 2 s while Home is visible |

Live clipping (section 9):

| Name | Value |
|---|---|
| `liveFragmentInterval` (macOS writer in the app) | 2 s |
| `liveMinderInterval` (macOS `AVFragmentedAssetMinder`) | 1 s |
| `liveRenderGuard` | 1 s past a clip's end must be sealed before it renders |
| `liveRenderResume` | 2 s clear before a paused job resumes |
| `liveRenderPauseLag` | 4 s of live-engine lag pauses heavy jobs |
| recorder pressure gate | an input not ready for more than 250 ms (macOS); more than 256 of 512 packets in the mux channel (Windows) |
| `silenceFrame` / `silenceMinRun` | 160 samples (10 ms at 16 kHz) / 30 frames (300 ms) |
| `silenceStatsWindow` / `silenceFloor` | 120 s / 0.001 (−60 dBFS) |
| `clipThatLookback` | 45 s (setting `ingest.liveClips.lookbackSeconds`, 15–120 s) |
| `clipThatSnapBack` / `clipThatSnapForward` / `clipThatEndSnap` | 15 s / 10 s / 5 s |
| `clipThatMinSeconds` / `clipThatMaxSeconds` | 5 s / 180 s |
| `clipThatCoalesce` | 3 s |
| `clipThatPauseBefore` / `clipThatPauseAfter` / `clipThatFinalWait` | 0.25 s / 0.4 s / 5 s |
| `clipAdjustStep` | 15 s |
| `phoneClipRate` | 10 requests per 60 s per helper session |
| `liveEvalMinWords` | 40 new final words |
| `liveEvalMinInterval` / `liveEvalMaxInterval` / `liveEvalPause` | 30 s / 90 s / 1.2 s |
| `liveWindowSeconds` / `liveWindowStep` | 240 s / 60 s |
| `liveCandidatesPerCall` | 2 |
| `liveSettleSeconds` | 8 s |
| `liveSameMoment` / `liveContainment` | overlap ratio 0.6 (the prompt file's `nearDuplicateOverlap`) / 0.8 |
| `liveSameTopicJaccard` / `liveSameTopicGap` / `liveTopicTokenMin` | 0.5 / 120 s / 4 UTF-16 code units |
| `liveOutputReserve` | 2,000 tokens per request in the budget estimate |
| back-off | 60 s, doubling, at most 600 s; pause after 3 consecutive failures |
| defaults | minimum score 8, 6 AI clips per hour, budget 120 calls and 400,000 tokens per stream (section 4.4) |
| `notifyScoreBonus` / `notifyMinGap` | +1 over the minimum score / 300 s |
| `draftMaxAge` | 24 h for draft folders no session owns |
| `cameraMatchWindow` / `cameraFineSearch` / `cameraMatchMinCorrelation` | 10 min / ±50 ms / 0.5 (tune after H7) |

Tests and the CLI may override timeouts and limits through an injected `IngestLimits` value (live clipping: `LiveClipLimits`); the app always uses these values.

---

## 6. RTMP / Enhanced RTMP receiver

Specifications: [Adobe RTMP 1.0](https://veovera.org/docs/legacy/rtmp-v1-0-spec.pdf) (Dec 2012, Veovera mirror), the [RTMP errata](https://zenomt.github.io/rtmp-errata-addenda/rtmp-errata-addenda.html), and [Enhanced RTMP v2](https://veovera.org/docs/enhanced/enhanced-rtmp-v2.html) (version `v2-2026-01-31-r2`, Release). Multi-byte integers are big-endian, except the message stream id in a type-0 chunk header, which is little-endian.

### 6.1 Transport

1. Bind TCP on `<interface IPv4>:<port>` only (section 13). Set `SO_REUSEADDR` (macOS `allowLocalEndpointReuse = true`); never `SO_REUSEPORT`. Disable Nagle on accepted sockets.
2. On accept, check the peer against `PeerPolicy` (section 14 rule 3) and the throttle list. Refused peers are closed at once without a byte.
3. At most `maxPendingConnections` connections may be in the handshake or pre-publish stage; extra ones are closed.
4. Enable TCP keepalive (`tcpKeepalive`) and enforce `handshakeTimeout`, `prePublishTimeout` and `readIdleTimeout`. A half-open socket must not block a reconnect.
5. Read with `receive(atLeast: 1, atMost: 256 KiB)` (macOS) or `ReadAsync` into a pooled 256 KiB buffer (Windows) and pass each slice to `RTMPServerProtocol.receive`. Write every `.send` output in order before handling the next input slice.

### 6.2 Handshake

```text
client → C0 (1 byte: 3) + C1 (1536: time u32, zero-or-version u32, 1528 random)
server → S0 (3) + S1 (1536) + S2 (1536)          sent together after C0+C1 arrive
client → C2 (1536)                               not validated (errata: do not fail on an echo mismatch)
```

- **C0.** `3` continues. `6` (RTMPE) closes with `rtmpeUnsupported`. Any other value closes with `badVersion`.
- **Digest detection.** If C1 bytes 4–7 are non-zero, look for a client digest. For `base` in 8 and then 772: `offset = (C1[base] + C1[base+1] + C1[base+2] + C1[base+3]) % 728 + base + 4`. The digest is valid when `HMAC-SHA256(key: first 30 bytes of "Genuine Adobe Flash Player 001", data: C1 without the 32 bytes at offset)` equals `C1[offset ..< offset+32]`. The first base that matches wins.
- **Plain reply** (no valid digest): S1 = `serverTime` (u32) + four zero bytes + `serverRandom[0..<1528]`. S2 = C1 copied exactly.
- **Digest reply**: S1 = `serverTime` + version bytes `04 05 00 01` + `serverRandom[0..<1528]`. Then compute the digest offset from S1's own bytes with the client's base (same formula), and overwrite the 32 bytes there with `HMAC-SHA256(key: the 36 ASCII bytes "Genuine Adobe Flash Media Server 001", data: S1 without those 32 bytes)`. S2 = `serverRandom[1528..<3032]` (1504 bytes) followed by `HMAC(key: HMAC(key: fmsKey68, data: clientDigest), data: those 1504 bytes)`, where `fmsKey68` is the same 36 bytes followed by the 32-byte constant `F0 EE C2 4A 80 68 BE E8 2E 00 D0 D1 02 9E 7E 57 6E EC 5D 2D 29 80 6F AB 93 B8 E6 36 CF EB 31 AE`. The client key used in detection is the 30 ASCII bytes "Genuine Adobe Flash Player 001".
- `serverRandom` (3032 bytes) and `serverTime` are injected into `RTMPServerProtocol`. The app fills them from the CSPRNG and the uptime in ms; fixtures use all-zero bytes and time 0, so server output is byte-identical on both platforms.
- **Measured:** FFmpeg 6.1 sends a digest C1 and accepted the prototype's digest reply. From its source (`rtmpproto.c`), FFmpeg checks the server digest only when playing, so a plain reply also works for publishing. Moblin answers every publisher plainly and works with Pocket 3 and 4, so either reply is expected to satisfy the camera **[HW H1]**.

### 6.3 Chunk stream

- **Basic header:** `fmt` (2 bits), `csid` (6 bits). `csid` 0 → `64 + next byte`. `csid` 1 → `64 + b1 + b2 × 256`.
- **Message header by `fmt`:** 0 → timestamp (3), length (3), type (1), stream id (4, little-endian). 1 → timestamp delta (3), length (3), type (1). 2 → timestamp delta (3). 3 → none.
- A `fmt` 3 chunk that **starts** a new message reuses the previous header of that `csid`, including its delta.
- **Extended timestamp:** when the 24-bit field is `0xFFFFFF`, a 4-byte timestamp follows. Keep a per-`csid` flag; when the last header on that `csid` was extended, a `fmt` 3 chunk also carries the 4 bytes (librtmp, FFmpeg and OBS repeat them).
- The incoming chunk size is 128 until a Set Chunk Size arrives (31-bit value; values below 1 or above 16,777,215 close with `protocolError`).
- **Abort (type 2)** drops the partial message of that `csid`.
- A message whose declared length exceeds `maxMessageBytes` (media types 8, 9, 22) or 64 KiB (other types) closes with `messageTooLarge` before any payload is buffered.
- **Acknowledgement.** If the peer sends Window Ack Size `W`, then after each **complete message** is decoded, if `totalBytesConsumed − lastAckedTotal ≥ W`, send Acknowledgement (type 3) with `totalBytesConsumed mod 2^32` and set `lastAckedTotal = totalBytesConsumed`. Checking at message boundaries keeps server output independent of how TCP split the input.

### 6.4 Messages and their handling

| Type | Message | Action |
|---|---|---|
| 1 | Set Chunk Size | update inbound chunk size |
| 2 | Abort | drop the partial message on that `csid` |
| 3 | Acknowledgement | ignore |
| 4 | User Control | ignore inbound |
| 5 | Window Ack Size | remember `W` |
| 6 | Set Peer Bandwidth | ignore |
| 8 / 9 | Audio / Video | FLV body (6.8, 6.9); before `publish` is accepted: ignore and count against `maxPrePublishMessages` |
| 15 / 18 | AMF3 data / AMF0 data | strip the leading format byte for type 15, then AMF0 values (6.11) |
| 17 / 20 | AMF3 command / AMF0 command | strip the leading format byte for type 17, then AMF0 (6.5) |
| 22 | Aggregate | sub-messages `type(1) size(3) ts(3) tsExt(1) streamId(3) body backPointer(4)`; each sub-message timestamp is `aggregateTs + (subTs − firstSubTs)`; then handled as types 8, 9 or 18 |
| other | — | ignore |

AMF0 decoding supports number, boolean, string, object, null, undefined, ECMA array, object end, strict array, date and long string, with `amfMaxDepth` and `amfMaxProperties`. References, typed objects and AMF3-only types close the connection with `protocolError`. More than `maxCommandsPerSecond` command or data messages in any one-second window closes with `rateLimited`.

### 6.5 Commands and exact replies

All server messages use timestamp 0. Protocol control and User Control go on `csid` 2, message stream 0; commands go on `csid` 3. Every reply is AMF0 (type 20) whatever the request type. Object properties are encoded in the order listed, so fixtures can compare server bytes exactly.

| Inbound | Reply |
|---|---|
| `connect(txn, cmdObj)` | Window Ack Size `5,000,000`; Set Peer Bandwidth `5,000,000`, limit 2; Set Chunk Size `4096` (outbound chunk size changes after this message); then `_result(txn, {fmsVer: "FMS/3,0,1,123", capabilities: 31, videoFourCcInfoMap: {avc1: 4, hvc1: 4}, audioFourCcInfoMap: {mp4a: 4}, capsEx: 0}, {level: "status", code: "NetConnection.Connect.Success", description: "Connection succeeded.", objectEncoding: 0})`. A second `connect` closes with `protocolError` |
| `releaseStream(txn, null, name)` | `_result(txn, null)` |
| `FCPublish(txn, null, name)` | `onFCPublish(0, null, {code: "NetStream.Publish.Start", description: "Publishing."})` |
| `createStream(txn, null)` | `_result(txn, null, 1)`. A second `createStream` closes with `protocolError` |
| `publish(txn, null, name, type)` on message stream 1 | key check (6.6). **Accepted:** User Control StreamBegin (event 0, stream id 1), then `onStatus(0, null, {level: "status", code: "NetStream.Publish.Start", description: "Publishing."})` on message stream 1. **Rejected:** `onStatus(0, null, {level: "error", code: "NetStream.Publish.BadName", description: "Invalid stream key"})`, then close after the bytes are flushed |
| `FCUnpublish`, `deleteStream`, `closeStream` | event `unpublished` |
| `play`, `play2` | `onStatus(0, null, {level: "error", code: "NetStream.Play.Failed", description: "Playback is not supported."})`, then close |
| other with `txn > 0` | `_error(txn, null, {level: "error", code: "NetConnection.Call.Failed", description: "Unknown command."})` |
| other with `txn = 0` | ignore |

E-RTMP capability fields in the client's `connect` object (`fourCcList`, `videoFourCcInfoMap`, `audioFourCcInfoMap`, `capsEx`) are recorded for diagnostics only. The Pocket 4 sends HEVC to servers that advertise nothing, so nothing depends on them. The server does not send `onBWDone`, Reconnect Request or `_checkbw`.

**Measured** FFmpeg 6.1 command order: `connect`, `releaseStream`, `FCPublish`, `createStream`, `publish`, `@setDataFrame onMetaData`, media, `FCUnpublish`, `deleteStream`. The camera's order is **[HW H1]**.

### 6.6 Stream key acceptance

1. Candidates, in order: the `publish` name; the last non-empty path segment of `connect.app`; the last non-empty path segment of `connect.tcUrl`. Candidates longer than 256 bytes are dropped.
2. `normalizedKeyCandidate`: strip everything from the first `?`; strip trailing `/`; trim ASCII whitespace; lowercase ASCII letters; remove every `-`; remove one leading `vox`. The result must be exactly 16 symbols of `keyAlphabet`, otherwise the candidate is dropped. Lowercasing loses no entropy (the alphabet is lowercase) and absorbs keyboard auto-capitalization; removing dashes and the prefix accepts retyped keys. `vox` can never be part of the 16 symbols because `o` is not in the alphabet.
3. Accept if any normalized candidate equals the expected key's 16 symbols under a **constant-time** byte comparison.

### 6.7 Publisher lifecycle

- One publisher at a time. **The newest accepted publisher wins:** when a second connection's `publish` is accepted, the old connection is closed with `replaced`, and the take continues with the new connection exactly as after a reconnect (section 8.5). This is what lets a camera reconnect before its old socket times out.
- A rejected `publish` counts towards `failedPublishLimit` for that peer.
- After `unpublished`, a TCP close, or `readIdleTimeout`, the connection is gone; the session reducer decides what happens to the take (section 8.1).

### 6.8 Video tags

```text
byte0 bit7 = isExVideoHeader
legacy (bit7 = 0):   frameType UB[4] (1 key, 2 inter, 3 disposable, 5 command)  codecId UB[4] (7 = AVC, 12 = pre-standard HEVC)
                     AVCPacketType UI8 (0 sequence header, 1 NALUs, 2 end)  CompositionTime SI24 (ms)  data
enhanced (bit7 = 1): frameType UB[3]  packetType UB[4]
  while packetType == ModEx (7): size = UI8 + 1 (if 256 then UI16 + 1), modExData[size], then modExType UB[4], packetType UB[4]
                                  modExType 0 = TimestampOffsetNano (UI24 ns): ignored
  if frameType == 5 (command) and packetType != Metadata (4): UI8 command; no media
  if packetType == Multitrack (6): multitrackType UB[4] (0 one track, 1 many tracks, 2 many tracks many codecs), packetType UB[4],
                                  FourCC once unless type 2, then per track: trackId UI8 [, size UI24 unless type 0]
  else FourCC UI32
  packetType: 0 SequenceStart (record), 1 CodedFrames (SI24 CTS first for avc1/hvc1), 2 SequenceEnd,
              3 CodedFramesX (CTS = 0), 4 Metadata (AMF ["colorInfo", {...}]), 5 MPEG2TSSequenceStart
```

- Accepted video: legacy id 7 (AVC), legacy id 12 (HEVC), E-RTMP `avc1` and `hvc1`. **Measured:** FFmpeg 6.1 sends HEVC as `0x90 'hvc1' <hvcC>` then `0x93` / `0xA3 'hvc1'` (CodedFramesX). Which form the Pocket 4 uses is **[HW H1]**, so all are required.
- Other FourCCs (`av01`, `vp09`, `vp08`, `vvc1`) produce `unsupported(videoCodec)` (section 6.12).
- Multitrack: only track id 0 (or the first track listed) is used; other tracks are counted and logged once.
- Frames before the first SequenceStart are dropped. A SequenceStart byte-identical to the current one is ignored; a different one is a `sequenceChanged` event (section 8.5).
- Disposable frames (type 3) are recorded like inter frames. Command frames, metadata packets and SequenceEnd produce no samples.
- Data after the header is length-prefixed NAL units (AVCC / HVCC). It is passed through unchanged.

### 6.9 Audio tags

- **Legacy:** `soundFormat UB[4]` (10 = AAC), then rate, size and type bits (ignored for AAC), `AACPacketType UI8` (0 = AudioSpecificConfig, 1 = raw frame). **Measured:** FFmpeg sends `0xAF`.
- **Enhanced:** `soundFormat == 9`, then `AudioPacketType UB[4]` (0 SequenceStart, 1 CodedFrames, 2 SequenceEnd, 4 MultichannelConfig, 5 Multitrack, 7 ModEx) and a FourCC. Accepted: `mp4a`. A zero-length CodedFrames payload and SequenceEnd mean silence. A message may batch several tracks and must be parsed completely; only track 0 is used.
- **AudioSpecificConfig:** objectType (5 bits; 31 means escape, 6 more bits), frequency index (4 bits; 15 means an explicit 24-bit rate), channel configuration (4 bits). Accepted object types: 2 (AAC-LC), 5 (SBR), 29 (PS). Channel configurations 1 and 2. **Measured** from FFmpeg: `11 90 56 e5 00` = AAC-LC, 48 kHz, stereo.
- Other audio (`Opus`, `.mp3`, `ac-3`, `ec-3`, `fLaC`, legacy MP3) produce `unsupported(audioCodec)`.

### 6.10 Sequence headers to format descriptions

- **avcC** (ISO/IEC 14496-15 §5.3.4.1): version 1, profile, compatibility, level, `lengthSizeMinusOne & 3`, `numSPS & 0x1F` × (u16 length + NAL), `numPPS` × (u16 length + NAL). **hvcC** (§8.3.3.2): 22 fixed bytes (byte 21 holds `lengthSizeMinusOne` in its low 2 bits), `numArrays`, each `(type & 0x3F, u16 count, count × (u16 length + NAL))`; types 32 VPS, 33 SPS, 34 PPS, 39/40 SEI. Core parses these structurally; it does not decode SPS fields.
- **macOS:** `CMVideoFormatDescriptionCreateFromH264ParameterSets` (SPS + PPS) or `CMVideoFormatDescriptionCreateFromHEVCParameterSets` (VPS + SPS + PPS, `extensions: nil`), with `nalUnitHeaderLength = lengthSizeMinusOne + 1`. Dimensions come from the result. **Measured:** they produce `avc1` and `hvc1` sample entries. The AAC decoder input description is built from an ES_Descriptor magic cookie (tag 0x03 → DecoderConfigDescriptor 0x04, objectType 0x40, streamType 0x15 → DecoderSpecificInfo 0x05 with the ASC → SLConfig 0x06 = 0x02).
- **Windows:** `codecpar->extradata` = the avcC / hvcC record and the ASC exactly as received. Width and height come from opening the decoder with that extradata and sending the first keyframe (measured). HEVC `codec_tag` must be `hvc1` (FFmpeg defaults to `hev1`, which QuickTime and AVFoundation refuse; measured).

### 6.11 Metadata

`@setDataFrame` is stripped; `onMetaData` fields `width`, `height`, `framerate`, `videocodecid`, `audiocodecid`, `audiosamplerate`, `audiochannels` and `encoder` are kept as a diagnostics value. `framerate` in 1…120 sets the video nominal duration (section 7.1); otherwise 30 is assumed. Sequence headers always win over metadata.

### 6.12 Unsupported or broken input

| Case | Behaviour |
|---|---|
| Unsupported video codec | Finalize the current take if any; close the connection; state `failed(ingestUnsupportedCodec)` with the codec's FourCC |
| Unsupported audio codec with supported video | Record video only; notice "VoxClip can't record this camera's {codec} audio. The video is being recorded without sound." |
| Parse error inside a media payload | Drop that message, count it, keep going. More than 50 in 10 s closes with `protocolError` |
| Protocol error (chunking, AMF, commands) | Close the connection; the session treats it as a TCP close |

---

## 7. Timeline mapping and the audio clock

RTMP timestamps are 32-bit milliseconds of decode time per connection; video adds a composition offset in ms. The rules below were all hit and fixed in the prototypes. **Measured** with a flash-and-beep clip: A/V offset in the output matches the source within 0.4 ms in both AVFoundation and FFmpeg readers, including across a forced reconnect.

### 7.1 `TimelineMapper` (Core, pure)

One mapper per take. One offset is shared by audio and video so that sync survives every discontinuity. `nominal` is 21 ms for audio (one 1024-sample AAC frame at 48 kHz, rounded) and `round(1000 / fps)` for video.

```text
state: offset: Int64?, pendingBase: Int64?, lastRaw[track]: UInt32, unwrapped[track]: Int64, lastOut[track]: Int64, markers[]

map(raw: UInt32, track, nominal) -> Int64 (take timeline ms):
  if lastRaw[track] exists: unwrapped[track] += Int64(Int32(bitPattern: raw &- lastRaw[track]))    // wrap-safe
  else:                     unwrapped[track]  = Int64(raw)
  lastRaw[track] = raw
  u = unwrapped[track]
  if offset == nil:
     if pendingBase != nil: offset = pendingBase + nominal - u; markers.append(reconnect at pendingBase + nominal); pendingBase = nil
     else:                  offset = -u
  t = u + offset
  if lastOut[track] exists:
     d = t - lastOut[track]
     if d < -jumpBackwardMs or d > jumpForwardMs:
        target = lastOut[track] + nominal; offset += target - t; t = target
        markers.append(timestampJump(d) at target)
  lastOut[track] = t
  return t

beginNewConnection():
  pendingBase = max(lastOut.values) ?? 0; offset = nil; lastRaw = [:]; unwrapped = [:]
```

### 7.2 Video timestamps

- `dtsMs = map(rawDts, .video, nominalVideo)`, `ptsMs = dtsMs + cts`.
- Convert to 90 kHz: `dts90 = dtsMs × 90`, `pts90 = ptsMs × 90`. If `dts90 ≤ lastDts90` then `dts90 = lastDts90 + 1` (one nudge, counted), and `pts90 = max(pts90, dts90)`. **Measured:** a VideoToolbox H.264 stream with B-frames needed 147 nudges in 20 s; without them AVAssetWriter failed with −11800 / −16364.
- **Take origin.** The first keyframe's `pts90` is the take origin. macOS starts the writer session at it (`startSession(atSourceTime:)`); Windows subtracts it from every timestamp, so the first presented frame has PTS 0 and leading DTS values may be negative. **Measured:** without the rebase FFmpeg's mov muxer puts a 33 ms empty edit on both tracks and audio lands 33 ms late.
- Keep the actual ms values (deltas alternate 33 and 34 ms at 30 fps). Do not snap to a frame grid.

### 7.3 `AudioSampleClock` (Core, pure)

AAC frames are decoded to PCM (sections 8.3 and 8.4) and placed by **counting samples**, re-anchored to the RTMP clock when they drift.

```text
init(sampleRate sr)                       reanchorFrames = round(audioReanchorMs × sr / 1000)   // 1920 at 48 kHz
state: next: Int64?                       // sample index of the next frame in the take
place(tMs: Int64 /* take-relative, may be negative */, frames n: Int, force: Bool) -> Placement:
  expected = roundHalfUp(tMs × sr / 1000)  (integer arithmetic)
  silence = 0; skip = 0
  if next == nil:          next = max(expected, 0); skip = max(0, -expected)
  else:
     drift = expected - next
     if not force and |drift| <= reanchorFrames:  (continuous; write at next)
     else if drift > 0:   silence = drift; next += drift
     else:                skip = min(n, -drift)
  if skip >= n: return Placement(silence, drop: n, writeAt: next, write: 0)
  writeAt = next; next += n - skip
  return Placement(silence, drop: skip, writeAt, write: n - skip)
```

- `tMs` = mapped audio time − take origin (ms) + the device's `audioOffsetMs` (section 7.5).
- `force` is true for the first block after every reconnect or publisher replacement.
- Silence is written as zero samples; dropped frames are discarded from the front of the block. Totals go into the take sidecar.

### 7.4 The 16 kHz feed

The feed is produced by resampling exactly the PCM written to the file, including inserted silence, to 16 kHz mono Float32 (equal-weight downmix as in transcription.md §4). Feed sample `k` therefore corresponds to file time `k / 16000`. **Measured:** beep onsets in the 16 kHz feed sit within 0.1 ms of the file's audio (2.0054 vs 2.0053 s). On macOS use one `AVAudioConverter` from the written LPCM format; on Windows one `SwrContext` created from the first decoded `AVFrame` (the AAC decoder reports `sample_rate = 0` until then; measured).

### 7.5 Device calibration

The camera's AAC encoder delay is unknown. After hardware test H6 (clap test), add `shared/catalog/ingest-devices.json` with match rules (from `connect.flashVer`, `onMetaData.encoder` and the codec) and `audioOffsetMs` per model. Until then the offset is 0. Users rarely notice offsets below 45 ms, but the value must be measured, not guessed.

---

## 8. Takes

### 8.1 `IngestSessionReducer` (Core, pure)

The session logic is a reducer over inputs with injected monotonic time, so that both platforms share one fixture set (`shared/fixtures/ingest/session/`).

States: `listening(sinceMs)`, `pending(conn, publishAtMs)` (publish accepted, waiting for sequence headers and a keyframe), `live(take, conn)`, `reconnecting(take, sinceMs)`, `stopped(reason)`.

| Input | In state | Actions → next state |
|---|---|---|
| `publishAccepted(c)` | `listening` | → `pending(c)` |
| `publishAccepted(c)` | `pending(old)` | `closeConnection(old, replaced)` → `pending(c)` |
| `publishAccepted(c)` | `live(take, old)` | `closeConnection(old, replaced)`, `attach(c, newConnection: true)`, notice `replaced` if the peer differs → `live(take, c)` |
| `publishAccepted(c)` | `reconnecting(take)` | `attach(c, newConnection: true)` → `live(take, c)` |
| `publishRejected(peer)` | any | count; on the 10th within 60 s `throttlePeer(peer, now + 10 min)`; notice `wrongKey` |
| `ready(c, configs)` (both sequence headers seen, or `preBufferMax` passed with one) | `pending(c)` | `startTake(configs)` → `live` |
| `ready(c, configs)` | `live(take, c)` after an attach | if configs equal the take's: `continueTake`; else `finalizeTake(formatChanged)`, `startTake(configs)` |
| `sequenceChanged(c, configs)` | `live(take, c)` | `finalizeTake(formatChanged)`, `startTake(configs)` |
| `connectionClosed(c)` or `idleTimeout(c)` | `live(take, c)` | → `reconnecting(take, now)` |
| `connectionClosed(c)` | `pending(c)` | → `listening(now)` |
| `unpublished(c)` | `live(take, c)` | after `unpublishGrace`: `finalizeTake(unpublished)` → `stopped(takeEnded)` (CLI with `--max-takes > 1`: → `listening(now)`) |
| `tick(now)` | `reconnecting(take, since)` and `now − since ≥ reconnectWindow` | `finalizeTake(reconnectTimeout)` → `stopped(takeEnded)` |
| `tick(now)` | `listening(since)` and `now − since ≥ waitingAutoOff` | `stopListening(idle)` → `stopped(idle)` |
| `tick(now)` | `pending(c, at)` and `now − at ≥ noVideoNotice` | notice `noVideo` (once) |
| `userStop` | `live` or `reconnecting` | `finalizeTake(user)`, `stopListening(user)` → `stopped(user)` |
| `userStop` | other | `stopListening(user)` → `stopped(user)` |
| `diskLow` | `live` or `reconnecting` | `finalizeTake(diskFull)`, `stopListening(diskFull)` → `stopped(diskFull)` |
| `writerFailed(reason)` | `live` | `finalizeTake(writerFailed)`, `stopListening(writerFailed)` → `stopped(writerFailed)` |
| `unsupported(codec)` | `pending` or `live` | `finalizeTake(unsupported)` if live, `closeConnection(c, unsupported)` → `stopped(unsupported)` |

"Configs equal" means byte-equal avcC / hvcC records and byte-equal AudioSpecificConfig. `attach(newConnection: true)` calls `TimelineMapper.beginNewConnection()` and sets `force` for the next audio block. The preview is flushed on every attach and every new take.

### 8.2 Start of a take

1. Check free space on the Received volume: at least `freeDiskToStart`, else `diskFull` (no take starts).
2. While `pending`, hold media in memory until both sequence headers have arrived, or for `preBufferMax` if only one kind arrives (a video-only or audio-only take).
3. The take origin is the first video keyframe's PTS. Audio before the origin is dropped through `AudioSampleClock` (negative `tMs`). An audio-only take uses the first audio frame as its origin.
4. Create `<name>.partial.mov` and the recorder. Hold a power assertion for the whole session: macOS `ProcessInfo.processInfo.beginActivity(options: [.userInitiated, .idleSystemSleepDisabled], reason: "Receiving live video")`; Windows `PowerCreateRequest` + `PowerSetRequest(PowerRequestSystemRequired)`. Closing the lid still sleeps the Mac; the Receive window says so in its help text.

### 8.3 macOS writer

- One `AVAssetWriter(outputURL:fileType: .mov)` per take, `movieFragmentInterval = 10 s`, `shouldOptimizeForNetworkUse = false`. **Measured:** fragments are written during capture and the finished file is a normal movie, which gives crash safety at no extra cost. The app writes with `liveFragmentInterval` (2 s) instead, so live clips can read the take while it grows (section 9.7.1); the CLI keeps 10 s unless `--clip-at` is given.
- **Video input:** `AVAssetWriterInput(mediaType: .video, outputSettings: nil, sourceFormatHint: fd)`, `expectsMediaDataInRealTime = true`, `mediaTimeScale = 90000`. Each frame is a `CMSampleBuffer` made with `CMSampleBufferCreateReady` over the received bytes, with the DTS and PTS of section 7.2; non-keyframes carry `kCMSampleAttachmentKey_NotSync`. **Measured:** B-frame order is preserved and 600/600 decoded frames are bit-identical to the source; a 4K 50 Mbps HEVC stream comes out MD5-identical.
- **Audio input:** LPCM signed 16-bit interleaved at the source rate and channel count, `sourceFormatHint` = that LPCM description. AAC is decoded with `AVAudioConverter(from: AVAudioFormat(cmAudioFormatDescription: aacFD), to: int16)` and placed by `AudioSampleClock`.
- If an input is not ready for more data for 2 s, raise `writerFailed("the disk is too slow")`.
- **Finalize:** `markAsFinished()` on both inputs, `finishWriting()`, rename `.partial.mov` → `.mov`, compute `contentKey` (editing.md §10.3), write the take sidecar, end the power assertion.

### 8.4 Windows writer

- FFmpeg mov muxer (`avformat_alloc_output_context2(…, "mov", …)`), **not fragmented**, no `faststart` (a full-file rewrite at the end is too slow for multi-GB takes).
- **Video stream:** `codec_id` H.264 or HEVC, `codec_tag = 'hvc1'` for HEVC, `extradata` = the record, time base 1/90000, packets written with `av_interleaved_write_frame` using the rebased PTS and DTS of section 7.2 and `AV_PKT_FLAG_KEY` on keyframes.
- **Audio stream:** `pcm_s16le` at the source rate and channel layout; AAC decoded with FFmpeg's native decoder (LGPL) and placed by `AudioSampleClock`; time base 1/sampleRate.
- **Journal:** every received FLV tag, with its timeline-mapped timestamp and the current sequence headers first, is appended to `<name>.partial.flv` (a valid Enhanced FLV), flushed with `FileStream.Flush(true)` every `journalFlushInterval`. It costs one sequential write per message. While live, the recorder also keeps the in-memory `LiveTakeIndex` and publishes the flushed length and the sealed horizon after each flush, so live clips can read the take before it is finalized (section 9.7.1).
- **Finalize:** flush the muxer, `av_write_trailer`, close, rename `.partial.mov` → `.mov`, delete the journal, compute `contentKey`, write the sidecar, release the power request.
- **Measured** on the C# prototype with FFmpeg 6.1 libraries: with a non-fragmented output rebased to PTS 0, sync is exact in both FFmpeg and AVFoundation readers. With `frag_keyframe+empty_moov` the H.264 output started video at 0.033 s and audio at 0 (a 33 ms error). That is why the final file is not fragmented and the journal provides crash safety instead.

### 8.5 Reconnects and format changes

| Event | Action |
|---|---|
| `FCUnpublish` / `deleteStream` | Finalize at once (`unpublishGrace` 0 s) and open the project |
| TCP closed or idle without unpublish | `reconnecting`; the writer stays open for `reconnectWindow` |
| New publisher with the valid key within the window | `beginNewConnection()`, forced audio re-anchor, a `reconnect` marker. Same configs → same file. Different configs → finalize, new take |
| Window expires | Finalize; the editor shows "The camera didn't reconnect within a minute, so VoxClip saved the take." |
| Mid-connection SequenceStart with a different record | Finalize, new take, marker in the new take at 0 |

Each finalized take becomes its own project. When one Receive session produces several takes, the first opens in the Receive window and the others are added to Recent with a notice.

### 8.6 Opening the project

The Receive window becomes the editor (as the Record view does, design.md §12) with the take as `media.source`. The normal import runs: probe, extraction, transcription with the user's engine and routing (transcription.md). Live words, if any were shown, are discarded. Batch transcription is always the source of truth. Local never silently becomes cloud: with ElevenLabs as the default engine, the same rules as a dropped file apply. Live clips from the take become clip ranges of this project once its batch transcript is ready (section 9.8.1). Finalizing first cancels running live renders and never waits for them (section 9.7.4).

### 8.7 Crash recovery

- At launch, VoxClip scans the Received folder for `*.partial.mov` (macOS) and `*.partial.flv` (Windows) that no running session owns.
- **macOS:** if `AVURLAsset` reports the fragmented file as playable, copy it with an `AVAssetReader` → `AVAssetWriter` passthrough (no re-encode) to `<name>.mov`, then delete the partial file. If it is not playable, keep it and offer "Show in Finder".
- **Windows:** replay the journal through `LiveTakeRecorder` with the mapper disabled (timestamps are already mapped), producing `<name>.mov`; delete the partial `.mov` and the journal only after success.
- A recovered take adopts its live clip store (section 9.10).
- Recovery never deletes anything that did not produce a playable file. Copy: section 15.2.

### 8.8 Live preview

- **macOS:** the same compressed `CMSampleBuffer`s are enqueued into an `AVSampleBufferVideoRenderer` (hosted by an `AVSampleBufferDisplayLayer` in the view), with `kCMSampleAttachmentKey_DisplayImmediately` and no jitter buffer. Hardware decodes H.264 and HEVC. Flush on attach and on a new take.
- **Windows:** FFmpeg decode (D3D11VA, software fallback as in architecture.md §6.2) on `vc-ingest-preview`; frames are converted to BGRA at preview size and handed to the UI through a channel of capacity 2 that drops the oldest frame. Show at most 15 fps. Never use `MediaStreamSource` for HEVC: it needs the Store HEVC extension.
- Expected glass-to-glass latency is about 0.3–1 s on a LAN plus the camera's encoder (inferred; measured in H1).

### 8.9 Live audio feed and live transcript

`LiveTakeRecorder` exposes the 16 kHz feed (section 7.4) as an `AsyncStream<AudioFeedChunk>` (macOS) or `ChannelReader<AudioFeedChunk>` (Windows), where each chunk carries its first sample index. The live engine, its cost line and the transcript rendering belong to the M2 Recording spec and reuse this feed unchanged ("Live transcript while recording", design.md §4.1). Without a live engine the window shows "Words appear when the take ends." A live cloud engine starts only after the user turns it on, with its cost per hour shown. Live clipping (section 9) consumes the engine's final words through the contract in section 9.2; the Recording spec must give each engine's finalisation rule and its `processed` time.

### 8.10 Disk

Check free space every 10 s while live. Below `freeDiskToContinue`, raise `diskLow`; the take is finalized and kept. At 6 Mbps HEVC plus 48 kHz stereo PCM a take grows by about 3.4 GB per hour (2.7 GB video + 0.69 GB audio); Windows doubles this while the journal exists.

---

## 9. Live clipping

The author's follow-up idea, verbatim: "it can make clips continuously from live stream once something cool is captured". This section makes it normative. While a take is being received, VoxClip cuts clips from it and renders them, with captions, before the stream ends:

- **"Clip that".** The speaker says "clip that" (or an Estonian equivalent), presses a shortcut, or taps a button on the phone helper page. VoxClip cuts the last 45 seconds, snapped back to a sentence or a pause and ending before the trigger words. No LLM is involved.
- **AI watching** (the rolling clip finder). At natural pauses, roughly every 30 to 90 seconds, the latest four minutes of live transcript go to the user's chosen connector with the clip-finder presets. Strong moments whose thought has finished become clips. It is off until the user turns it on for a stream, and it stops at a per-stream budget.
- **Drafts while live.** The take is readable in sealed pieces while it is written, so a clip renders while the stream continues, into the **Clips from this stream** tray.
- **Review, never auto-post.** Clips wait in the tray for Keep, Share, Open in editor or Discard. Overlapping finds are merged so the tray does not fill with versions of the same moment. Nothing is posted or uploaded automatically, ever.

Milestones are in section 9.14, constants in section 5, settings keys in section 4.4.

### 9.1 Pipeline and invariants

```text
 16 kHz feed (7.4) ─┬─▶ live engine (M2 Recording spec) ── final words, processed time ──┐
                    └─▶ LiveSilenceFinder (Core) ── silence runs ─────────────────────────┤
 Clip that button, ⌘K / Ctrl+K, global shortcut, phone POST /s/{t}/clip ── triggers ──────┤
                                                                                          ▼
                                     LiveClipEngine (Core, sans-I/O, clock = take time from the feed)
                   LLMRequest ◀───────────┤   │ render jobs                 │ clips, watch state, notices
 LLMRunner + connector (ai.md) ── result ─┘   ▼                             ▼
                     LiveClipRenderer (Media) ◀── sealed take (9.7.1)   "Clips from this stream" tray (UI)
                     one compose path, low priority                     Keep · Share… · Open in editor · Discard
                                                                        └─▶ clip ranges in the take's project (9.8)
```

Invariants (each one is tested, section 9.13):

1. **Nothing is posted or uploaded automatically.** No code path in this section calls a publishing API (publishing.md §3) or uploads a clip or a draft anywhere. **Share…** opens the share helpers and nothing else.
2. **Batch transcription stays the source of truth** (ING-2). Live words drive the triggers, AI watching and draft captions only. They are never written to disk or to the project. A live clip is stored by take time and re-anchored to the batch transcript when the take ends (9.8.1).
3. **The receiver comes first.** Live clipping never blocks, slows or delays the receiver, the recorder, finalizing or the live engine. Renders and other heavy jobs pause under pressure (9.7.3).
4. **Local never silently becomes cloud** (AGENTS.md rule 10). AI watching sends text only, only to the connector the user chose, only after the user turns it on for this stream (9.6). The only other data that can leave the machine is a clip's audio during clip transcription without a live engine, and only when ElevenLabs is already the user's transcription engine with its consent given (9.4.4). Nothing else in this section sends anything off the machine.
5. **Preview equals export.** Drafts render through the platform's one compose path (macOS `FrameCompositor`, Windows compose function) with the export encoder settings (architecture.md §5.6, §6.4). There is no second caption renderer.
6. **Deterministic core.** Trigger matching, snapping, evaluation timing, windows, admission and the budget are decided by the pure `LiveClipEngine` on take time taken from the feed, never on wall-clock time, so a recorded stream replays to the same result on both platforms (9.13).

### 9.2 Live words and finality

The live engine, its adapters and its per-engine finalisation rules belong to the M2 Recording spec (section 8.9). Live clipping relies only on this contract:

| Event | Meaning |
|---|---|
| `final([LiveWord])` | Words the engine will never revise, appended in time order |
| `processed(throughSeconds)` | The feed time the engine has consumed; used by the lag gate (9.7.3) |
| `volatileText(text)` | Partial text for display (design.md §4.1). Ignored by everything in this section |

- `LiveWord = {index, text, kind, start, end}`. `index` is the word's **absolute number**: its position among the take's final words, from 0. It is the number the model sees and returns (ai.md §11.2). `text` has been through `cleanWords` (editing.md §5.2). `kind` is `word` or `event`. `start` and `end` are take seconds: feed sample `k` is take second `k / 16000` (section 7.4), which is also the file time of the finished take.
- **Final means provider finalisation.** A word counts only once the engine has finalised it. Examples (the Recording spec is normative for each engine): Apple `SpeechTranscriber` with volatile results enabled delivers a word as final once its result is no longer volatile; a streaming whisper.cpp engine delivers a word when its commit policy commits it; a cloud realtime engine delivers a word when the provider marks its segment final. An engine that might still change a word must hold it back.
- A `final` batch whose first word starts before the previous final word's start breaks the contract. The batch is dropped and logged at `warning`.
- `finalEdge` is the end of the newest final word (0 before any). `feedTime` is the duration of feed received so far. Final words stay in memory for the take (about 10,000 words per hour).
- **Lines.** `formatTranscript` (ai.md §11.3) runs incrementally over all final words, taken as the clip words of ai.md §11.2 (`index`, `text` cut to `maxWordTextLength`, `start`, `end`). A line closes when its successor word arrives, because the gap rule needs it. Closed lines never change; the newest line is open. A line break depends only on a word, its successor and the line's start, so the incremental lines equal `formatTranscript` over the full list (tested).
- **Boundaries.** A line start is a *boundary* when it is the take's first word, or when the previous line ended on a sentence end (ai.md §11.3 regex) or with a gap of at least 1.2 s. A break forced by the 40-word rule is not a boundary.
- The live language is the engine's language. It feeds `LLMRequest.language` and the Apple locale gate (ai.md §6.7).

Without a live engine there are no final words. "Clip that" still works from the button, the shortcuts and the phone (9.4); the voice phrase and AI watching are unavailable.

### 9.3 Pauses from the feed (`LiveSilenceFinder`, Core, pure)

Pauses come from the feed when there are no words (snapping without a live engine) and when the speaker stops talking (the evaluation trigger, 9.5.2).

```text
frames of silenceFrame (160) samples of the 16 kHz feed
level[f]  = Float32(sqrt(sum of squares / 160))                    (editing.md §5.1 and §4.9 rules, one channel)
every second of feed:
  quietest  = sortAscending(levels of the last silenceStatsWindow (120 s))[floor(count × 0.1)]
  threshold = max(quietest × 2, silenceFloor)                        (silenceFloor alone before 10 s of feed)
quiet(f)  = level[f] < the threshold in force when frame f arrives
silence run      = at least silenceMinRun (30) consecutive quiet frames, reported as {start, end} once closed
silenceSince(t)  = feedTime − max(t, start of the quiet run still open at the feed end), or 0 when the last frame is not quiet
```

### 9.4 "Clip that"

#### 9.4.1 Triggers

| Source | How | Default |
|---|---|---|
| Voice | a trigger phrase in the final words (9.4.2) | on when a live engine runs (`ingest.liveClips.voiceTrigger`) |
| Button | **Clip that** in the Receive toolbar, and ⌘K / Ctrl+K while the Receive window is key (the editor's "Make clip" shortcut; there is no word selection while live) | always on |
| Global shortcut | a shortcut the user records in Settings → Receive, registered only while a take is live or reconnecting. macOS: Carbon `RegisterEventHotKey`, which needs no Accessibility permission. Windows: `RegisterHotKey`; combinations with the Windows key are refused because Windows reserves them, and F12 is refused because it is reserved for debuggers ([RegisterHotKey](https://learn.microsoft.com/en-us/windows/win32/api/winuser/nf-winuser-registerhotkey)) | off (`ingest.liveClips.globalShortcut` = null) |
| Phone | **Clip that** on the stream helper page (10.7), which sends `POST /s/{helperToken}/clip` | on (`ingest.liveClips.phoneButton`) |

- Triggers are accepted while the session is `live` or `reconnecting` (section 8.1). Otherwise the button is disabled and the phone gets `409`.
- **Trigger time `T`.** Voice: the start of the first trigger word. The other sources: `feedTime` at the moment VoxClip receives the press. Feed time already includes the delay from the camera, so `T` is what the speaker had just said.
- **Coalescing.** A trigger within `clipThatCoalesce` (3 s of take time) of an earlier trigger's `T` joins that trigger's clip instead of making a new one. When a phrase is found within `clipThatCoalesce` of a press, `T` moves to the phrase start, so the phrase is cut (9.4.3).
- **Phone route.** `POST /s/{helperToken}/clip` with an empty body (`Content-Length: 0`; a non-empty body gets `400`). It passes every rule of section 10.1, including the `Host` and `Origin` checks. Replies are `application/json`:

| Status | Body | When |
|---|---|---|
| `202` | `{"ok":true,"lookbackSeconds":45}` | accepted, including when coalesced |
| `409` | `{"ok":false,"reason":"notLive"}` or `{"ok":false,"reason":"off"}` | no take is live or reconnecting, or the phone button is turned off |
| `429` | `{"ok":false,"reason":"tooMany"}` | more than `phoneClipRate` (10) requests within 60 s in this helper session |

`GET /s/{helperToken}/info` gains `"live"` (bool), `"clipThat"` (bool, the phone-button setting) and `"lookbackSeconds"` (integer).

#### 9.4.2 Phrase detection (voice)

- **Tokens.** For each final word of kind `word`: `splitWords(text)` (editing.md §4.5), then `normalizeForMatch` (editing.md §4.7) on each part. Empty parts are dropped. Each token remembers its word.
- **Sequences** (normative). Every list is active whatever the live language, because speakers mix languages. Both apps read the list from `shared/ingest/live-clip-triggers.json`, which must hold exactly this table (the fixtures job compares them; a change to one changes the other in the same commit). The longest sequence that matches wins:

| Language | Normalised token sequences |
|---|---|
| English | `okay clip that`, `ok clip that`, `clip that`, `clip this`, `clip it` |
| Estonian | `okei klipi see`, `klipi see ära`, `klipi see`, `klipi seda`, `klipi ära`, `see läheb klippi`, `see klippi`, `tee klipp` |

- **Whole words.** A match starts at a word's first token and ends at a word's last token.
- **Standalone rule.** This keeps "I'll clip that later" and "you can clip it" from triggering:
  - *Before:* the first trigger word is the take's first final word, or the word before it ends a sentence (ai.md §11.3 regex), or `first.start − previous.end ≥ clipThatPauseBefore` (0.25 s).
  - *After:* the last trigger word ends a sentence, or the next final word starts at least `clipThatPauseAfter` (0.4 s) after it, or no next final word has arrived and `silenceSince(last.end) ≥ clipThatPauseAfter`. The engine waits for one of these for at most `clipThatFinalWait` (5 s of feed time), then drops the candidate.
- A matched phrase is consumed: its words never match again.

#### 9.4.3 The clip range

With live words:

```text
(button, shortcut and phone triggers first wait until finalEdge ≥ T, or until clipThatFinalWait has passed)
E      = the newest final word with start < T that is not part of a trigger phrase, skipping back over
         items that are fillers (editing.md §6.2 isFiller) or events
target = T − lookback                                    lookback = ingest.liveClips.lookbackSeconds (default 45)
S      = the latest boundary b (9.2) at or before E with target − clipThatSnapBack ≤ b.start ≤ target,
         else the earliest boundary b with target < b.start ≤ min(target + clipThatSnapForward, E.start),
         else the first final word with start ≥ target (the take's first word if none starts earlier)
range  = words [S, E]; [start, end] = clipTimes(words, S, E)      (editing.md §7.2; the tail never reaches the trigger words)
```

Without live words (a time range):

```text
end    = r.start + min(0.25, (r.end − r.start) / 2) for the latest silence run r that starts in [T − clipThatEndSnap, T]; else T
target = T − lookback
start  = r.end − min(0.12, (r.end − r.start) / 2) for the latest run r that ends in [target − clipThatSnapBack, target],
         else the same for the earliest run that ends in (target, target + clipThatSnapForward]; else target
```

Here the silence runs include the run still open at `T`, with `r.end = T`, once it has `silenceMinRun` quiet frames: a press usually comes in the pause after the moment, and that pause is where the clip should end.

Then, in both cases: `start = max(0, start)`. If `end − start < clipThatMinSeconds` (5 s), `start = max(0, end − clipThatMinSeconds)`. If `end ≤ start` there is no clip and the window shows "Nothing to clip yet." A range longer than `clipThatMaxSeconds` (180 s) is cut from the start. With live words these clamps move `S` instead of the time, so the range stays whole words: `S` becomes the latest word whose start is at or before `end − clipThatMinSeconds` (the take's first word if none), or the first word whose start is at or after `end − clipThatMaxSeconds`, and `[start, end]` is computed again with `clipTimes`.

The title is the clip's own text (its words joined by spaces), cut at the last space within 120 UTF-16 code units, as in ai.md §11.8. A time range without words is titled "Clip at {m:ss}" with the take time of `T`.

#### 9.4.4 Captions without a live engine

When there are no live words, VoxClip transcribes just the clip so the draft gets captions:

1. Once the range is sealed (9.7.1), extract `[start − clipThatSnapBack, end]` of the sealed take as 16 kHz mono (section 7.4 rules).
2. Run the user's batch engine and routing (transcription.md) on the excerpt, with the same consent, cost and cloud rules as a dropped file. With ElevenLabs as the engine, only that excerpt's audio is uploaded, and only when its first-upload consent (`transcription.cloudConsent.elevenlabs`) is already given. Nothing prompts during the stream: if routing would ask the user anything (a language, a model download, a key or the ElevenLabs consent), the draft renders without captions (step 4). The words are offset by the excerpt start and pass through `cleanWords`.
3. Re-run 9.4.3 with these words, including the phrase check, so a spoken "clip that" is cut too. Render with them as captions.
4. If no engine is ready, the engine fails, or the take ends first, the draft renders without captions and its row says so (9.9.2). The project gets full captions after the take anyway.

Clip transcription is a heavy job (9.7.3) and runs at low priority.

#### 9.4.5 Adjusting the start (±15 s)

In the tray, **+15 s** starts the clip `clipAdjustStep` (15 s) earlier and **−15 s** starts it 15 s later. The new target is `start ∓ 15 s`, snapped with the 9.4.3 rule but searching first in the direction of the change: +15 s prefers the latest boundary at or before the target, −15 s the earliest boundary at or after it. The end never moves. The result must keep `clipThatMinSeconds ≤ length ≤ clipThatMaxSeconds` and `start ≥ 0`; otherwise the button is disabled. Adjusting works on any clip that is not kept (AI clips included), marks it seen and re-renders it.

### 9.5 AI watching (the rolling clip finder)

#### 9.5.1 Availability and connectors

- AI watching needs final live words (9.2). Without them the switch is disabled with "AI watching needs a live transcript."
- It uses the AI settings' connector and model (`llm.connector`, `llm.model.<id>`, ai.md §8.2), the same as Find clips. The connector's status must be `ready`; otherwise its ai.md §5 message shows. The Apple locale gate uses the live language.
- **Connector groups.** The `apiKey` group (Anthropic, OpenAI, xAI, Google Gemini) and the `local` group (Ollama, LM Studio, Apple Foundation Models) may watch automatically. The `cli` group (Claude Code, Codex) may not: ai.md §7.1 rule 5 allows CLI calls only for actions the user starts and forbids background or scheduled calls, and subscription plan limits assume ordinary individual use. With a CLI connector the switch is disabled and the tray offers **Find clips now**, which runs one evaluation (9.5.3 to 9.5.6) each time the user presses it. **Find clips now** works with every connector, one request at a time.
- **Per stream.** AI watching is off at the start of every Receive session, whatever happened last time. The user turns it on with the switch (9.6.2). Turning it off cancels a request in flight (ai.md §4.7; partial results are discarded).
- **Consent.** Before the first automatic request to a connector whose `privacy` is `thirdPartyCloud`, VoxClip shows the live consent sheet (9.9.4) and stores `ingest.liveClips.cloudConsent.<connectorId>`. This is separate from the Find clips consent (ai.md §4.8): sending text every minute or so for as long as a stream lasts is a different use. **Find clips now** is a single request the user starts, so it uses the Find clips consent (ai.md §4.8) instead. A local server on another host shows "Transcripts are sent to {host}" as in ai.md §8.2.

#### 9.5.2 When it evaluates

All times are take seconds from the feed (9.1, invariant 6).

```text
last     = the previous evaluation; before the first one: lastIndex = −1, feedTime = when watching was turned on
newWords = final words with index > last.lastIndex
eligible = watching, no request in flight, not backing off, not paused,
           newWords.count ≥ liveEvalMinWords (40) and feedTime − last.feedTime ≥ liveEvalMinInterval (30 s)
pause    = a final word has just arrived that starts at least liveEvalPause (1.2 s) after the previous word's end,
           or silenceSince(finalEdge) ≥ liveEvalPause (the speaker stopped and the engine has finalised everything)
fire when eligible and (pause or feedTime − last.feedTime ≥ liveEvalMaxInterval (90 s))
```

**Find clips now** fires at once when no request is in flight, without the `eligible` conditions. It still respects the budget (9.6.1).

#### 9.5.3 The window

The window reuses ai.md §11.5: absolute word numbers, absolute times, whole lines, the context budget and the overlap rule.

```text
edge   = finalEdge
anchor = max(0, floor((edge − liveWindowSeconds) / liveWindowStep) × liveWindowStep)              (240 s, 60 s)
window = the lines (9.2, closed and open) from the first line whose start ≥ anchor to the newest line
need   = the first line whose start ≥ last.edge − min(preset.maxSeconds, windowOverlapMaxSeconds)    (ai.md §11.5 overlap)
         (the first evaluation needs the whole window)
budget = ai.md §11.5 for this connector and model, with k = liveCandidatesPerCall in the overhead
while cost(window) > budget and window.first is earlier than need: drop window.first
if cost(window) > budget or the window holds more than maxWordsPerRequest words: pause with contextTooLong (9.6.3)
```

- The overlap means a clip that ends in the new words but started before the previous edge is still inside the window. With the default 240 s window, `need` is inside the window whenever evaluations are at most 150 s apart, which covers normal timing (at most 90 s). After a longer gap, such as a back-off or a quiet stretch with too few words, words older than the window are not checked: live clipping looks at the recent past only. Trimming only happens with small contexts, such as Apple's on-device model on macOS 26 (4,096 tokens). A local server model with a 4,096-token context has no room left after its 4,096-token output reserve (ai.md §11.5), so AI watching pauses with `contextTooLong`, as Find clips fails with it.
- **Cached prefix.** Rounding the start down to whole minutes keeps the window's start, and so the prefix `system + "<transcript>\n" + earlier lines`, identical for up to a minute of evaluations. Connectors with automatic prefix caching can reuse it: OpenAI, xAI, Gemini implicit caching, and the llama.cpp prompt cache behind Ollama and LM Studio. Anthropic caches at block boundaries and the transcript block grows each time, so live requests to Anthropic write the cache without reading it. The budget counts those writes (9.6.1), and section 20 asks ai.md to adjust `cache_control` and `prompt_cache_key` for live requests.

#### 9.5.4 The request

**No new preset.** The live finder reuses `shared/prompts/clip-finder.json` unchanged. Its system prompt, the `best`, `hooks` and `quotes` presets, the window lines and the `clips` schema already say everything a live window needs. The live rules (a stricter score, a finished thought, dedupe, an hourly cap) are deterministic post-processing (9.5.5 to 9.5.7) and need no prompt text. The prompt file, its parity tests and its VoxConvo provenance stay as they are, and ai.md's preset table does not change.

- **Presets.** The stream uses `ingest.liveClips.presets`, a non-empty subset of `best`, `hooks` and `quotes` (default `["best"]`), kept in that order. `topics` (one clip per topic, no overlaps) and `custom` (instructions required) do not suit a sliding window. Evaluation `n` (counting from 0) uses `presets[n mod presets.count]`. There is one request per evaluation, so the cost does not grow with the number of presets.
- **Optional instruction.** The tray's "Anything specific? (optional)" field, at most 500 UTF-16 code units after `jsTrim`, applies to this stream only and is never saved in settings; like Find clips, the take's `aiResult` records it (9.8.1). It is added with the `Also:` rule.
- **Text.** Exactly the clip finder's multi-window request (ai.md §11.4) for this window:

```text
cachedBlock = transcriptBlock.prefix + the window's rendered lines + transcriptBlock.suffix
parts = [ "The recording is " + formatTime(edge) + " long.", preset.instruction ]
if instructions != "": parts.append("Also: " + instructions)
parts.append("This part of the transcript runs from " + formatTime(window.first.start) + " to "
             + formatTime(window.last.end) + ". Other parts are handled separately.")     (request.windowLines[0])
parts.append("Return at most " + liveCandidatesPerCall + " clips.")                       (request.windowLines[1])
instruction = join("\n", parts)
```

- `LLMRequest { feature: clipFinder, system: the clip-finder system prompt, cachedBlock, instruction, schemaName: "clips", schema, maxOutputTokens and effort from the prompt file's generation, timeout from ai.md §4.4, language: the live language, tag: "live/{preset} {formatTime(edge)}" }`. It runs through `LLMRunner.run` unchanged: retries, one fallback model, extraction, one corrective retry, logging and redaction (ai.md §4).
- For a given window the rendered request is byte-identical to the clip finder's window request with `k = liveCandidatesPerCall`. The request parity fixture (`shared/fixtures/llm/clip-finder-requests.json`, test 1 of `shared/prompts/README.md`) gains a live window case (section 20).

#### 9.5.5 Reading the reply

```text
cands = LLMResult.object.clips                                                     (ai.md §2.3)
drop c unless window.firstIndex ≤ c.start_word ≤ c.end_word ≤ window.lastIndex    (integral checks stay in finalizeClips)
fin   = finalizeClips(cands, words = all final words, preset, lines = all lines (9.2), cutSet = ∅,
                      windowCount = 2, snap = llm.clips.snapToLines)
```

`windowCount = 2` turns on the near-duplicate rule of ai.md §11.7 step 7, because a live window is always part of a longer recording. Then, for each clip in `fin` order:

1. **Score.** Keep it only if `score ≥ ingest.liveClips.minScore` (default 8; the clip panel shows every score, live is stricter).
2. **Range.** `[start, end] = clipTimes(words, s, e)`.
3. **Settled.** The thought must have finished: `end ≤ edge − liveSettleSeconds` (8 s) **and** the line holding word `e` is closed. A settled clip goes to admission (9.5.6). An unsettled clip is **held**; at most `liveCandidatesPerCall` clips are held, and a newer hold replaces the oldest.
4. **Holds** from the previous evaluation are handled after this evaluation's clips. A hold that is the same moment (9.5.6) as any clip of this evaluation is dropped, because the newer view wins. Otherwise, if it is settled against this evaluation's edge, it goes to admission; if not, it is dropped. A hold never outlives one later evaluation, and a clip whose end could still move is never emitted.

#### 9.5.6 Admission: dedupe, merge and supersede

```text
overlapRatio(a, b) = ai.md §11.7 step 7 on absolute word numbers (on milliseconds when either clip is a time range)
contained(a, b)    = time intersection ≥ liveContainment (0.8) × the shorter clip's length
sameMoment(a, b)   = overlapRatio(a, b) ≥ liveSameMoment (0.6) or contained(a, b)
topicTokens(c)     = the set of normalizeForMatch(t) for every t in splitWords(text) of c's words,
                     keeping tokens of at least liveTopicTokenMin (4) UTF-16 code units
sameTopic(a, b)    = time gap between a and b ≤ liveSameTopicGap (120 s), both token sets non-empty,
                     and |A ∩ B| / |A ∪ B| ≥ liveSameTopicJaccard (0.5)
related(a, b)      = sameMoment(a, b) or sameTopic(a, b)
```

For a candidate `c` from AI watching:

1. `R` = the take's live clips `m`, in any state except `superseded`, with `related(c, m)`. Discarded clips are included, so a moment the user threw away does not come back.
2. If `R` is empty, `c` becomes a new clip, if the hourly cap allows (9.5.7).
3. Otherwise `c` **supersedes** `R` only when every `m` in `R` is an AI clip the user has not seen, and either `c.score > max(m.score)`, or the scores are equal and `c` contains every `m` in time (the thought continued) while staying within `preset.maxSeconds × maxLengthFactor`. Each `m` becomes `superseded`: its render is cancelled, its draft deleted and its notification withdrawn. `c` takes the tray position of the earliest `m` and does not use another hourly slot. This is the merge: one clip per moment, the best version.
4. Otherwise `c` is dropped.

A **"clip that"** clip is always created. It supersedes every unseen AI clip that is the same moment, because the user's own clip wins.

**Seen** means the user has interacted with the row: played, kept, shared, opened, adjusted, renamed or discarded it, or clicked its notification. Being visible on screen does not count. AI watching never replaces or changes a seen clip.

#### 9.5.7 Hourly cap

At most `ingest.liveClips.maxPerHour` (default 6) AI clips are emitted in any 3600 s of feed time. Superseding replacements and discarded clips keep their slot. At the cap, new candidates that would not supersede are dropped, and the watch state shows the hourly limit until the oldest slot expires. "Clip that" is never capped.

#### 9.5.8 When the take ends

If AI watching is on and the budget allows, the end of the take triggers one last evaluation after the live engine has flushed its final words, with `edge = finalEdge` and the settled rule waived (the take is over). Its clips render from the finished file. Then AI watching stops. This evaluation is the take's project's one LLM run (ai.md §4.7), so Find clips in the editor waits until it finishes. A new take in the same session (a format change, section 8.5) starts with fresh words, numbers, holds and clips; the session's budget carries over.

### 9.6 Cost and privacy guard

#### 9.6.1 Budget per stream

The budget belongs to the Receive session and applies to `thirdPartyCloud` connectors. Local and on-device connectors cost nothing and have no budget. They still follow the timing rules and the priority gates (9.7.3), because a local model competes with the live engine and the renderer for the GPU.

```text
estimate(r) = est(system) + est(cachedBlock) + est(instruction) + liveOutputReserve (2,000)    (est from ai.md §11.5)
send r only if calls < ingest.liveClips.budgetCalls (default 120)
           and tokens + estimate(r) ≤ ingest.liveClips.budgetTokens (default 400,000)
after the reply:
  calls  += 1          (retries, the fallback model and the corrective retry inside one run count once)
  tokens += actual     Anthropic: input + output + cacheRead + cacheWrite (its input excludes cached tokens)
                       other connectors: input + output (their input includes cached tokens)
                       usage missing: estimate(r) − liveOutputReserve + est(reply text)
```

The defaults allow about two hours at one check a minute. **Find clips now** counts towards the budget, and it is refused with the budget copy once the budget is spent.

When the budget is reached, AI watching pauses: a request in flight finishes, no new one starts, and the tray shows the budget notice with **Keep watching**, which grants this stream one more budget of the same size. AI watching never resumes by itself.

#### 9.6.2 Indicator and off switch

While AI watching is on, the Receive toolbar shows the pill **AI watching · {label}** with a switch. `{label}` is the catalog label in plain text with no logo (ai.md §7.1 rule 6), or "{label} at {host}" for a local server on another host. The pill's popover shows the connector and model, the presets, the minimum score, the usage line ("{calls} of {maxCalls} checks · about {tokens} of {maxTokens} tokens" for cloud connectors; "Runs on this {Mac/PC}. Nothing leaves it." for local ones; "Runs on {host}." for a local server on another host) and **Turn off**. The tray header repeats the state (9.9.3). Switching off takes effect at once.

#### 9.6.3 Errors and back-off

The runner's own retries and fallback (ai.md §4.2, §4.3) run first. Then, for the final error of an evaluation:

| Error (ai.md §5) | AI watching |
|---|---|
| `rateLimited(retryAfter)`, `planLimit`, `overloaded`, `server`, `timeout`, `network` | Back off: no evaluation before `feedTime + max(retryAfter ?? 0, 60 s × 2^(n − 1))`, at most 600 s, where `n` counts consecutive failures. After 3 consecutive failures, pause |
| `invalidOutput`, `truncated`, `refused` | No clips from this window. Counts towards the 3 consecutive failures; no back-off |
| `noConnector`, `missingKey`, `unauthorized`, `quotaExceeded`, `modelNotFound`, `contextTooLong`, `badRequest`, `notRunning`, `noModels`, `unavailable`, `unsupportedLanguage`, `cliMissing`, `cliTooOld`, `cliSignedOut`, `cliFailed` | Pause at once |
| `cancelled` | Nothing (switched off, or the take ended) |

A success resets `n`. A paused finder resumes only through **Try again** in the tray. **Find clips now** shows its error and never retries by itself; it is the only path to a CLI connector, so a subscription plan limit stops there.

#### 9.6.4 Defaults

| Feature | Default |
|---|---|
| AI watching | off at the start of every stream; never stored |
| Voice "clip that" | on, when a live engine runs |
| **Clip that** button and ⌘K / Ctrl+K | always on |
| Phone **Clip that** button | on |
| Global shortcut | off |
| Notifications for strong AI clips | on; permission is asked when AI watching is first turned on |
| Presets, minimum score, clips per hour, budget | `best`, 8, 6, 120 checks and 400,000 tokens |

### 9.7 Rendering while live

#### 9.7.1 The sealed take

The **horizon** is the take time up to which every video frame and audio sample is durably on disk and readable. The part before it is the **sealed span**. Sealed data never changes: the recorder only appends, inserted silence goes after the audio already written, and dropped audio is removed from new blocks only (section 7.3).

- **macOS.** In the app the writer uses `movieFragmentInterval = liveFragmentInterval` (2 s) instead of 10 s (section 8.3); the finished file is the same normal movie. A long-lived `AVFragmentedAsset` on `<name>.partial.mov`, watched by an `AVFragmentedAssetMinder` with `mindingInterval = liveMinderInterval` (1 s), reports growth. `horizon` is the smaller of the asset's video and audio track end times. Each render opens its own `AVFragmentedAsset` for the same URL, because AVFoundation graphs are never shared across isolation domains (architecture.md §7.1). Reading the sealed part of a fragmented movie while AVAssetWriter appends to it is not yet measured: test L-B1 (9.13) must pass before this ships. If it fails, macOS adopts the Windows design below (a journal and a `LiveTakeIndex` next to the partial movie), and this spec changes in the same commit.
- **Windows.** The final movie is not fragmented (section 8.4), so drafts read the journal. While live, the recorder also keeps a `LiveTakeIndex` in memory: for each video frame, its journal offset and length, its rebased `dts90` and `pts90` (section 7.2) and the keyframe flag; for each audio tag, its journal offset and length and its `AudioSampleClock.Placement`. After every `Flush(true)` (section 8.4) it publishes `flushedBytes` and `horizon = min(DTS of the newest flushed video frame, end of the newest flushed audio placement)`. Every frame whose PTS is at or before that DTS has already arrived, because PTS ≥ DTS. `JournalPacketSource` opens the journal with `FileShare.ReadWrite | FileShare.Delete`, reads only entries below `flushedBytes`, parses tags with Core's `FLVTagParser` and feeds the export decoders. Audio is decoded and written at the recorded placements, with silence where the recorder inserted it, so the decoded samples equal the finished movie's for the same range. Because AAC frames overlap, a cold decoder's first frames differ from the recorder's continuous decode: the source starts decoding a few AAC frames before the range (from the last decoder start, such as a reconnect, if that is nearer) and discards that output. L-B1 checks the result.
- **Eligibility.** A clip renders once `end + liveRenderGuard ≤ horizon` (1 s, which covers B-frame reordering and the last audio block). Until then it is `waiting`. A "clip that" draft therefore starts about 1 to 4 s after the trigger, plus the final-word wait for voice triggers and for presses while a live engine runs.

#### 9.7.2 The draft's plan and captions

- **Clip with words.** The transcript is the take's final live words as `TimedWord`s (`id` "L{index + 1}", `timing: native`, optional fields null), with no cuts and the active clip `[S, E]`. `buildSegments` and `buildEditPlan` run exactly as in editing.md §7, with `duration = horizon` and `sampleRate` = the take's audio rate (48,000 for a video-only take). Captions: `captionCopy` (editing.md §7.6), then the captions engine with the session's style.
- **Time range.** Segments `[{id: "clip-head", kind: range, start: 0, end: start, cut: true}, {id: "clip-tail", kind: range, start: end, end: end + 3600, cut: true}]`, each omitted when empty as in editing.md §7.1 (§2.6 allows exact range segments; they are always cut). No captions, unless clip transcription produced words (9.4.4); those words then act as the transcript.
- **Output.** The export path for one clip (architecture.md §4 step 9, §4.1): MP4, H.264, AAC, the session's aspect and caption style, quality Standard, no `.srt`, written to the draft path as `.partial` and renamed on success. The session's aspect and style start as `export.defaultAspect` and `captions.defaultStyleId` and can be changed in the tray header. A change re-renders drafts that are ready and not kept. When the take's project is created, its `export.aspect` and `captions.styleId` take the session's values.
- Each draft records `horizonAtRender`.

#### 9.7.3 Scheduling and priority

- **One heavy job at a time per session**: a render, a clip transcription (9.4.4) or a local-model evaluation. Order: "clip that" clips in trigger order, then AI clips by score, then re-renders.
- **macOS.** `LiveClipRenderer` is an actor. Its work runs in `Task(priority: .utility)`, and its reader and writer pump queues use QoS utility. **Windows.** The render runs on the dedicated thread `vc-live-render` at `ThreadPriority.BelowNormal`, decoding with D3D11VA when available (architecture.md §6.2).
- **Gates**, checked between frames and between work units. While a gate holds, the job pauses (it never fails for this reason) and resumes once the condition has been clear for `liveRenderResume` (2 s):
  1. *Recorder pressure.* macOS: a recorder input has not been ready for more data for more than 250 ms. Windows: the `vc-ingest-mux` channel holds more than 256 of its 512 packets.
  2. *Live engine lag.* `feedTime − processedThrough > liveRenderPauseLag` (4 s).
- **Disk.** A job starts only with at least `freeDiskToContinue` + 1 GB free on the draft folder's volume; otherwise the clip fails with `diskFull`.
- The receiver and the recorder never wait for live clipping. They publish the horizon, the index and the pressure signal; nothing flows back to them.

#### 9.7.4 When the take ends

1. Finalizing (sections 8.3 and 8.4) first cancels running live renders and clip transcriptions. It never waits for them.
2. After finalizing, the cancelled jobs restart and waiting clips render from the finished `.mov`. File seconds equal take seconds, so ranges carry over unchanged.
3. A draft that **touched the last fragment**, that is whose `end + liveRenderGuard` is later than `horizonAtRender − liveFragmentInterval` (macOS) or `horizonAtRender − journalFlushInterval` (Windows), is re-rendered from the finished file unless it is kept. Test L-B1 shows that sealed reads equal final reads; this rule guards the one case the test cannot cover, a writer that rewrites its last fragment when it finishes.
4. Kept files are never rewritten (9.7.5).

#### 9.7.5 Files

- **Drafts** live in `<data>/Cache/LiveClips/<takeId>/<clipId>.mp4`. A draft is deleted when its clip is discarded or superseded. The folder is deleted when the window closes, after 9.8.1 has stored the clips as clip ranges. At launch, draft folders older than `draftMaxAge` (24 h) that no session owns are deleted.
- **Keep** copies the draft to the export folder (`export.folder`, default per architecture.md §2.5) with the Export sheet's file name pattern (`export.fileNamePattern`, default `{project}-{clip}-{aspect}`, plus `.mp4`; design.md §8), where `{project}` is the take name without its extension and `{clip}` the clip title, de-duplicated the same way. A kept file belongs to the user: VoxClip never overwrites, moves or deletes it.

### 9.8 After the take

#### 9.8.1 Clips in the take's project

When the take's batch transcript is ready (section 8.6), every live clip that is not discarded or superseded becomes a clip range in the project, in one undo step named "Clips from this stream" that groups every operation below, `addAIClips` included:

```text
items = the project's transcript items
S = the first item whose midpoint (start + end) / 2 ≥ the clip's start
E = the last item whose midpoint ≤ the clip's end
no such S and E, or S > E: the clip is not placed; its row says so (9.9.2) and it is logged
llm.clips.snapToLines: snap S and E to the batch transcript's lines with ai.md §11.7 step 3
```

- **AI clips.** For each preset used in the take, one `aiResult` (ai.md §11.8) is appended with `provider`, `model` (the last answering model), `preset`, `instructions` (the optional instruction of the first request that produced one of its clips, or null), `language`, `inputSha256` (SHA-256 of the `cachedBlock` of the first request that produced one of its clips) and its clips in start order with batch word ids. Then `addAIClips` (editing.md §6.3) runs. The live blocks hash differently from the batch block, so the editor marks these results as made from an older transcript (editing.md §10.6), which is accurate.
- **"Clip that" clips.** `addClip(S, E, origin: manual)` with the clip's title.
- The Clips list checkbox (`selected`) stays on for kept clips and is turned off for the others, in the same undo step.
- This runs once per take; the take sidecar records `"liveClipsApplied": true` (section 4.3). The project format does not change.

#### 9.8.2 The camera's own recording

Replacing the take with the camera original in place needs a source time offset in the project format, and stays later (section 21). Live clips take a narrower path that needs no format change, because the camera file becomes its own project (ING-9):

1. When a file arrives through Import from a connected camera (section 12.1), the camera inbox (section 11) or Send from your phone (section 10), VoxClip compares it with the takes of the last 7 days that have live clips. It matches when its creation time (QuickTime `creationdate`, else the container's `creation_time`) lies within `cameraMatchWindow` (10 min) of the take's start and its duration is at least half the take's.
2. On a match, the take's project shows "The camera's own recording of this take is in VoxClip. Make sharper clips from it?" [Use camera file]. Nothing happens without that click.
3. **Use camera file** opens the camera file as a normal project, with its own import and batch transcript, then places each clip range of the take's project:
   - *Coarse offset:* normalized cross-correlation of the two cached 10 ms level envelopes (architecture.md §8.2), over the whole camera file for the first clip and within ±60 s of the previous clip's offset for the others.
   - *Fine offset:* cross-correlation of the two 16 kHz WAVs within `cameraFineSearch` (±50 ms) of the coarse lag, over the clip's own range.
   - The offset is found per clip, because a reconnect removes the dropped interval from the take (section 7.1) while the camera kept recording.
   - A clip is placed when the coarse peak's normalized correlation is at least `cameraMatchMinCorrelation` (0.5, to be tuned with H7 recordings): its times are shifted by the offset and placed with the 9.8.1 rule. AI clips get a copy of their `aiResult` with the camera project's word ids.
   - Clips that do not match are listed: "{n} clips couldn't be matched to the camera file."
4. The take, its project and its clips are never changed or deleted.

Whether the camera records internally while it streams is hardware test H7, so this part ships only after H7 passes (9.14).

### 9.9 UX: the tray, AI watching, notifications and exact copy

Voice and conventions as in section 15. `{⌘K/Ctrl+K}` is ⌘K on macOS and Ctrl+K on Windows.

#### 9.9.1 Layout

The tray is a trailing column of the Receive window, 320 wide, next to the preview, shown or hidden with a toolbar button. When the take ends and the window becomes the editor, the tray stays open until the user closes it; by then its clips are also in the Clips list (9.8.1).

```text
┌ Receive from camera ─ REC ● 41:12 ─ [AI watching · Anthropic ◉] ─ [Clip that] ─ [End take] ─────────────────────┐
│ ┌────────────────────── preview ─────────────────────┐  Clips from this stream · 3          9:16 ▾  Highlight ▾ │
│ │                                                    │  ● ┌──────┐ Why pricing is a story       0:42 · AI 9/10 │
│ │                                                    │    │thumb │ Ready to review · Best moments              │
│ │                                                    │    └──────┘ ▶  Keep  Share…  Open in editor  Discard   │
│ └────────────────────────────────────────────────────┘             Start  +15 s  −15 s                         │
│  live transcript …                                        ┌──────┐ Clip at 38:05                   0:45 · You  │
│                                                           │      │ Rendering · 62%                  Discard    │
│                                                           └──────┘                                             │
│                                                           Anything specific? (optional)     [Find clips now]   │
│                                                           Nothing is posted until you share it.                │
└────────────────────────────────────────────────────────────────────────────────────────────────────────────────┘
```

- **Header:** "Clips from this stream · {n}", an Aspect menu (Source, 16:9, 9:16, 1:1) and a Captions menu (the gallery's styles and Off).
- **Row:** a thumbnail (the draft's first frame), the title (`typography.bodyStrong`), the length `m:ss` (Geist Mono), the origin ("You" for "clip that", "AI {score}/10" for AI clips), a state line and the actions. Unseen rows show an accent dot. Rows are in creation order; a superseding clip takes its predecessor's place.
- **Footer:** the "Anything specific? (optional)" field and **Find clips now**, both hidden without a live transcript or a ready connector, and the line "Nothing is posted until you share it."

#### 9.9.2 Rows

| State | State line | Actions |
|---|---|---|
| waiting ("clip that") | "Saving the last {n} seconds…" | Discard |
| waiting (AI) | "Saving this moment…" | Discard |
| transcribing (9.4.4) | "Adding captions…" | Discard |
| rendering | "Rendering · {p}%" | Discard |
| render paused (9.7.3) | "Rendering paused while the stream catches up" | Discard |
| ready | "Ready to review" ("clip that"); "Ready to review · {preset label}" (AI) | ▶, Keep, Share…, Open in editor, Discard, Start +15 s / −15 s |
| ready without captions | "Ready to review · no captions in this draft. The project gets them when the take ends." | as ready |
| updating (9.7.4) | "Updating with the finished take…" | Discard |
| kept | "Kept · saved to {folder}" | ▶, Share…, Open in editor, Show in Finder / Show in Explorer |
| failed | "Couldn't render this clip: {reason}. The stream is still being recorded." | Try again, Discard |
| in the project (9.8.1) | "In this project's clips" | ▶, Keep (if not kept), Share…, Open in editor |
| not placed (9.8.1) | "Couldn't place this clip in the final transcript. The draft is still here." | ▶, Keep, Share…, Discard |

- **▶** plays the draft inline (`AVPlayerView` / `MediaPlayerElement`) with sound.
- **Keep** copies the draft to the export folder (9.7.5).
- **Share…** keeps the clip first if needed, then shows publishing.md §2's share helpers for that file: Show in Finder / Show in Explorer, Copy caption, Open X, Open LinkedIn, and drag out. The caption is publishing.md §2.1's default, from the title and the clip's first sentence. From M2, when VoxConvo is connected, the explicit VoxConvo post action of publishing.md §3 is offered with its own confirmation. **Share…** itself posts nothing.
- **Open in editor** is disabled while live, with the tooltip "Available when the take ends." After 9.8.1 it opens the clip in the editor (`setActiveClip`).
- **Discard** removes the row and deletes the draft; "Clip discarded." [Undo] shows for 6 s. A discarded clip never becomes a clip range, and related AI finds are not added again (9.5.6).
- **Start +15 s / −15 s**: 9.4.5. Accessibility labels "Start 15 seconds earlier" and "Start 15 seconds later".
- **Keyboard**, with focus in the tray list: ↑ / ↓ select, Return or Space plays and pauses the selected draft, ⌫ / Delete discards (with undo). While focus is in the tray, Space does not end the take.

Hints and transient messages:

| Situation | Copy |
|---|---|
| Empty, live engine running | "Say “clip that”, press {⌘K/Ctrl+K} or tap Clip that on your phone to save the last {n} seconds." |
| Empty, no live engine | "Press {⌘K/Ctrl+K} or tap Clip that on your phone to save the last {n} seconds." |
| Empty, AI watching on | "AI is watching for strong moments. Clips appear here for you to review. Nothing is posted." |
| Trigger accepted | "Saving the last {n} seconds." (transient, 3 s) |
| Trigger with nothing recorded | "Nothing to clip yet." (transient, 3 s) |
| Global shortcut taken (Settings → Receive) | "Another app uses this shortcut. Choose another." |

#### 9.9.3 AI watching states

| State | Toolbar and tray copy | Actions |
|---|---|---|
| off | Switch "AI watching" off. Tray footnote: "AI watching looks for strong moments in the live transcript with the AI you chose in Settings → AI. It's off until you turn it on for this stream." | turn on |
| on | "AI watching · {label}"; the popover's usage line (9.6.2) | Turn off |
| checking | "Checking the last {m} minutes…" | Turn off |
| no live transcript | "AI watching needs a live transcript." (switch disabled) | — |
| CLI connector | "AI watching needs an API key or a model on this computer. Installed CLIs run only when you ask, so use Find clips now." | Find clips now, Open AI settings |
| no connector, or not ready | the ai.md §5 message | Open AI settings |
| backing off | "{label} is busy. VoxClip will check again in {n} s." | Turn off |
| hourly limit | "AI added {n} clips in the last hour, the most it adds. It looks again at {time}." | Turn off, Settings |
| budget reached | "AI watching paused: this stream used its budget of {calls} checks and about {tokens} tokens." | Keep watching, Settings |
| paused after an error | "{ai.md §5 message} AI watching is paused. The stream is still being recorded and “clip that” still works." | Try again, Turn off |

#### 9.9.4 Live consent sheet (cloud connectors, once per connector)

Title "Let {label} watch this stream?" Body "AI watching sends the live transcript to {label} with your API key, a few minutes of text at a time, about once a minute while the stream runs. No audio or video is sent. This stream can use up to {calls} requests and about {tokens} tokens before it pauses." Buttons **Start watching**, **Cancel**.

#### 9.9.5 Notifications

- Only for AI clips with `score ≥ minScore + notifyScoreBonus` (default 9), only while the Receive window is not key or VoxClip is not active, at most one per `notifyMinGap` (300 s; finds in between are counted into the next one), and only with `ingest.liveClips.notify` on. Never for "clip that" (the user already knows) and never with sound.
- Copy: title "Clip ready to review", body "{title} · {m:ss} · {score}/10". Grouped: title "{n} clips ready to review", body "From your live stream in VoxClip."
- **macOS:** `UNUserNotificationCenter`. Authorization (`.alert` only) is requested when the user first turns on AI watching, never at launch. Each take uses one request identifier, `voxclip.liveclip.<takeId>`, so a newer notification replaces the older one; a superseded clip's notification is removed. A click activates VoxClip, brings the Receive window forward, selects the clip and marks it seen. Ad-hoc signed builds may not show notifications; the tray is always the source of truth.
- **Windows:** Windows App SDK `AppNotificationManager` ([quickstart](https://learn.microsoft.com/en-us/windows/apps/develop/notifications/app-notifications/app-notifications-quickstart)). `Register()` is called in `Program.Main` before `Application.Start`; that it registers the activator for an unpackaged app is check W-7 (section 18.8). Tag = clip id, group = `liveclips-<takeId>`; `RemoveByTagAndGroupAsync` on supersede. A click activates the running instance (architecture.md §2.6) with the argument `liveclip=<takeId>/<clipId>`. App notifications do not work for elevated processes; VoxClip's only elevated mode, the firewall helper, never notifies.

#### 9.9.6 Accessibility

- The tray is a list; each row reads its title, length, origin and state.
- Announcements: "Saving the last {n} seconds" (trigger), "New clip to review: {title}" (AI clip, polite), "Clip kept", "Clip discarded", "AI watching on", "AI watching off", "AI watching paused".
- Under Reduce Motion, rows appear without animation.

### 9.10 Persistence, recovery and logging

- **Live store.** While a take is live, its clips are written to `<data>/Ingest/Live/<takeId>.json` (atomic, debounced 1 s):

  ```json
  { "schema": "voxclip-live-clips/1", "takeFile": "2026-10-25 14.03 Live take.partial.mov",
    "clips": [ { "id": "lc3", "title": "Why pricing is a story",
                 "origin": { "kind": "finder", "preset": "best", "score": 9, "reason": "…", "connector": "anthropic",
                             "model": "claude-sonnet-5-5", "inputSha256": "<64 hex>" },
                 "start": 2240.88, "end": 2283.15, "firstWord": 5120, "lastWord": 5233,
                 "state": "kept", "seen": true, "draft": "<path>", "kept": "<path>" } ],
    "budget": { "calls": 38, "tokens": 91840 } }
  ```

  `origin.kind` is `trigger` (with `source`) or `finder`. Time-range clips omit the word numbers. The store holds no keys and no transcript text other than titles and reasons, which the project stores anyway.
- **At finalize** the store's clips are copied into the take sidecar as `liveClips`, with `"liveClipsApplied": false` (section 4.3), and the store is deleted.
- **Crash recovery** (section 8.7): a recovered take adopts its live store, matched by take file name. Ready drafts stay, waiting clips render from the recovered file, and the clips go into the project after its batch transcript as in 9.8.1.
- **Logging** (category `ingest`, metadata only): `live-trigger source=phone t=2291.42 coalesced=false`; `live-eval preset=best edge=2290.10 words=598 estTokens=2410` (the runner adds its own `llm` line, ai.md §4.9); `live-candidates returned=2 valid=2 aboveScore=1 held=0 emitted=1 superseded=0 dropped=1`; `live-render clip=lc3 seconds=45.20 ms=9120 pausedMs=1800`; `live-watch state=paused reason=budget`. Never transcript text, titles, reasons, trigger phrases or the stream's instruction.

### 9.11 Type sketches

Shapes, not final code, in the style of section 16. The pure types live in `Domain/Ingest/LiveClips/` and use the pure AI parts of Core (`formatTranscript`, `finalizeClips`, request rendering, `est`) and its value types (`LLMRequest`, `LLMResult`, `LLMError`).

```swift
// VoxClipCore/Domain/Ingest/LiveClips — pure, Sendable values (fixture-tested)
public struct LiveWord: Sendable, Equatable {
    public let index: Int                              // absolute number among the take's final words, from 0
    public let text: String                            // after cleanWords
    public let kind: WordKind                          // .word or .event
    public let start: Double, end: Double              // take seconds (= file seconds of the finished take)
}
public enum LiveTranscriptEvent: Sendable, Equatable {
    case final([LiveWord])                             // append-only, never revised
    case processed(throughSeconds: Double)
    case volatileText(String)                          // display only; ignored by LiveClipEngine
}
public struct SilenceRun: Sendable, Equatable { public let start: Double, end: Double }
public struct LiveSilenceFinder: Sendable {
    public init(limits: LiveClipLimits)
    public mutating func append(_ samples: [Float], firstSample: Int64) -> [SilenceRun]   // runs closed by this chunk
    public func silenceSince(_ t: Double) -> Double
}
public struct TriggerPhrase: Sendable, Equatable, Codable { public let language: String; public let tokens: [String] }
public struct TriggerMatch: Sendable, Equatable { public let firstWord: Int, lastWord: Int, start: Double }
public enum LiveTriggerMatcher {
    public enum Outcome: Sendable, Equatable { case none, pending(untilFeedSeconds: Double), matched(TriggerMatch) }
    public static func tokens(of word: LiveWord) -> [String]                               // splitWords + normalizeForMatch
    public static func scan(_ words: ArraySlice<LiveWord>, phrases: [TriggerPhrase], silenceSince: Double,
                            feedTime: Double, limits: LiveClipLimits) -> Outcome          // standalone rule, §9.4.2
}
public enum LiveRange: Sendable, Equatable { case words(first: Int, last: Int), time(start: Double, end: Double) }
public enum LiveClipSnapper {
    public static func clipThat(at t: Double, phrase: TriggerMatch?, words: [LiveWord], lines: [TranscriptLine],
                                silences: [SilenceRun], lookback: Double, limits: LiveClipLimits) -> LiveRange?
    public static func adjustStart(_ range: LiveRange, bySeconds: Double, words: [LiveWord], lines: [TranscriptLine],
                                   silences: [SilenceRun], limits: LiveClipLimits) -> LiveRange?   // nil: button disabled
}
public enum ClipTriggerSource: String, Sendable, Codable { case voice, button, shortcut, phone }
public struct LiveClip: Sendable, Equatable, Identifiable {
    public enum Origin: Sendable, Equatable {
        case trigger(ClipTriggerSource)
        case finder(preset: String, score: Int, reason: String, connector: ConnectorID, model: String)
    }
    public enum State: Sendable, Equatable {
        case waiting, transcribing, rendering(progress: Double), renderPaused, updating
        case ready(draft: String, captions: Bool), kept(file: String), failed(VoxClipError)
        case inProject, notPlaced, superseded, discarded
    }
    public let id: String
    public var title: String
    public var range: LiveRange
    public var start: Double, end: Double              // padded take seconds (clipTimes, or the snapped time range)
    public var origin: Origin
    public var state: State
    public var seen: Bool
    public var horizonAtRender: Double?
}
public enum WatchState: Sendable, Equatable {
    case off
    case unavailable(WatchUnavailable)                 // .noLiveWords, .cliConnector, .connector(LLMError)
    case watching(calls: Int, tokens: Int, checking: Bool)
    case backingOff(untilFeedSeconds: Double, LLMError)
    case paused(WatchPause)                            // .budget, .hourlyLimit(untilFeedSeconds:), .error(LLMError)
}
public struct LiveClipSettings: Sendable, Equatable {
    public var voiceTrigger: Bool, phoneButton: Bool, lookbackSeconds: Int
    public var presets: [String], minScore: Int, maxPerHour: Int, budgetCalls: Int, budgetTokens: Int
    public var notify: Bool, snapToLines: Bool
    public var instructions: String?                   // this stream only; never saved in settings
}
public struct LiveConnectorInfo: Sendable, Equatable {
    public let id: ConnectorID, group: String, privacy: String, model: String
    public let contextTokens: Int?, maxOutputTokensCap: Int?, liveConsent: Bool
}
public struct LiveRenderJob: Sendable, Equatable {
    public let clipID: String
    public let segments: [EditSegment]                 // §9.7.2
    public let captionWords: [TimedWord]               // live words or clip-transcription words; empty: no captions
    public let duration: Double, sampleRate: Double    // horizon (or the finished duration) and the take's audio rate
    public let styleID: String, aspect: AspectRatio
    public let output: String                          // draft path
    public let fromFinishedFile: Bool
}

/// Sans-I/O live clip engine. Deterministic: its only clock is take time from the feed.
public struct LiveClipEngine: Sendable {
    public enum Input: Sendable {
        case transcript(LiveTranscriptEvent), silence(runs: [SilenceRun], since: Double), feed(seconds: Double), horizon(Double)
        case trigger(ClipTriggerSource)
        case setWatching(Bool), liveConsentGiven(ConnectorID), findNow(instructions: String?)
        case evaluationFinished(id: Int, Result<LLMResult, LLMError>)
        case clipTranscribed(clipID: String, Result<[LiveWord], VoxClipError>)
        case render(clipID: String, LiveRenderEvent)            // progress, paused, resumed, finished(Result<String, VoxClipError>)
        case user(clipID: String?, LiveClipUserAction)         // play, keep(file:), share, open, discard, undoDiscard, adjust(seconds:),
                                                                // rename, setStyle, setAspect, keepWatching, retryWatching, notificationClicked
        case takeEnded(finishedFile: String), batchTranscriptReady(Transcript)
    }
    public enum Action: Sendable, Equatable {
        case evaluate(id: Int, LLMRequest), cancelEvaluation(id: Int)
        case transcribeClip(clipID: String, start: Double, end: Double)
        case render(LiveRenderJob), cancelRender(clipID: String), deleteDraft(String)
        case copyToExportFolder(clipID: String, draft: String)
        case requestLiveConsent(ConnectorID), notify(LiveClipNotice), withdrawNotice(takeID: String, clipID: String)
        case applyToProject(LiveProjectPatch)                   // aiResults plus clip operations, one undo step (§9.8.1)
        case persist, log(String)                               // metadata only (§9.10)
    }
    public init(takeID: String, settings: LiveClipSettings, connector: LiveConnectorInfo?, prompt: ClipFinderPrompt,
                phrases: [TriggerPhrase], limits: LiveClipLimits)
    public mutating func handle(_ input: Input) -> [Action]
    public private(set) var clips: [LiveClip]
    public private(set) var watch: WatchState
}
public struct LiveTakeIndex: Sendable {                         // Windows recorder; also the macOS fallback (§9.7.1)
    public mutating func addVideo(offset: Int64, length: Int32, dts90: Int64, pts90: Int64, keyframe: Bool)
    public mutating func addAudio(offset: Int64, length: Int32, placement: AudioSampleClock.Placement)
    public func horizon(flushedBytes: Int64, sampleRate: Int) -> Double
}

// VoxClipMedia/Ingest/LiveClips — I/O
public protocol LiveTakeSource: Sendable {                      // §9.7.1
    nonisolated var horizon: AsyncStream<Double> { get }        // AVFragmentedAssetMinder growth, then the finished duration
    func openAsset() async throws(VoxClipError) -> AVAsset      // a fresh AVFragmentedAsset per render, or the finished file
}
public actor LiveClipRenderer {                                 // FrameCompositor + the export writer, QoS utility, §9.7.3 gates
    public init(gates: LiveRenderGates)
    public func render(_ job: LiveRenderJob, from source: any LiveTakeSource) -> AsyncThrowingStream<LiveRenderEvent, any Error>
}
public protocol ClipTranscriber: Sendable {                     // §9.4.4: the user's batch engine on a sealed excerpt
    func transcribe(excerpt: URL, offsetSeconds: Double) async throws(VoxClipError) -> [LiveWord]
}
public actor LiveClipCoordinator {                              // owns the engine; drives LLMRunner, renderer, transcriber, store
    public init(engine: LiveClipEngine, runner: LLMRunner, connector: (any LLMConnector)?, source: any LiveTakeSource,
                renderer: LiveClipRenderer, transcriber: (any ClipTranscriber)?, store: LiveClipStore)
    public nonisolated var updates: AsyncStream<LiveClipsSnapshot> { get }   // clips, watch state, notices; coalesced to 10 Hz
    public func send(_ input: LiveClipEngine.Input) async
}

// VoxClip (app)
@MainActor @Observable final class LiveClipsModel {
    private(set) var clips: [LiveClip] = []
    private(set) var watch: WatchState = .off
    var aspect: AspectRatio
    var styleID: String
    func clipThat(_ source: ClipTriggerSource) async
    func setWatching(_ on: Bool) async                          // live consent sheet first for cloud connectors (§9.9.4)
    func findNow(instructions: String?) async
    func play(_ id: String)
    func keep(_ id: String) async
    func share(_ id: String) async                              // keep, then publishing.md §2 share helpers
    func discard(_ id: String)
    func undoDiscard()
    func adjust(_ id: String, bySeconds: Double) async
    func openInEditor(_ id: String)
}
// The app also owns GlobalClipShortcut (Carbon RegisterEventHotKey) and LiveClipNotifier (UNUserNotificationCenter).
```

```csharp
// VoxClip.Core/Domain/Ingest/LiveClips — pure, immutable where possible
public sealed record LiveWord(int Index, string Text, WordKind Kind, double Start, double End);
public abstract record LiveTranscriptEvent
{
    public sealed record Final(IReadOnlyList<LiveWord> Words) : LiveTranscriptEvent;
    public sealed record Processed(double ThroughSeconds) : LiveTranscriptEvent;
    public sealed record VolatileText(string Text) : LiveTranscriptEvent;
}
public readonly record struct SilenceRun(double Start, double End);
public sealed class LiveSilenceFinder(LiveClipLimits limits)
{
    public IReadOnlyList<SilenceRun> Append(ReadOnlySpan<float> samples, long firstSample);
    public double SilenceSince(double t);
}
public sealed record TriggerPhrase(string Language, IReadOnlyList<string> Tokens);
public readonly record struct TriggerMatch(int FirstWord, int LastWord, double Start);
public static class LiveTriggerMatcher
{
    public static IReadOnlyList<string> Tokens(LiveWord word);
    public static TriggerScan Scan(IReadOnlyList<LiveWord> words, int fromIndex, IReadOnlyList<TriggerPhrase> phrases,
                                   double silenceSince, double feedTime, LiveClipLimits limits);   // None, Pending(until), Matched(match)
}
public abstract record LiveRange
{
    public sealed record Words(int First, int Last) : LiveRange;
    public sealed record Time(double Start, double End) : LiveRange;
}
public static class LiveClipSnapper
{
    public static LiveRange? ClipThat(double t, TriggerMatch? phrase, IReadOnlyList<LiveWord> words, IReadOnlyList<TranscriptLine> lines,
                                      IReadOnlyList<SilenceRun> silences, double lookback, LiveClipLimits limits);
    public static LiveRange? AdjustStart(LiveRange range, double bySeconds, IReadOnlyList<LiveWord> words,
                                         IReadOnlyList<TranscriptLine> lines, IReadOnlyList<SilenceRun> silences, LiveClipLimits limits);
}
public enum ClipTriggerSource { Voice, Button, Shortcut, Phone }
public abstract record LiveClipOrigin
{
    public sealed record Trigger(ClipTriggerSource Source) : LiveClipOrigin;
    public sealed record Finder(string Preset, int Score, string Reason, ConnectorId Connector, string Model) : LiveClipOrigin;
}
public abstract record LiveClipState
{
    public sealed record Waiting : LiveClipState;
    public sealed record Transcribing : LiveClipState;
    public sealed record Rendering(double Progress) : LiveClipState;
    public sealed record RenderPaused : LiveClipState;
    public sealed record Updating : LiveClipState;
    public sealed record Ready(string Draft, bool Captions) : LiveClipState;
    public sealed record Kept(string File) : LiveClipState;
    public sealed record Failed(VoxClipError Error) : LiveClipState;
    public sealed record InProject : LiveClipState;
    public sealed record NotPlaced : LiveClipState;
    public sealed record Superseded : LiveClipState;
    public sealed record Discarded : LiveClipState;
}
public sealed record LiveClip(string Id, string Title, LiveRange Range, double Start, double End, LiveClipOrigin Origin,
                              LiveClipState State, bool Seen, double? HorizonAtRender);
public abstract record WatchState
{
    public sealed record Off : WatchState;
    public sealed record Unavailable(WatchUnavailable Reason) : WatchState;
    public sealed record Watching(int Calls, long Tokens, bool Checking) : WatchState;
    public sealed record BackingOff(double UntilFeedSeconds, LlmError Error) : WatchState;
    public sealed record Paused(WatchPause Reason) : WatchState;
}
public sealed record LiveClipSettings(bool VoiceTrigger, bool PhoneButton, int LookbackSeconds, IReadOnlyList<string> Presets,
                                      int MinScore, int MaxPerHour, int BudgetCalls, long BudgetTokens, bool Notify,
                                      bool SnapToLines, string? Instructions);
public sealed record LiveConnectorInfo(ConnectorId Id, string Group, string Privacy, string Model, int? ContextTokens,
                                       int? MaxOutputTokensCap, bool LiveConsent);
public sealed record LiveRenderJob(string ClipId, IReadOnlyList<EditSegment> Segments, IReadOnlyList<TimedWord> CaptionWords,
                                   double Duration, double SampleRate, string StyleId, ExportAspect Aspect, string Output,
                                   bool FromFinishedFile);

/// Sans-I/O live clip engine. Not thread-safe: owned by the coordinator. Its only clock is take time from the feed.
public sealed class LiveClipEngine(string takeId, LiveClipSettings settings, LiveConnectorInfo? connector, ClipFinderPrompt prompt,
                                   IReadOnlyList<TriggerPhrase> phrases, LiveClipLimits limits)
{
    public IReadOnlyList<LiveClipAction> Handle(LiveClipInput input);   // inputs and actions mirror the Swift enums
    public IReadOnlyList<LiveClip> Clips { get; }
    public WatchState Watch { get; }
}
public sealed class LiveTakeIndex
{
    public void AddVideo(long offset, int length, long dts90, long pts90, bool keyframe);
    public void AddAudio(long offset, int length, AudioSampleClock.Placement placement);
    public double Horizon(long flushedBytes, int sampleRate);
}

// VoxClip.Media/Ingest — additions to LiveTakeRecorder (section 16.2), owned by "vc-ingest-mux":
//     public LiveTakeIndex Index { get; }                     immutable snapshots for readers
//     public ChannelReader<LiveHorizon> Horizon { get; }      (FlushedBytes, Seconds) after each journal flush
// VoxClip.Media/Ingest/LiveClips — I/O
public interface ILiveTakeSource
{
    ChannelReader<double> Horizon { get; }
    IPacketSource OpenPackets();                                         // JournalPacketSource while live, the file demuxer afterwards
}
public sealed class LiveClipRenderer : IAsyncDisposable                   // thread "vc-live-render", BelowNormal, the export compose function
{
    public IAsyncEnumerable<LiveRenderEvent> RenderAsync(LiveRenderJob job, ILiveTakeSource source, CancellationToken ct);
}
public interface IClipTranscriber { Task<IReadOnlyList<LiveWord>> TranscribeAsync(string excerptWav, double offsetSeconds, CancellationToken ct); }
public sealed class LiveClipCoordinator : IAsyncDisposable
{
    public LiveClipCoordinator(LiveClipEngine engine, LlmRunner runner, ILlmConnector? connector, ILiveTakeSource source,
                               LiveClipRenderer renderer, IClipTranscriber? transcriber, LiveClipStore store);
    public ChannelReader<LiveClipsSnapshot> Updates { get; }
    public ValueTask SendAsync(LiveClipInput input, CancellationToken ct);
}

// VoxClip.App — view model; the app also owns GlobalClipShortcut (RegisterHotKey) and LiveClipNotifier (AppNotificationManager)
public sealed partial class LiveClipsViewModel : ObservableObject
{
    public ObservableCollection<LiveClipRow> Clips { get; } = [];
    [ObservableProperty] public partial WatchState Watch { get; private set; }
    [ObservableProperty] public partial ExportAspect Aspect { get; set; }
    [ObservableProperty] public partial string StyleId { get; set; }
    [RelayCommand] private Task ClipThatAsync(CancellationToken ct);
    [RelayCommand] private Task ToggleWatchingAsync(CancellationToken ct);   // live consent dialog first for cloud connectors
    [RelayCommand] private Task FindNowAsync(CancellationToken ct);
    [RelayCommand] private Task KeepAsync(string id);
    [RelayCommand] private Task ShareAsync(string id);
    [RelayCommand] private void Discard(string id);
    [RelayCommand] private void UndoDiscard();
    [RelayCommand] private Task AdjustStartAsync(LiveClipAdjust adjust);
    [RelayCommand] private void OpenInEditor(string id);
}
```

### 9.12 Errors

| Code | Raised by | Copy |
|---|---|---|
| `liveClipRenderFailed` | live renderer | "Couldn't render this clip: {reason}. The stream is still being recorded." |

LLM errors keep their ai.md §5 codes and messages, followed by the AI watching reassurance of 9.9.3 instead of "Your edits are saved." `diskFull` and `cancelled` are reused. There is no new CLI exit code.

### 9.13 Automated test plan

Everything here runs without a camera and without a network: a fake LLM connector, a fake transcriber and recorded transcript streams.

**Fixtures** in `shared/fixtures/ingest/live/`, generated by `tools/fixtures/ingest/` with a JavaScript reference of this section, as for sections 6 and 7. Swift, C# and the reference must agree.

```text
live/
  triggers.json    tokenisation, every sequence of 9.4.2, the standalone rule (positives and negatives)
  silence.json     feed levels → silence runs and silenceSince
  snap.json        clip-that ranges (words and time ranges), boundaries, clamps, ±15 s adjustments
  admission.json   overlapRatio, containment, sameTopic, supersede, discard memory, hourly cap
  windows.json     anchor, overlap need, context trimming, and the rendered cachedBlock and instruction
  budget.json      token accounting for each usage shape; the stop before sending
  cases/<id>/      events.jsonl, settings.json, llm.json, [batch.json], expected.json
```

**Replay cases.** `events.jsonl` is a transcript stream with take timestamps: `final` word batches, `processed`, silence runs, `horizon` updates, triggers, user actions, `takeEnded` and `batchTranscript`. Recorded cases come from real live-engine output captured with `voxclip-cli ingest rtmp --live-words-out` (section 17.2) from the maintainers' own test recordings, words only. `llm.json` scripts the fake connector: one entry per request, in order, holding either a reply (`clips`, `usage`, latency) or an error (`rateLimited` with `retryAfter`, `planLimit`, `unauthorized`, …). Renders and clip transcription are faked with scripted durations. `expected.json` holds the ordered actions (`evaluate` with the full `cachedBlock` and `instruction`, `render` with the kept interval and word ids, `notify`, `withdrawNotice`, `cancelEvaluation`, `applyToProject`), the watch-state transitions and the final clips. `voxclip-cli ingest live-replay --case … --check` runs a case.

| Case | Checks |
|---|---|
| `recorded-en-12min`, `recorded-et-12min` | real English and Estonian live output: evaluation times, windows, admitted clips |
| `clip-that-en`, `clip-that-et` | every sequence triggers; the trigger words and trailing fillers are outside the range; the tail padding stops before the trigger |
| `clip-that-negatives` | "I'll clip that later", "you can clip it", "clip that one" and mid-sentence matches do not trigger |
| `clip-that-snap` | boundary at or before the target, forward fallback, forced 40-word breaks ignored, take start, minimum length |
| `clip-that-button-wait` | a press with a live engine waits for final words; a phrase within 3 s moves `T` |
| `clip-that-coalesce` | voice and phone within 3 s make one clip |
| `clip-that-no-words` | a time range snapped to silence runs; clip-transcription words become captions and re-snap the start |
| `adjust` | +15 s and −15 s snap in their direction; limits disable the button |
| `rolling-basic` | eligibility, pause and max-interval firing, preset rotation, byte-exact request text |
| `rolling-window-anchor` | consecutive `cachedBlock`s share their prefix while the anchor holds |
| `rolling-context-trim` | a small context drops leading lines, never past `need`; `contextTooLong` pause |
| `rolling-settle-hold` | an unsettled clip is held once, then emitted when settled, or dropped |
| `rolling-supersede-unseen` | a higher score replaces an unseen clip in place; its notification is withdrawn |
| `rolling-no-supersede-seen` | a played or kept clip is never replaced |
| `rolling-same-topic` | a word-overlap topic match drops a near repeat |
| `rolling-discard-memory` | a discarded moment does not come back |
| `rolling-hourly-cap` | the cap and its expiry |
| `budget-calls`, `budget-tokens` | the request that would exceed the budget is not sent; pause; Keep watching |
| `backoff-rate-limited` | `retryAfter` 120 s honoured, doubling back-off, pause after 3 failures, Try again |
| `pause-unauthorized` | immediate pause with the ai.md message |
| `cli-connector` | AI watching refused; Find clips now sends exactly one request per press |
| `consent-gate` | no request before live consent for a cloud connector; none needed for a local one |
| `take-end` | final evaluation with the settled rule waived; renders restart from the finished file; touched-last-fragment re-render |
| `map-to-batch` | midpoint placement, snapping, one `aiResult` per preset, manual origin for "clip that", checkboxes |

**Tier B** (both platforms, in-process receiver as in section 18.1):

- **L-B1, sealed equals final.** Replay `sync_h264`, `sync_hevc` and `reconnect-same-config` through the real receiver paced at 1×, and trigger a time-range clip at 9.5 s with a 5 s lookback and captions off. The draft must render from the sealed take before the take ends. Then render the same plan from the finished file. Decoded output frames (after compose) and audio samples must be identical, and section 18.4 rule 3 (flash and beep within 1 ms) must hold in the draft. macOS exercises `AVFragmentedAsset` with `liveFragmentInterval`; Windows exercises `JournalPacketSource` and `LiveTakeIndex`.
- **L-B2, the receiver comes first.** A 60 s paced push with renders back to back: no `writerFailed`, recorder pressure never above 250 ms (macOS), the mux channel never full (Windows), section 18.4 rules 1 to 3 still pass on the take, and preview frames keep arriving.
- **L-B3, take end during a render.** End the take mid-render: finalizing takes no more than 1 s longer than without a render, the render restarts from the finished file, and its output equals L-B1's.
- **L-B4, recovery.** Kill the app mid-take with one ready and one waiting clip; recovery adopts the live store and renders the waiting clip.
- **HTTP** (`http.json` additions): `POST /s/{t}/clip` gives `202`, `409` (not live, turned off), `429` (the eleventh request within 60 s), `400` (non-empty body), `411`, `403` (wrong `Origin`), `404` and `410`; the new `info` fields.

**Tier C.** `voxclip-cli ingest rtmp --bind 127.0.0.1 --allow-loopback … --clip-at 9.5 --clip-lookback 5 --clip-out <tmp> --json` during the `sync_h264` FFmpeg push. With no live engine the range snaps to the fixture's silences, so the clip spans the beeps at 2, 5 and 9 s. Assert the JSON (`renderedBeforeTakeEnd: true`, the range), the clip's duration within one frame of the range, and flash and beep sync within 1 ms.

**Tier D.** The helper page's **Clip that** button through browser automation: enabled only while live, `202` → "Clipped. Review it in VoxClip.", and no request outside the origin.

**Guarantees.** A capturing log sink shows no transcript text, titles, reasons, trigger phrases or instructions in any line during the replay cases. No replay produces an action outside the listed kinds (there is no post or upload action). The live clip modules have no reference to the publishing client.

### 9.14 Milestones

| Part | Milestone | Why |
|---|---|---|
| "Clip that" from the button, {⌘K/Ctrl+K}, the global shortcut and the phone page; silence snapping; clip transcription for captions; drafts while live; the tray; Keep, Share…, Discard, ±15 s; clips into the project at take end | **M2, with the receiver** (section 3.1 item 9) | No LLM, no cost and no new privacy surface. It reuses the export path, the helper server and the batch engines, and it is useful with any RTMP app the day the receiver ships |
| Voice "clip that" | M2, with the live transcript (item 5) | Needs final live words and nothing else |
| AI watching and Find clips now | **M2.x** | Needs a live engine, which M2 may not have; needs threshold and timing tuning on real streams (H14); carries cost, consent and rate-limit risk that must not hold up the receiver |
| Clips onto the camera's own recording (9.8.2) | M2.x, after H7 | Depends on whether the camera records internally while it streams |

Inside M2 the order is: sealed reading and test L-B1, then the renderer and the tray with button triggers, then the phone button, then clip transcription.

---

## 10. LAN helper server and the phone upload page

One `LanHttpServer` per app instance serves both the stream helper page (for Receive) and phone uploads (for Send from your phone). It runs only while at least one of those windows is open.

### 10.1 HTTP subset (Core parser, both platforms)

- HTTP/1.1 only. Other versions get `505` and close.
- The request head (request line + headers) must fit `httpHeadMax` and arrive within `httpHeadTimeout`; otherwise `431` or close. Header names are case-insensitive; duplicate `Content-Length` or `Host` → `400`.
- **Body framing:** `Content-Length` only. Any `Transfer-Encoding` → `501`. A `POST` or `PATCH` without `Content-Length` → `411`. Safari and Chrome send `Content-Length` for Blob bodies (measured).
- `Expect: 100-continue`: validate the head first, then send either `HTTP/1.1 100 Continue` or the final error status. curl sends this header for large bodies.
- `Host` must equal `<bound IPv4>:<port>` exactly; otherwise `421`. This blocks DNS-rebinding pages.
- For `POST`, `PATCH` and `DELETE`, an `Origin` header, if present, must equal `http://<bound IPv4>:<port>`; otherwise `403`. curl sends no `Origin` and is allowed.
- Keep-alive is supported; `Connection: close` is honoured; at most `httpMaxRequestsPerConnection` requests per connection; idle keep-alive connections close after `httpKeepAliveIdle`.
- Bodies stream straight to disk. If no body byte arrives for `httpBodyIdle`, the connection closes; bytes already written stay written (tus semantics).
- At most `httpMaxConnections` connections, `8` per peer.
- Every response carries `Cache-Control: no-store`, `Referrer-Policy: no-referrer`, `X-Content-Type-Options: nosniff`, `Cross-Origin-Resource-Policy: same-origin` and `Content-Security-Policy: default-src 'none'; script-src 'self'; style-src 'self'; connect-src 'self'; img-src 'self' data:; base-uri 'none'; form-action 'none'; frame-ancestors 'none'`. Error bodies are short `text/plain; charset=utf-8`. No CORS headers are ever sent.

### 10.2 Routes

| Method and path | Response |
|---|---|
| `GET /s/{helperToken}/` | `stream.html` |
| `GET /s/{helperToken}/stream.js`, `GET /s/{helperToken}/page.css` | the static asset |
| `GET /s/{helperToken}/info` | `application/json`: `{"rtmpUrl":"rtmp://…","live":false,"clipThat":true,"lookbackSeconds":45}` (the last three fields: section 9.4.1) |
| `POST /s/{helperToken}/clip` | "clip that" from the phone, empty body: `202`, `409` or `429` with a short JSON body (section 9.4.1) |
| `GET /u/{uploadToken}/` | `upload.html` |
| `GET /u/{uploadToken}/upload.js`, `GET /u/{uploadToken}/page.css` | the static asset |
| `OPTIONS /files/{uploadToken}` | `204`, `Tus-Version: 1.0.0`, `Tus-Extension: creation,termination`, `Tus-Max-Size: <maxUploadBytes>` |
| `POST`, `HEAD`, `PATCH`, `DELETE` on `/files/{uploadToken}[/{id}]` | section 10.3 |
| `GET /u/{t}` or `/s/{t}` without the trailing slash | `301` to the path with the slash |
| anything else (including `/`, `/favicon.ico`) | `404` |

An unknown token gets `404`. A token that was valid and is now closed gets `410` (closed tokens are remembered until the app quits). Assets live in `shared/ingest/web/` (`upload.html`, `upload.js`, `stream.html`, `stream.js`, `page.css`) and are served byte-for-byte. They contain no tokens: the scripts read the token from `location.pathname`. Pages include `<link rel="icon" href="data:,">` so browsers do not request a favicon.

### 10.3 Upload protocol (tus 1.0 subset)

From [tus 1.0.x](https://tus.io/protocols/resumable-upload). Every tus response carries `Tus-Resumable: 1.0.0`.

| Request | Checks, in order | Success |
|---|---|---|
| `POST /files/{t}` with `Upload-Length` and `Upload-Metadata: filename <b64>,filetype <b64>` | `410` session closed; `400` missing or invalid `Upload-Length` (deferred length is not supported); `413` length > `maxUploadBytes`; `415` file type not accepted (10.5); `429` `maxActiveUploads` incomplete uploads already exist; `507` `freeBytes − length − remainingBytesOfOtherIncompleteUploads < uploadDiskReserve` | `201`, `Location: /files/{t}/{id}`, `Upload-Offset: 0` |
| `HEAD /files/{t}/{id}` | `404` unknown id | `200`, `Upload-Offset`, `Upload-Length` |
| `PATCH /files/{t}/{id}` with `Content-Type: application/offset+octet-stream`, `Upload-Offset` | `404` unknown id; `415` wrong content type; `409` `Upload-Offset` ≠ current offset; `413` body > `maxPatchBody` or `offset + body > Upload-Length`; `507` free space below `uploadDiskReserve` | `204`, `Upload-Offset: <new offset>` |
| `DELETE /files/{t}/{id}` | `404` unknown id | `204`; the `.part` file is deleted |

- `id` is 16 lowercase hex characters from the CSPRNG.
- **Partial bodies advance the offset.** Bytes are written with seek + write and synchronized to disk (`FileHandle.synchronize()` / `FileStream.Flush(true)`) before the response, and also when a body breaks off; the next `HEAD` reports exactly what is on disk.
- **Measured** (prototype): curl uploading 300 MB, killed mid-chunk, `HEAD` reported 141,943,040 bytes and the resumed upload was SHA-256-identical. Desktop Chrome 155 switched offline mid-upload resumed from 8,388,608 and finished byte-identical. A wrong token gave 404.

### 10.4 Sessions and tokens

- Opening **Send from your phone** creates one upload session with a fresh 128-bit token. Opening **Receive from camera** creates one helper session with a fresh 128-bit token. Tokens are in memory only.
- An upload session accepts any number of files until it closes. It closes when the user presses **Done** or closes the window; after `uploadSessionIdle` with no requests and no incomplete upload; or after `uploadSessionIdleWithPartial` with no requests at all. **New link** closes the current session and opens a new one.
- On close, incomplete `.part` files are deleted (the originals are still on the phone) and the token returns `410` from then on. When no session is left, the server stops listening.

### 10.5 Storage, names and completion

- Accepted file types: by the `filename` extension (case-insensitive) `mp4`, `mov`, `m4v`, plus `mkv` and `webm` on Windows (architecture.md §5 rejects them on macOS); or, without a filename, a `filetype` of `video/mp4` (`.mp4`) or `video/quicktime` (`.mov`).
- `UploadFileName.sanitize`: decode the base64 metadata as UTF-8 (invalid → `Video`), take the last path component, NFC-normalize, replace every character outside `[A-Za-z0-9 ._-]` with `_`, collapse repeats of `_` and spaces, strip leading dots and spaces, cut the stem to 120 characters, keep the extension in lowercase. An empty stem becomes `Video`. Collisions use the rule in 4.3. Client paths are never used.
- Bytes go to `<Received>/.voxclip-upload-<id>.part`. At `offset == length`: synchronize, rename to the final name, then the app probes the file (`MediaProbe`). If it has neither a video nor an audio track, the file is kept and the row shows `uploadNotVideo`. Otherwise the row shows **Open**, which runs the normal import.
- Uploaded files are never deleted by VoxClip after completion.

### 10.6 The upload page (`upload.html`, `upload.js`)

- One file input (`accept="video/*"`, `multiple`); files upload one after another.
- XHR, not `fetch`, because `fetch` has no upload progress in Safari. Chunks are `File.slice` of `uploadChunk`. Before each chunk the page sends `HEAD` for the offset. On any network error or 5xx it retries with exponential backoff from 1 s to 15 s, and retries at once on `visibilitychange` to visible.
- `localStorage` maps `name:size:lastModified` to the upload URL, so reloading the page resumes. A `404` or `410` on `HEAD` clears the entry and shows the matching message.
- A plain-HTTP LAN page is not a secure context (**measured**: `isSecureContext = false` in Chrome 155), so the page uses no `crypto.subtle`, no [Screen Wake Lock](https://developer.mozilla.org/en-US/docs/Web/API/Screen_Wake_Lock_API) and no async Clipboard. Integrity rests on TCP, the length check and the container probe.
- Status texts are fixed (section 15.3). No external resources, fonts or analytics.

### 10.7 The stream helper page (`stream.html`, `stream.js`)

- Fetches `/s/{t}/info` and shows the RTMP address in a read-only, auto-selected `<input>` with a **Copy** button.
- Copy uses `document.execCommand('copy')` on the selected input, because `navigator.clipboard` needs a secure context. If it returns false, the page shows "Press and hold the address, then tap Copy." Whether iOS Safari's `execCommand` copy works on this page is **[HW H11]**; whether Mimo's address field accepts a paste is **[HW H3]**.
- **Clip that** (section 9.4.1). Below the address, a large button (at least 64 px high) sends `POST /s/{t}/clip` with `fetch` (empty body, `credentials: "omit"`) and shows the result (copy in section 15.3). The page re-reads `/s/{t}/info` every 5 s while it is visible, and never in a background tab, to enable the button only while a take is live and the phone button is on. The button is disabled for 3 s after a tap. A failed request is not retried; the user taps again.

### 10.8 iPhone and Android caveats

- Picking from Photos through `<input type=file>` may hand the page a re-encoded file ("Compressing Video…"). Since iOS 17 the picker has **Options → Format: Automatic / Current / Most Compatible**; "Current" keeps the original, and a web page cannot set it ([Apple forums 743037](https://developer.apple.com/forums/thread/743037), [731042](https://developer.apple.com/forums/thread/731042)). The page and VoxClip tell users to choose **Current** or pick from **Files**.
- Safari pauses uploads in background tabs and when the screen locks; the resume logic continues when the page is visible again.
- Android Chrome hands over the original file.
- Always put the IPv4 address in the QR code; never rely on `.local` names (resolving them needs the Local Network permission on Apple devices, TN3179).

### 10.9 QR codes

- Content: `http://{ipv4}:{httpPort}/u/{uploadToken}/` (upload) or `http://{ipv4}:{httpPort}/s/{helperToken}/` (stream helper). Never an `rtmp://` URL: phone cameras do not open those usefully.
- Error correction M, quiet zone 4 modules, at least 4 px per module, black on white in both appearances. The URL is shown as selectable text under the code.
- macOS: `CIFilter.qrCodeGenerator()` with `correctionLevel = "M"`, scaled with nearest-neighbour. Windows: QRCoder `QRCodeGenerator.ECCLevel.M`.

---

## 11. Camera inbox (watched folder)

### 11.1 Behaviour

- Off by default. When on, VoxClip watches one folder recursively while it runs (FSEvents on macOS; `FileSystemWatcher` plus a full rescan every `inboxRescan` on Windows, because watchers can miss events) and rescans at launch.
- Candidates: `.mp4` and `.mov` (case-insensitive). Ignored: `.LRF`, `.WAV`, `.DNG`, names starting with `.` or `._` or `~$`, and `*.partial*`.
- A candidate is **ready** when its size and modification time have not changed for `inboxStable`, it can be opened for reading (Windows: no sharing violation), and `MediaProbe` succeeds. Pending candidates are re-checked every `inboxRecheck`. A candidate that is stable but fails to probe stays pending and is re-checked when it changes.
- `InboxIndex` (`<data>/Ingest/inbox.json`) keys entries by path relative to the inbox, size and modification time, with state `new`, `opened` or `dismissed`, so nothing is offered twice.
- VoxClip never moves, renames or deletes inbox files. Opening one runs the normal import in place.

### 11.2 SMB setup guide (DJI Camera Cloud Service)

Shown from Settings → Receive → **Setup guide** only after H8 passes. Until then the row reads "Use this for AirDrop, iCloud Drive, OneDrive or any synced folder." VoxClip creates the folder and shows this computer's IPv4 address and the share name. It never asks for, stores or tests the SMB password, and it cannot create the share itself (that needs administrator rights).

**macOS** ([Set up SMB file sharing on Mac](https://support.apple.com/guide/mac-help/set-up-smb-file-sharing-on-mac-mchlp1657/mac), macOS 27 edition; [Set up file sharing](https://support.apple.com/guide/mac-help/set-up-file-sharing-on-mac-mh17131/mac)):

1. System Settings → General → Sharing → ⓘ next to File Sharing → turn on File Sharing.
2. Under Shared Folders, click + and choose `VoxClipInbox`.
3. Click Options, turn on "Share files and folders using SMB", tick the account the camera will use under Windows File Sharing and enter its password. Apple warns these passwords "may be stored in a less secure manner", so the guide suggests a separate sharing-only account.
4. Leave "Only allow SMB encrypted connections" off unless uploads work with it **[HW H8]**.
5. In DJI Mimo: Me → Camera Cloud Service → NAS. Enter the IP, the share name `VoxClipInbox`, the user name and the password (path as reported by [DroneXL](https://dronexl.co/2026/01/12/dji-osmo-action-6-cloud-backup/) and [Basic Tutorials](https://basic-tutorials.com/news/dji-osmo-pocket-4-and-4p-automatic-upload-to-the-cloud-and-nas-is-here/); Mimo's labels may differ).

**Windows** ([File sharing over a network in Windows](https://support.microsoft.com/en-us/windows/experience/connectivity-networking/file-sharing-over-a-network-in-windows)):

1. Make sure the network is Private, and turn on File and printer sharing for Private networks (Settings → Network & internet → Advanced network settings → Advanced sharing settings).
2. Share the `VoxClipInbox` folder (Properties → Sharing → Advanced Sharing → Share this folder, share name `VoxClipInbox`, Change and Read for the camera's account).
3. Keep password-protected sharing on. Use a local account for the camera. (Microsoft's page suggests turning password protection off; VoxClip does not.)
4. Mimo as in macOS step 5.

---

## 12. Wired fallbacks

### 12.1 Import from a connected camera (M2)

- **Detection.** macOS: `NSWorkspace.didMountNotification` plus a scan of `/Volumes` at launch. Windows: poll `DriveInfo.GetDrives()` every `volumePoll` while Home is visible. A volume qualifies when `DCIM/` contains a folder matching `DJI_[0-9]{3}` (the Pocket 4 uses `DCIM/DJI_001`; [DJI export guide](https://support.dji.com/help/content?customId=en-us03400006849&spaceId=34&re=US&lang=en)). On macOS 26 the user may first have to allow the accessory to connect.
- **Import sheet.** Lists `.MP4` / `.MOV` files (thumbnail, name, duration, size, date), newest first, multi-select. The primary action **Copy and open** copies to the Received folder (`.partial` then rename, size verified, progress, Cancel deletes the partial file) and opens one project per file. **Open in place** is secondary; such projects show "Can't find {file}" once the card is removed (editing.md §10.3).
- **Pocket 4 files** are HEVC (often 10-bit D-Log). With a DJI Mic linked they have two audio tracks; VoxClip uses the first, which is the microphone. D-Log footage looks flat; VoxClip applies no LUT in v1.

### 12.2 Webcam (UVC)

Part of M2 Recording (design.md §12, architecture.md §5.7 and §6.7). The Pocket 4 appears as a camera (macOS shows "Osmo Pocket 4"; Windows may show "UVC Camera"; [DJI webcam guide](https://support.dji.com/help/content?customId=en-us03400006962&spaceId=34&re=US&lang=en)) at up to 4K30. Whether it also appears as a microphone is unknown **[HW H9]**; until then the Record view's Microphone menu is the answer (the DJI Mic receiver plugged into the computer, or the computer's microphone). The camera can record internally at the same time, so the user keeps a sharper original.

### 12.3 DisplayPort

Not supported directly: it needs a capture card, and a capture card is just another camera device in Recording.

---

## 13. Networks, interfaces and permissions

### 13.1 Choosing the interface (`LANInterfaceSelector`, Core, pure)

Input: every interface with `{id, displayName, kind (wifi | ethernet | other), ipv4, prefixLength, isUp, carriesDefaultRoute, isVirtual}`.

1. Keep interfaces that are up, have an IPv4 address in 10.0.0.0/8, 172.16.0.0/12 or 192.168.0.0/16, have a prefix length of 8–30, are of kind `wifi` or `ethernet`, and are not virtual.
   - macOS virtual: names starting with `bridge`, `utun`, `awdl`, `llw`, `anpi`, `vmenet`, `gif`, `stf`, `ipsec`, `ppp`.
   - Windows virtual: description or name containing `vEthernet`, `Hyper-V`, `VMware`, `VirtualBox`, `WSL`, `Default Switch`, `TAP-`, `WireGuard`, `Tailscale`, `ZeroTier`, or `NetworkInterfaceType` `Tunnel`/`Ppp`/`Loopback`.
2. Sort: carries the default route first, then `wifi` before `ethernet`, then `id` ascending.
3. If `ingest.interface` names a remaining candidate, use it; otherwise use the first. No candidate → `ingestNoNetwork`.
4. **Measured** on the planning Mac: `en0 192.168.1.15` and `bridge100 192.168.64.1` (a VM bridge); the rule picks `en0`.
5. macOS sources: `NWPathMonitor` (interface types and the default route) plus `getifaddrs` (IPv4 and netmask). Windows: `NetworkInterface.GetAllNetworkInterfaces()` with `OperationalStatus.Up`, a non-empty `GatewayAddresses` meaning "default route", cross-checked by a UDP `Socket.Connect(8.8.8.8:53)` and its `LocalEndPoint` (sends no packet).
6. **Rebind on change.** When the chosen address disappears or changes (`NWPathMonitor` update, `NetworkChange.NetworkAddressChanged`), stop the listeners, pick again, rebind, and show the address-changed notice. A live connection is not closed by VoxClip; if it dies, the reconnect rules apply.
7. Do not show the Wi-Fi network name. Reading it can require Location permission, which VoxClip does not ask for, and the IP address is enough.

### 13.2 Ports

Bind the RTMP listener to the first free port of `rtmpPorts`, starting at `ingest.rtmpPort`, and the HTTP server to the first free port of `httpPorts`. If none is free: `ingestPortsBusy`. Mimo accepts a custom port (the captured URL used `:1946`). The RTMP address always includes the port.

### 13.3 macOS

- **Local Network privacy** ([TN3179](https://developer.apple.com/documentation/technotes/tn3179-understanding-local-network-privacy), updated 2026-10-06): listening for and accepting incoming TCP connections does not need the privilege; outgoing TCP to a LAN address, UDP to a LAN address, Bonjour and `.local` resolution do. VoxClip's v1 ingest only accepts connections, so no Local Network alert should appear. Two rules keep it that way:
  - no Bonjour advertising or browsing, and no `NSBonjourServices`;
  - no self-test that connects to the Mac's own LAN address.
- **Info.plist** (`apps/macos/Sources/VoxClip/Info.plist`, embedded in both executables) gains one key. It is not needed by v1 operations; it is added so that any future or system-triggered check shows VoxClip's reason instead of a bare prompt:

  ```xml
  <key>NSLocalNetworkUsageDescription</key><string>VoxClip receives video from your camera or phone on this network while Receive from camera or Send from phone is open.</string>
  ```

- **Entitlements: unchanged** (exactly camera + audio-input, ADR-007; release.md checks this). A non-sandboxed app needs no `com.apple.security.network.server`; if VoxClip is ever sandboxed, that entitlement is required.
- **Code signing** matters: Local Network privacy and the Application Firewall track the app by its signature (TN3179). Developer-ID builds (`bundle.sh --sign-only`) keep their grants across rebuilds; ad-hoc builds may be asked again after each rebuild.
- **Application Firewall** ([macOS guide](https://support.apple.com/guide/mac-help/block-connections-to-your-mac-with-a-firewall-mh34041/mac)): when the firewall is on and VoxClip is not on its list, macOS asks whether to allow incoming connections, and denies them until the user answers. "Automatically allow downloaded signed software to receive incoming connections" admits validly signed apps without asking ([firewall settings](https://support.apple.com/guide/mac-help/change-firewall-settings-on-mac-mh11783/mac)). VoxClip does not query or change the Application Firewall; it shows the hint in section 15.2 after `noClientHint`.
- Resetting the Local Network privilege for testing is possible in System Settings → Privacy & Security → Local Network from macOS 27.2; on older versions use a fresh user account or a VM (TN3179).

### 13.4 Windows

**Installer facts.** Velopack's `Setup.exe` installs per user into `%LocalAppData%\VoxClip\` with the app in `current\`, which is replaced on every update, and it runs without elevation ([Velopack installers](https://docs.velopack.io/packaging/installer), [Windows overview](https://docs.velopack.io/packaging/operating-systems/windows)). Hooks run inside the install, update and uninstall steps with 15–30 s limits and "you may not show any UI to the user" ([Velopack hooks](https://docs.velopack.io/integrating/hooks)). The installer therefore cannot add a firewall rule. The rule's program path, `%LocalAppData%\VoxClip\current\VoxClip.exe`, stays the same across updates.

**Windows Firewall behaviour** ([Microsoft Learn, updated 2026-10-08](https://learn.microsoft.com/en-us/windows/security/operating-system-security/network-security/windows-firewall/rules)): when an app first listens and no allow rule exists, an admin is prompted, and if they answer No or cancel, block rules are created. A standard user is prompted and block rules are created "no matter what option is selected". Explicit block rules beat allow rules, and the prompt does not return until the rules are deleted. Microsoft recommends adding the app's rules before first launch and restricting home-network apps to **Local Subnet**.

**Preflight** (`FirewallManager`, every time before a LAN listen):

1. Read `INetFwPolicy2` ([docs](https://learn.microsoft.com/en-us/windows/win32/api/netfw/nn-netfw-inetfwpolicy2)): `CurrentProfileTypes`, `FirewallEnabled` and `BlockAllInboundTraffic` for those profiles, `LocalPolicyModifyState`, and the rules whose `ApplicationName` equals VoxClip's executable path (case-insensitive). Reading is expected to work without elevation (verify in test W-6). Do not infer firewall state from the network category: Microsoft says the category "must never be used to assume which Windows Firewall ports are open" ([INetwork::GetCategory](https://learn.microsoft.com/en-us/windows/win32/api/netlistmgr/nf-netlistmgr-inetwork-getcategory)).
2. Firewall disabled on every current profile (for example a third-party firewall is in charge) → listen.
3. `LocalPolicyModifyState` says local rules have no effect (managed PC) → `ingestFirewallManaged`. Do not listen.
4. `BlockAllInboundTraffic` on the current profile → `ingestFirewallBlocked` with the "blocking all incoming connections" copy. Do not listen.
5. Current profile is Public only → `ingestNetworkPublic`. Do not listen. VoxClip never adds a Public rule.
6. A block rule for VoxClip exists, or no VoxClip allow rule covers the Private profile and both port ranges → `ingestFirewallBlocked` with **Allow on private networks**. Do not listen.
7. Otherwise → listen.

VoxClip never calls `listen` on a LAN address while preflight fails, because that could trigger Windows' own prompt and leave block rules behind. Loopback binds (tests, CLI with `--allow-loopback`) skip the preflight.

**Elevated helper.** **Allow on private networks** starts `VoxClip.exe --firewall-helper add` with `UseShellExecute = true, Verb = "runas"` (UAC). `Program.Main` handles `--firewall-helper` right after `VelopackApp.Build().Run()` and before WinUI starts; it shows no window and exits with 0 on success. It:

1. takes the program path from its own process (`Environment.ProcessPath`), never from an argument, so an elevated helper can only change rules for VoxClip itself (in an install this is `%LocalAppData%\VoxClip\current\VoxClip.exe`; in a development build, the build output path);
2. removes every rule whose `ApplicationName` equals that path and which is either a block rule or in the group `VoxClip`;
3. adds one rule: name `VoxClip - receive from camera and phone`, description `Added by VoxClip when you allowed receiving on private networks.`, `ApplicationName` = that path, protocol TCP, `LocalPorts = 1935-1945,8765-8775`, `RemoteAddresses = LocalSubnet`, direction in, action allow, profiles Private, grouping `VoxClip`, enabled.

`--firewall-helper remove` removes the VoxClip-group rules for that path. A cancelled UAC prompt (`Win32Exception` with `NativeErrorCode == 1223`) shows the cancelled copy. Without admin credentials the copy explains how an administrator can add the rule, with **Copy details** placing the equivalent command on the clipboard:

```text
netsh advfirewall firewall add rule name="VoxClip - receive from camera and phone" dir=in action=allow program="%LocalAppData%\VoxClip\current\VoxClip.exe" protocol=TCP localport=1935-1945,8765-8775 remoteip=localsubnet profile=private
```

**Network profile.** New networks are Public by default on Windows 11 ([Microsoft support](https://support.microsoft.com/en-us/windows/experience/connectivity-networking/essential-network-settings-and-tasks-in-windows)); a phone hotspot usually is too. The Public notice links to `ms-settings:network-wifi` or `ms-settings:network-ethernet` ([Launch Windows Settings](https://learn.microsoft.com/en-us/windows/apps/develop/launch/launch-settings-app)). VoxClip never changes the category itself.

**Uninstall.** The Velopack uninstall hook runs without elevation, so it cannot remove the rule. The rule then points at a deleted program and has no effect. Settings → Receive offers **Remove firewall rule** (UAC) for users who want to remove it before uninstalling; the release notes and About → "What leaves this device" mention it.

**No URL ACL** is needed: the HTTP server uses raw sockets, not `http.sys`.

---

## 14. Security rules

1. **Off by default.** Listeners run only while the Receive window or the Send from your phone window is open. The Receive listener also stops after `waitingAutoOff` without a publisher. The camera inbox opens no socket.
2. **Bind one private IPv4 address** (section 13.1). Never `0.0.0.0`, never IPv6, never loopback in the app. The CLI may bind `127.0.0.1` only with `--allow-loopback`, and then accepts loopback peers only.
3. **Peer policy.** Accept a peer only if its IPv4 address is inside the bound interface's subnet (`address & mask == interface & mask`), or is loopback in loopback mode. Refuse everything else at accept time.
4. **Secrets.** Stream keys and tokens come from the CSPRNG (section 5), are compared in constant time, are registered with the `Redactor`, and never appear in logs, project files, settings, sidecars, window titles or crash output. The stream key is stored only in the Keychain / DPAPI. **Reset address** replaces it at once.
5. **Throttling.** `failedPublishLimit` per peer for RTMP. For HTTP, 20 requests with an unknown token from one peer within 60 s also block that peer for 10 minutes.
6. **Resource limits** as in section 5: message sizes, AMF depth, command rates, connection counts, header sizes, timeouts, upload size and disk reserve.
7. **No playback, no file serving.** The RTMP server never plays streams out. The HTTP server serves only the five static assets, the `info` JSON and the bodyless "clip that" action (section 9.4.1); it never lists directories and never serves user files, drafts included.
8. **Uploads cannot escape the Received folder.** Names are sanitized (section 10.5), written via `.part` files in that folder, and never derived from client paths.
9. **Plain transport.** Neither RTMP from the camera nor the LAN page is encrypted (the camera offers no RTMPS). Both windows say so: "Stays on your local network. It is not encrypted, so use a network you trust."
10. **Nothing leaves the LAN.** Ingest makes no outgoing connections at all (also required by section 13.3). The one exception in this spec is AI watching (section 9.5): only after the user turns it on for a stream does the AI layer (ai.md), not ingest, send live transcript text to the connector the user chose. About → "What leaves this device" gains: "Receive from camera and Send from your phone listen on your local network only while their window is open. They send nothing to the internet." and "AI watching, if you turn it on for a stream, sends the live transcript (no audio or video) to the AI you chose in Settings → AI."
11. **Windows Firewall** rules are added only after the user's click, for the Private profile and the local subnet only (section 13.4).
12. **Validate before opening.** Every received file is probed before it becomes a project; the import pipeline's normal error handling applies.
13. **Nothing is posted automatically.** Live clips are drafts for the user to review. No live clipping path calls a publishing API or uploads a file (section 9.1, invariant 1).

---

## 15. UX: entry points, states and exact copy

Voice as in design.md §13: short, factual, calm, no exclamation marks, no emoji. `{Mac/PC}` is "Mac" on macOS and "PC" on Windows. macOS shows notices as inline callout rows; Windows uses `InfoBar` with the severity given.

### 15.1 Entry points (M2)

- **Welcome / Home:** next to **Choose file…** and **Record**, a **From camera or phone** menu button with: "Receive a live stream…", "Send from your phone…", "Import from a connected camera…" (enabled when a DJI volume is mounted), "Camera inbox…" (opens Settings → Receive).
- **macOS File menu:** "Receive Live Stream…", "Send from Phone…", "Import from Camera…", after New Recording. No new keyboard shortcuts.
- **Welcome / Home sections:** "From your camera" (camera-inbox items in state `new`, at most 5 rows with **Open** and **Dismiss**, then "Show all"), and a callout when a DJI volume is mounted: "DJI camera connected · {n} videos" [Import…].
- Only one Receive session can exist; choosing it again brings the window to the front. Drag-and-drop onto a Receive window that is live shows "Finish or end the take first".

### 15.2 Receive from camera

The window opens like the Record view (design.md §12): a new project window that becomes the editor when the take ends.

```text
┌ Receive from camera ───────────────────────────────────────────────────────────┐
│  ┌──────────────────────────── preview (stage black) ────────────────────────┐ │
│  │   REC ● 03:12                                                              │ │
│  │                         waiting: the steps below                           │ │
│  └────────────────────────────────────────────────────────────────────────────┘ │
│  1. On your phone, open DJI Mimo and connect to the camera.                     │
│  2. Tap Livestream, then RTMP, and choose the same Wi-Fi as this Mac.           │
│  3. Paste this address:                                                         │
│     rtmp://192.168.1.15:1935/live/vox-7k3m-q9tz-2hxp-8fwa      [Copy]  [▣ QR]  │
│  4. Choose 1080p and 6 Mbps, then tap Start.                                    │
│  Wi-Fi · 192.168.1.15 ▾                         Using another app? Stream to the same address. │
│  Stays on your local network. It is not encrypted, so use a network you trust. │
│                                                          [Stop receiving]       │
└────────────────────────────────────────────────────────────────────────────────┘
```

- The address uses Geist Mono 500 at the transcript text size, selectable. The QR button shows the helper-page QR code with "Scan with your phone to copy this address there and to clip from your phone."
- Toolbar while live: the REC pill (as in Recording), the stats line, an audio level meter, the **AI watching** pill and switch (section 9.6.2), **Clip that** (⌘K / Ctrl+K, tooltip "Save the last {n} seconds"), the tray button and **End take** (Space). Esc does nothing.
- Under the preview while live: "This is the live stream, up to 1080p at 30 fps. The camera's own recording is sharper."
- The "Clips from this stream" tray is a trailing column of this window; its layout, rows, AI watching states, consent sheet, notifications and copy are in section 9.9.

| Situation | Copy / UI |
|---|---|
| Preflight | "Getting ready to receive…" |
| No network (`ingestNoNetwork`) | "Connect this {Mac/PC} to Wi-Fi or Ethernet to receive from a camera." [Try again] (Warning) |
| Ports busy (`ingestPortsBusy`) | "Another app is using ports 1935 to 1945. Quit apps that receive streams, such as OBS, then try again." (Error) |
| Port fallback | "Port 1935 is in use, so the address uses port {port}. Paste the new address in DJI Mimo." (Informational) |
| Windows: rule needed (`ingestFirewallBlocked`) | "Windows Firewall needs your permission before cameras and phones can connect. VoxClip allows connections from your local network on private networks only." [Allow on private networks] (Informational) |
| Windows: UAC cancelled | "VoxClip can't receive until Windows Firewall allows it." [Allow on private networks] (Warning) |
| Windows: no admin rights | "Allowing VoxClip through Windows Firewall needs an administrator. Ask one to run the command from Copy details." [Copy details] (Warning) |
| Windows: block all incoming | "Windows Firewall is blocking all incoming connections on this network. Turn that off in Windows Security to receive from a camera." [Open Windows Security] (`ms-settings:windowsdefender`) (Warning) |
| Windows: managed (`ingestFirewallManaged`) | "Your organization manages Windows Firewall on this PC. Ask your administrator to allow VoxClip on TCP ports 1935 to 1945 and 8765 to 8775 for private networks." [Copy details] (Warning) |
| Windows: Public network (`ingestNetworkPublic`) | "This network is set to Public, so Windows blocks cameras and phones. If you trust this network, make it Private in Settings." [Open network settings] (Warning) |
| Waiting | the layout above |
| No connection after 30 s | macOS: "Nothing yet? The camera and this Mac must be on the same Wi-Fi. Guest networks often block devices from seeing each other. If macOS asked whether VoxClip may accept incoming connections, choose Allow." [Open Network Settings]. Windows: the same without the last sentence (Informational) |
| Wrong key | "A device at {ip} used an old address. Paste the address again in DJI Mimo." (Warning) |
| Peer throttled | "VoxClip stopped accepting connections from {ip} for 10 minutes after too many wrong addresses." (Warning) |
| Connected, waiting for video | "Camera connected. Waiting for video…" |
| No video after 15 s | "The camera connected but hasn't sent video. Stop and start the livestream in DJI Mimo." (Warning) |
| Live, stats line | "{height}p · {fps} fps · {HEVC/H.264} · {Mbps} Mbps · from {ip}" |
| Live, no live engine | "Words appear when the take ends." |
| Live, live engine running | hint under the live transcript: "Say “clip that” to save the last {n} seconds." (only with `ingest.liveClips.voiceTrigger` on) |
| Reconnecting | "The connection dropped. Waiting for the camera to reconnect · {m:ss}" and "Everything up to {elapsed} is saved." [End take] (Warning) |
| Taken over | "A new connection from {ip} took over the stream." (Informational) |
| New take after format change | "The camera changed its video format, so VoxClip started a new take. The first take is saved in {folder}." (Informational) |
| Unsupported video (`ingestUnsupportedCodec`) | "This camera sends {codec} video, which VoxClip can't record yet. Use H.264 or HEVC." (Error) |
| Unsupported audio | "VoxClip can't record this camera's {codec} audio. The video is being recorded without sound." (Warning) |
| Disk low | "There isn't enough free space on {volume}. The take is saved up to {elapsed}." (Error) |
| Writer failed (`ingestWriterFailed`) | "Recording stopped: {reason}. The take is saved up to {elapsed}." (Error) |
| Finalizing | "Finishing the take…" |
| Didn't reconnect (in the editor) | "The camera didn't reconnect within a minute, so VoxClip saved the take." (Informational) |
| Reconnect markers (in the editor) | "The connection dropped {n} time(s). VoxClip joined the parts at {times}." (Informational, once) |
| Auto off | "Receiving stopped after 15 minutes without a camera." [Start again] |
| Address changed | "This {Mac/PC}'s network address changed. Paste the new address in DJI Mimo." (Warning) |
| Window closed while live | No alert. The take is finalized, kept and added to Recent |
| Recovery (Welcome / Home) | "VoxClip found an unfinished take from {date} {time}. It's saved up to {duration}." [Recover] [Show in Finder / Show in Explorer] |
| Recovered | "Recovered {name}." (Success, auto-dismiss after 6 s) |
| Recovery failed | "VoxClip couldn't recover {name}. The file is still in {folder}." [Show in Finder / Show in Explorer] |

### 15.3 Send from your phone

```text
┌ Send from your phone ───────────────────────────────────────────┐
│   [ QR ]   Scan this code with your phone's camera.             │
│            Your phone must be on the same Wi-Fi as this Mac.    │
│            http://192.168.1.15:8765/u/k3m…/                     │
│   On iPhone, tap Options in the photo picker and choose Current │
│   to send the original, or choose the video from Files.         │
│   ───────────────────────────────────────────────────────────── │
│   DJI_20261025_140311_0001_D.MP4 · 1.2 GB of 4.0 GB · 38 MB/s   │
│   Interview take 2.mov · received                     [Open]    │
│   ───────────────────────────────────────────────────────────── │
│   Stays on your local network. It is not encrypted, so use a    │
│   network you trust. This link works until you close this window.│
│                                           [New link]  [Done]    │
└─────────────────────────────────────────────────────────────────┘
```

| Situation | In VoxClip | On the phone page |
|---|---|---|
| Ready | the layout above | Title "Send a video to VoxClip". "Keep this page open and the screen on until it says Done. If the upload pauses, come back to this tab and it continues where it stopped." "In the photo picker, tap Options and choose Current to send the original file, or tap Choose File to pick it from Files." Button "Choose video" |
| Receiving | "{name} · {done} of {total} · {rate}" | "Sending · {done} of {total} · {rate} · {eta} left" |
| No bytes for 15 s | "{name} · paused, waiting for the phone" | "Paused, retrying…" |
| Complete | "{name} · received" [Open] | "Done · sent to VoxClip" |
| Not a video (`uploadNotVideo`) | "{name} isn't a video VoxClip can open. It's saved in {folder}." [Show in Finder / Show in Explorer] | "Done · sent to VoxClip" |
| 507 | "Not enough free space on {volume} for {name} ({size})." | "The computer doesn't have enough free space for this video." |
| 413 | — | "This video is larger than VoxClip accepts (64 GB)." |
| 415 | — | "VoxClip can't receive this type of file." |
| 404 | — | "This link isn't valid. Scan the code in VoxClip again." |
| 410 / expired | "The link expired after 10 minutes without activity." [New link] | "This link has expired. Open a new one in VoxClip." |
| Windows preflight fails | the Receive copy for the same case | — |

Stream helper page (phone): title "Livestream to VoxClip"; "In DJI Mimo, tap Livestream, then RTMP, and paste this address:"; the address field; [Copy] → "Copied"; fallback "Press and hold the address, then tap Copy."; "Choose the same Wi-Fi as your computer. Choose 1080p and 6 Mbps, or 3 Mbps if the Wi-Fi is weak. Tap Start."; "The address stays the same until you reset it in VoxClip."

Stream helper page, **Clip that** (section 10.7): button "Clip that"; under it "Saves the last {n} seconds in VoxClip for you to review. Nothing is posted."; after `202` "Clipped. Review it in VoxClip." (3 s); not live (button disabled) "Clip that works while the camera is streaming to VoxClip."; turned off (`409 off`) "Clip that from the phone is turned off in VoxClip."; `429` "Too many clips in a minute. Wait a moment."; network error "VoxClip didn't answer. Check that this phone is on the same Wi-Fi."

### 15.4 Settings → Receive (new pane, M2)

| Row | Content |
|---|---|
| Save received videos to | folder picker, default per section 4.3, Reveal |
| Network | "Automatic" or "{Wi-Fi/Ethernet} · {ip}" for each candidate |
| Livestream address | `rtmp://{ip}:{port}/live/vox-••••-••••-••••-••••` with [Copy] [Reset address]. Footnote "Resetting makes the old address stop working. Paste the new one in DJI Mimo." |
| Camera inbox | toggle "Watch a folder for new videos", folder picker, footnote "Use this for AirDrop, iCloud Drive, OneDrive or any synced folder." After H8: [Setup guide] for DJI Camera Cloud Service |
| Windows Firewall (Windows) | "Allowed on private networks" or "Not allowed yet" with [Allow on private networks] / [Remove firewall rule] |
| Clip that (section 9.4) | toggle "Listen for “clip that” in the live transcript" (`ingest.liveClips.voiceTrigger`); toggle "Clip that button on the phone page" (`ingest.liveClips.phoneButton`); "Clip that from any app" with a shortcut recorder and Clear (`ingest.liveClips.globalShortcut`, off by default); "Look back" 30 s · 45 s · 60 s · 90 s (`ingest.liveClips.lookbackSeconds`) |
| AI watching (section 9.5) | Presets: Best moments · Hooks · Quotes, at least one (`ingest.liveClips.presets`); "Only clips scoring" 7 · 8 · 9 and up (`ingest.liveClips.minScore`); "At most" 3 · 6 · 12 "AI clips per hour" (`ingest.liveClips.maxPerHour`); "Budget per stream" Small (60 checks, 200,000 tokens) · Medium (120, 400,000) · Large (240, 800,000) (`ingest.liveClips.budgetCalls`, `ingest.liveClips.budgetTokens`); toggle "Notify me about strong clips" (`ingest.liveClips.notify`). Footnote "AI watching is off at the start of every stream. It sends the live transcript, never audio or video, to the AI you chose in Settings → AI. Installed CLIs run only when you press Find clips now." |
| Footnote | "VoxClip listens on your local network only while Receive from camera or Send from your phone is open. Nothing is sent to the internet unless you turn on AI watching for a stream." |

### 15.5 Accessibility

- The QR image has the accessibility label "QR code for {url}"; the URL is always available as text with Copy.
- State changes are announced: "Camera connected", "Recording", "Connection dropped", "Take saved", "{name} received". Live clipping adds its announcements in section 9.9.6.
- The REC dot does not blink under Reduce Motion. Space ends a take only when focus is not in a text field or the clips tray.

---

## 16. Type sketches

Shapes, not final code. Names match section 4.2. The live clipping types, including the Windows recorder's `Index` and `Horizon` additions, are in section 9.11.

### 16.1 Swift (Swift 6, strict concurrency)

```swift
// VoxClipCore/Domain/Ingest — pure, Sendable values
public struct IPv4: Hashable, Sendable { public let raw: UInt32; public init?(_ dotted: String); public var dotted: String { get } }

public struct LANInterface: Hashable, Sendable, Identifiable {
    public enum Kind: String, Sendable { case wifi, ethernet, other }
    public let id: String, displayName: String, kind: Kind
    public let address: IPv4, prefixLength: UInt8
    public let isUp: Bool, carriesDefaultRoute: Bool, isVirtual: Bool
}
public enum LANInterfaceSelector {
    public static func candidates(_ all: [LANInterface]) -> [LANInterface]
    public static func pick(_ all: [LANInterface], preferred: String?) -> LANInterface?
}
public enum PeerPolicy: Sendable, Equatable {
    case sameSubnet(LANInterface), loopbackOnly
    public func admits(_ peer: IPv4) -> Bool
}
public enum IngestSecretFormat {
    public static func streamKey(_ tenRandomBytes: [UInt8]) -> String          // "vox-xxxx-xxxx-xxxx-xxxx"
    public static func token(_ sixteenRandomBytes: [UInt8]) -> String          // 26 symbols
    public static func normalizedKeyCandidate(_ raw: String) -> String?         // §6.6 rules
    public static func constantTimeEquals(_ a: [UInt8], _ b: [UInt8]) -> Bool
}

public protocol HMACSHA256: Sendable { func mac(key: [UInt8], data: [UInt8]) -> [UInt8] }

public indirect enum AMF0Value: Sendable, Equatable {
    case number(Double), boolean(Bool), string(String), null, undefined, date(Double)
    case object([AMF0Property]), ecmaArray([AMF0Property]), strictArray([AMF0Value])
}
public struct AMF0Property: Sendable, Equatable { public let key: String; public let value: AMF0Value }
public enum AMF0 {
    public static func decodeAll(_ bytes: ArraySlice<UInt8>, limits: IngestLimits) throws(IngestProtocolError) -> [AMF0Value]
    public static func encode(_ values: [AMF0Value]) -> [UInt8]                // canonical: properties in given order
}

public struct RTMPMessage: Sendable, Equatable {
    public let csid: UInt32, typeId: UInt8, streamId: UInt32, timestamp: UInt32, payload: [UInt8]
}

public enum VideoCodec: String, Sendable { case avc = "avc1", hevc = "hvc1" }
public enum AudioCodec: String, Sendable { case aac = "mp4a" }

public enum FLVMedia: Sendable, Equatable {
    case videoConfig(VideoCodec, record: [UInt8])
    case videoFrame(VideoCodec, dtsMs: UInt32, ctsMs: Int32, keyframe: Bool, data: [UInt8])
    case videoEnd
    case audioConfig(AudioCodec, asc: [UInt8])
    case audioFrame(AudioCodec, dtsMs: UInt32, data: [UInt8])
    case audioSilence(dtsMs: UInt32)
    case unsupported(kind: UnsupportedKind, fourCC: String)
}

public enum RTMPEvent: Sendable, Equatable {
    case handshakeCompleted(digest: Bool)
    case connected(ConnectInfo)                       // app/tcUrl with the key segment removed, flashVer, fourCcList
    case publishAccepted, publishRejected
    case metadata(AMF0Value)
    case media(FLVMedia)
    case unpublished
}
public enum RTMPOutput: Sendable, Equatable { case send([UInt8]), event(RTMPEvent), close(RTMPCloseReason) }

/// Sans-I/O server side of one RTMP connection. Deterministic given its config.
public struct RTMPServerProtocol: Sendable {
    public struct Config: Sendable {
        public var expectedKey: String
        public var serverRandom: [UInt8]                 // 3032 bytes
        public var serverTime: UInt32
        public var limits: IngestLimits
    }
    public init(config: Config, hmac: any HMACSHA256)
    public mutating func receive(_ bytes: ArraySlice<UInt8>) -> [RTMPOutput]
    public mutating func timedOut(_ kind: RTMPTimeout) -> [RTMPOutput]
    public var totalBytesConsumed: UInt64 { get }
}

public struct TimelineMapper: Sendable {
    public enum Track: Sendable { case video, audio }
    public struct Marker: Sendable, Equatable { public enum Kind: Sendable, Equatable { case reconnect, timestampJump(deltaMs: Int64) }; public let atMs: Int64; public let kind: Kind }
    public init(limits: IngestLimits)
    public mutating func map(_ raw: UInt32, track: Track, nominalMs: Int64) -> Int64
    public mutating func beginNewConnection()
    public private(set) var markers: [Marker]
}

public struct AudioSampleClock: Sendable {
    public struct Placement: Sendable, Equatable { public let silenceFrames: Int64, dropFrames: Int, writeAtSample: Int64, writeFrames: Int }
    public init(sampleRate: Int, reanchorMs: Int)
    public mutating func place(takeMs: Int64, frames: Int, force: Bool) -> Placement
}

public struct IngestSessionReducer: Sendable {
    public enum Input: Sendable { case publishAccepted(ConnectionID, peer: IPv4), publishRejected(peer: IPv4), ready(ConnectionID, TakeConfigs),
                                  sequenceChanged(ConnectionID, TakeConfigs), unpublished(ConnectionID), connectionClosed(ConnectionID),
                                  idleTimeout(ConnectionID), unsupported(ConnectionID, String), userStop, diskLow, writerFailed(String), tick }
    public enum Action: Sendable, Equatable { case closeConnection(ConnectionID, RTMPCloseReason), attach(ConnectionID, newConnection: Bool),
                                  startTake(TakeConfigs), continueTake, finalizeTake(TakeEndReason), throttlePeer(IPv4, untilMs: Int64),
                                  stopListening(StopReason), notice(IngestNotice) }
    public init(limits: IngestLimits, nowMs: Int64, continueAfterTake: Bool)
    public private(set) var state: IngestSessionState
    public mutating func handle(_ input: Input, nowMs: Int64) -> [Action]
}

public struct HTTPRequestHead: Sendable, Equatable { public let method: String, target: String, headers: [(name: String, value: String)] }   // headers kept in order
public enum HTTPRequestParser { public static func parse(_ head: ArraySlice<UInt8>, limits: IngestLimits) -> Result<HTTPRequestHead, HTTPStatusError> }
public struct LanRouter: Sendable { public func route(_ head: HTTPRequestHead, boundHost: String) -> LanRoute }   // asset, info, tus op, or error status
public struct UploadSessionStore: Sendable {                                    // pure state; I/O done by the server
    public mutating func create(length: Int64, metadata: String?, freeBytes: Int64, nowMs: Int64) -> TusResult
    public mutating func patch(id: String, offset: Int64, contentType: String?, bodyLength: Int64, freeBytes: Int64, nowMs: Int64) -> TusResult
    public mutating func advance(id: String, by bytes: Int64, nowMs: Int64) -> UploadProgress   // after bytes hit the disk
    public mutating func tick(nowMs: Int64) -> [UploadSessionEvent]                          // expiry
}

// VoxClipMedia/Ingest — actors that own I/O and AVFoundation
public actor RTMPReceiver {
    public init(interface: LANInterface, policy: PeerPolicy, preferredPort: UInt16, key: String,
                limits: IngestLimits, receivedFolder: URL, devices: IngestDeviceCatalog)
    public func start() async throws(VoxClipError) -> UInt16                    // bound port
    public nonisolated var events: AsyncStream<ReceiverEvent> { get }           // state, stats, notices, finished takes
    public nonisolated var audioFeed: AsyncStream<AudioFeedChunk> { get }
    public func attachPreview(_ renderer: AVSampleBufferVideoRenderer)          // see §4.5
    public func endTake() async throws(VoxClipError) -> [TakeResult]
    public func stop() async
}
public actor LiveTakeRecorder {
    public init(url: URL, video: CMVideoFormatDescription?, aac: AudioSpecificConfig?, limits: IngestLimits) throws(VoxClipError)
    public func appendVideo(_ data: [UInt8], dts90: Int64, pts90: Int64, keyframe: Bool) throws(VoxClipError)
    public func appendAAC(_ data: [UInt8], takeMs: Int64, force: Bool) throws(VoxClipError) -> AudioSampleClock.Placement
    public func finish() async throws(VoxClipError) -> TakeResult
}
public actor LanHttpServer {
    public init(interface: LANInterface, policy: PeerPolicy, limits: IngestLimits, assets: URL /* shared/ingest/web */)
    public func start() async throws(VoxClipError) -> UInt16
    public func openUploadSession(folder: URL) -> UploadSessionHandle              // token, URL, AsyncStream<UploadEvent>
    public func openHelperSession(rtmpURL: String) -> HelperSessionHandle
    public func close(_ token: String)
}
public actor InboxWatcher { public init(folder: URL, index: InboxIndex); public nonisolated var items: AsyncStream<[InboxItem]> { get } }

// VoxClip (app)
@MainActor @Observable final class ReceiveModel {
    enum Phase: Equatable {
        case preflight, blocked(VoxClipError)
        case waiting(ReceiveAddress), connecting(peer: String)
        case live(LiveStats), reconnecting(since: Date, savedUpTo: Duration)
        case finalizing, finished(projectSource: URL), failed(VoxClipError)
    }
    private(set) var phase: Phase = .preflight
    private(set) var notices: [IngestNotice] = []
    func start() async
    func endTake() async
    func stop() async
    func resetAddress() async                      // Keychain write, rebinds with the new key
}
struct ReceiveAddress: Equatable { let rtmpURL: String; let helperURL: URL; let qr: CGImage; let interface: LANInterface; let port: UInt16 }
```

### 16.2 C# (.NET 10)

```csharp
// VoxClip.Core/Domain/Ingest — pure, immutable where possible
public readonly record struct IPv4(uint Raw) { public static bool TryParse(string s, out IPv4 a); public override string ToString(); }
public enum LanInterfaceKind { Wifi, Ethernet, Other }
public sealed record LanInterface(string Id, string DisplayName, LanInterfaceKind Kind, IPv4 Address, byte PrefixLength,
                                  bool IsUp, bool CarriesDefaultRoute, bool IsVirtual);
public static class LanInterfaceSelector
{
    public static IReadOnlyList<LanInterface> Candidates(IEnumerable<LanInterface> all);
    public static LanInterface? Pick(IEnumerable<LanInterface> all, string? preferredId);
}
public abstract record PeerPolicy { public sealed record SameSubnet(LanInterface Interface) : PeerPolicy; public sealed record LoopbackOnly : PeerPolicy; }
public static class IngestSecretFormat
{
    public static string StreamKey(ReadOnlySpan<byte> tenRandomBytes);
    public static string Token(ReadOnlySpan<byte> sixteenRandomBytes);
    public static string? NormalizedKeyCandidate(string raw);
    public static bool ConstantTimeEquals(ReadOnlySpan<byte> a, ReadOnlySpan<byte> b);   // CryptographicOperations.FixedTimeEquals
}

public abstract record Amf0Value { /* Number, Boolean, String, Null, Undefined, Date, Object, EcmaArray, StrictArray */ }
public static class Amf0 { public static IReadOnlyList<Amf0Value> DecodeAll(ReadOnlySpan<byte> b, IngestLimits l); public static byte[] Encode(IEnumerable<Amf0Value> v); }

public enum VideoCodec { Avc, Hevc }
public enum AudioCodec { Aac }
public abstract record FlvMedia;
public sealed record VideoConfig(VideoCodec Codec, byte[] Record) : FlvMedia;
public sealed record VideoFrame(VideoCodec Codec, uint DtsMs, int CtsMs, bool Keyframe, byte[] Data) : FlvMedia;
public sealed record AudioConfig(AudioCodec Codec, byte[] Asc) : FlvMedia;
public sealed record AudioFrame(AudioCodec Codec, uint DtsMs, byte[] Data) : FlvMedia;
public sealed record AudioSilence(uint DtsMs) : FlvMedia;
public sealed record Unsupported(UnsupportedKind Kind, string FourCc) : FlvMedia;

public abstract record RtmpOutput
{
    public sealed record Send(byte[] Bytes) : RtmpOutput;
    public sealed record Event(RtmpEvent Value) : RtmpOutput;
    public sealed record Close(RtmpCloseReason Reason) : RtmpOutput;
}
public sealed record RtmpServerConfig(string ExpectedKey, byte[] ServerRandom /* 3032 */, uint ServerTime, IngestLimits Limits);

/// Sans-I/O server side of one RTMP connection. Not thread-safe: owned by one connection task.
public sealed class RtmpServerProtocol(RtmpServerConfig config)
{
    public IReadOnlyList<RtmpOutput> Receive(ReadOnlySpan<byte> bytes);
    public IReadOnlyList<RtmpOutput> TimedOut(RtmpTimeout kind);
    public ulong TotalBytesConsumed { get; }
}

public sealed class TimelineMapper(IngestLimits limits)
{
    public long Map(uint raw, MediaTrack track, long nominalMs);
    public void BeginNewConnection();
    public IReadOnlyList<TimelineMarker> Markers { get; }
}
public sealed class AudioSampleClock(int sampleRate, int reanchorMs)
{
    public readonly record struct Placement(long SilenceFrames, int DropFrames, long WriteAtSample, int WriteFrames);
    public Placement Place(long takeMs, int frames, bool force);
}
public sealed class IngestSessionReducer(IngestLimits limits, long nowMs, bool continueAfterTake)
{
    public IngestSessionState State { get; }
    public IReadOnlyList<IngestAction> Handle(IngestInput input, long nowMs);
}
public static class HttpRequestParser { public static HttpParseResult Parse(ReadOnlySpan<byte> head, IngestLimits limits); }
public sealed class LanRouter { public LanRoute Route(HttpRequestHead head, string boundHost); }
public sealed class UploadSessionStore { /* Create, Patch, Advance, Tick: same semantics as Swift */ }

// VoxClip.Media/Ingest — sockets, FFmpeg
public sealed class RtmpReceiver : IAsyncDisposable
{
    public RtmpReceiver(LanInterface nic, PeerPolicy policy, int preferredPort, string key, IngestLimits limits,
                        string receivedFolder, IngestDeviceCatalog devices);
    public Task<int> StartAsync(CancellationToken ct);                       // bound port
    public ChannelReader<ReceiverEvent> Events { get; }
    public ChannelReader<AudioFeedChunk> AudioFeed { get; }
    public ChannelReader<PreviewFrame> Preview { get; }                       // BGRA at preview size, capacity 2, drop oldest
    public Task<IReadOnlyList<TakeResult>> EndTakeAsync(CancellationToken ct);
    public ValueTask DisposeAsync();
}
public sealed unsafe class LiveTakeRecorder : IDisposable                    // AVFormatContext owned by thread "vc-ingest-mux"
{
    public LiveTakeRecorder(string moviePath, string journalPath, VideoConfig? video, AudioConfig? audio, IngestLimits limits);
    public void WriteVideo(VideoFrame f, long dts90, long pts90);
    public AudioSampleClock.Placement WriteAac(AudioFrame f, long takeMs, bool force);
    public TakeResult Finish();
    public static TakeResult RecoverFromJournal(string journalPath, string moviePath, CancellationToken ct);
}
public sealed class LanHttpServer : IAsyncDisposable
{
    public LanHttpServer(LanInterface nic, PeerPolicy policy, IngestLimits limits, string assetsFolder);
    public Task<int> StartAsync(CancellationToken ct);
    public UploadSessionHandle OpenUploadSession(string folder);
    public HelperSessionHandle OpenHelperSession(string rtmpUrl);
    public void Close(string token);
}

// VoxClip.App/Ingest — Windows-only pieces and view models
[SupportedOSPlatform("windows")]
public sealed record FirewallStatus(bool EnabledOnCurrentProfile, bool CurrentProfileIsPublicOnly, bool BlockAllInbound,
                                    bool LocalRulesTakeEffect, bool HasAllowRuleForPrivate, bool HasBlockRuleForApp);
[SupportedOSPlatform("windows")]
public interface IFirewallPolicy { FirewallStatus Read(string exePath); }      // INetFwPolicy2 via COM; faked in tests
[SupportedOSPlatform("windows")]
public static class FirewallHelper
{
    public static Task<FirewallHelperResult> RunElevatedAsync(FirewallHelperVerb verb, CancellationToken ct);  // runas; helper uses its own path
    public static int Main(string[] args);                                     // "--firewall-helper add|remove", no UI
}

public sealed partial class ReceiveViewModel : ObservableObject
{
    [ObservableProperty] public partial ReceivePhase Phase { get; private set; }   // Preflight, Blocked, Waiting, Connecting, Live, Reconnecting, Finalizing, Finished, Failed
    public ObservableCollection<IngestNotice> Notices { get; } = [];
    [RelayCommand] private Task StartAsync(CancellationToken ct);
    [RelayCommand] private Task EndTakeAsync(CancellationToken ct);
    [RelayCommand] private Task AllowFirewallAsync(CancellationToken ct);
    [RelayCommand] private Task ResetAddressAsync(CancellationToken ct);
}
```

---

## 17. Errors and CLI

### 17.1 Error codes (added to architecture.md §10.2)

| Code | Raised by | Copy |
|---|---|---|
| `ingestNoNetwork` | interface selection | "Connect this {Mac/PC} to Wi-Fi or Ethernet to receive from a camera." |
| `ingestPortsBusy` | listeners | "Another app is using ports {range}. Quit apps that receive streams, such as OBS, then try again." |
| `ingestFirewallBlocked` | Windows preflight | "Windows Firewall needs your permission before cameras and phones can connect." (variants in 15.2) |
| `ingestFirewallManaged` | Windows preflight | "Your organization manages Windows Firewall on this PC. Ask your administrator to allow VoxClip on TCP ports 1935 to 1945 and 8765 to 8775 for private networks." |
| `ingestNetworkPublic` | Windows preflight | "This network is set to Public, so Windows blocks cameras and phones. If you trust this network, make it Private in Settings." |
| `ingestUnsupportedCodec` | receiver | "This camera sends {codec} video, which VoxClip can't record yet. Use H.264 or HEVC." |
| `ingestWriterFailed` | recorder | "Recording stopped: {reason}. The take is saved up to {elapsed}." |
| `uploadNotVideo` | phone upload | "{name} isn't a video VoxClip can open. It's saved in {folder}." |
| `liveClipRenderFailed` | live clip renderer (section 9.12) | "Couldn't render this clip: {reason}. The stream is still being recorded." |

`diskFull` and `cancelled` are reused. AI watching reports the ai.md §5 errors (section 9.6.3).

### 17.2 CLI subcommands (added to architecture.md §9.2)

```text
voxclip-cli ingest rtmp --bind <ipv4> [--allow-loopback] [--port <n>] --out <dir>
                        [--key <key>]                      default: env VOXCLIP_INGEST_KEY, else a fresh key printed to stderr
                        [--max-takes <n>] [--reconnect-window <s>] [--idle-timeout <s>] [--feed-wav <path>]
                        [--clip-at <s>[,<s>…]] [--clip-lookback <s>] [--clip-out <dir>]
                        [--live-words-out <path.jsonl>] [--json]
voxclip-cli ingest upload --bind <ipv4> [--allow-loopback] [--port <n>] --out <dir>
                        [--token <t>]                      default: env VOXCLIP_UPLOAD_TOKEN, else fresh
                        [--uploads <n>] [--idle <s>] [--max-gb <n>] [--json]
voxclip-cli ingest replay --case <shared/fixtures/ingest/rtmp/<id>> --out <dir> [--check] [--json]
voxclip-cli ingest live-replay --case <shared/fixtures/ingest/live/cases/<id>> [--check] [--json]
voxclip-cli ingest inspect <take.mov> [--frame-hashes] --json
voxclip-cli ingest interfaces --json
```

- `ingest rtmp` listens until `--max-takes` takes (default 1) are finalized, or until `--idle-timeout` (default `waitingAutoOff`) passes without a publisher. It never touches the Keychain or DPAPI and never runs the Windows firewall preflight (tests bind loopback). SIGINT / Ctrl+C **finalizes** the current take (it is not deleted, unlike export) and exits 6.
- `ingest replay` feeds the case's client byte files through `RTMPServerProtocol` and the platform recorder without sockets. `--check` compares the result with the case's expectations and exits 0 on a match, 1 with a JSON diff otherwise.
- `ingest inspect` prints tracks, codec tags, first PTS per track, durations, sample counts, the take sidecar if found, and with `--frame-hashes` the SHA-256 of every compressed video sample in decode order.
- `--feed-wav` writes the 16 kHz feed as a 16-bit WAV for sync tests.
- `--clip-at` fires a "clip that" trigger at each given take time (seconds, as if the button were pressed then), with `--clip-lookback` (default 45) and the section 9.4.3 rules, and renders each clip from the sealed take into `--clip-out` with captions off, using `liveFragmentInterval` on macOS. The CLI never runs AI watching. Each clip appears in the JSON as `{ "takeSeconds", "start", "end", "path", "renderedBeforeTakeEnd" }` under its take's `clips`.
- `--live-words-out` records the live engine's events (section 9.2) as JSONL in the `events.jsonl` format of section 9.13, for building replay cases. Words only, no audio.
- `ingest live-replay` runs one live clipping replay case (section 9.13) through `LiveClipEngine` with the fake connector and renderer. `--check` compares with the case's expectations and exits 0 on a match, 1 with a JSON diff otherwise.
- `--json` prints one object on stdout at the end:

```json
{ "ok": true, "command": "ingest-rtmp", "bound": "127.0.0.1:1935", "digestHandshake": true,
  "rejectedPublishers": 1, "takes": [ { "path": "/abs/2026-10-25 14.03 Live take.mov", "videoCodec": "hvc1",
  "width": 1280, "height": 720, "frames": 360, "audioSampleRate": 48000, "audioChannels": 2, "audioFrames": 576000,
  "durationSeconds": 12.0, "connections": 2, "nudgedFrames": 0, "silenceInsertedSeconds": 0.5,
  "markers": [ { "atSeconds": 6.921, "kind": "reconnect" } ] } ], "version": "0.2.0" }
```

Exit codes: 0 success; 2 usage; 3 no publisher before the idle timeout, unsupported codec or invalid stream; 5 recorder failed (including `diskFull`); 6 cancelled (take finalized); **8 (new) the listener could not start** (`ingestNoNetwork`, `ingestPortsBusy`, bind refused).

---

## 18. Automated test plan

Everything here runs without a camera. Publishers are byte fixtures replayed by the tests, or a local FFmpeg ≥ 6.1 doing `-c copy` pushes. Encoding happens only when fixtures are regenerated.

### 18.1 Tiers

| Tier | What | Where it runs | Needs |
|---|---|---|---|
| A | Pure Core: AMF0, handshake, chunking, FLV, codec configs, mapper, audio clock, session reducer, HTTP parser, router, tus store, interface selection, peer policy, key and token formats, file-name sanitizer, and the live clipping engine with its replay cases (section 9.13) | every CI run; Swift on macOS, C# on macOS and Windows | nothing |
| B | Sockets and recorders in-process: a test publisher replays fixture client bytes over real loopback TCP into the receiver; a test HTTP client drives uploads | every CI run (macOS: Swift media tests; Windows: `Category=RequiresFFmpeg` for the recorder) | the pinned FFmpeg on Windows |
| C | Live FFmpeg pushes and curl against `voxclip-cli ingest` | Windows CI with the BtbN LGPL `ffmpeg.exe` from `apps/windows/build/ffmpeg.json`; macOS when `VOXCLIP_TEST_FFMPEG=<path to ffmpeg ≥ 6.1>` is set | FFmpeg (remux only, so an LGPL build is enough), curl |
| D | Browser automation of the upload page and the helper page's Clip that button (Playwright or Chrome DevTools) | nightly or manual | Chrome |
| HW | Section 19 | manual | a Pocket 4 |

### 18.2 Fixture layout and generator

```text
shared/fixtures/ingest/                  (unrelated to shared/fixtures/editing/ingest, which is word ingest)
  README.md
  media/        sync_h264.mp4 (~50 KB), sync_hevc.mp4 (~74 KB), speech_h264.mp4, pocket4-like-2tracks.mov (M1)
  flv/          the same media remuxed by FFmpeg to FLV / Enhanced FLV (generator input)
  rtmp/<case>/  case.json, client-1.bin [, client-2.bin …], timeline.json
  amf0.json  handshake.json  chunking.json  flv-tags.json  codec-config.json
  timeline.json  audio-clock.json  session.json
  http.json  tus.json  interfaces.json  peers.json  secrets.json  filenames.json
  live/         live clipping vectors and replay cases (section 9.13)
```

- **Generator:** `tools/fixtures/ingest/` (Node 22), `npm --prefix tools/fixtures/ingest run generate`. It reads the FLV files, builds client byte streams (C0/C1/C2, the FFmpeg-style command sequence, chunked media at a chosen chunk size) for each case, and computes the expectations with a small JavaScript reference of sections 6 and 7 (mapper, clock, reducer) and of section 9 (live clipping). Swift, C# and the reference must agree. CI's fixtures job runs the generator and fails on any diff, as for editing fixtures. Hand edits follow the README rule in AGENTS.md.
- **Media regeneration** (developer machine only, never CI): `tools/fixtures/ingest/make-media.sh`, using FFmpeg ≥ 6.1 with VideoToolbox:

```bash
# A/V sync clip: white flash frames and 1 kHz beeps at 2, 5 and 9 s; H.264 High with B-frames, AAC 48 kHz stereo
ffmpeg -f lavfi -i "color=c=black:size=1280x720:rate=30,drawbox=x=0:y=0:w=iw:h=ih:color=white:t=fill:enable='between(t,2,2.099)+between(t,5,5.099)+between(t,9,9.099)'" \
  -f lavfi -i "sine=frequency=1000:sample_rate=48000,volume=0:enable='not(between(t,2,2.1)+between(t,5,5.1)+between(t,9,9.1))'" \
  -t 12 -c:v h264_videotoolbox -profile:v high -b:v 2M -g 60 -bf 2 -c:a aac -b:a 128k -ac 2 media/sync_h264.mp4
ffmpeg -i media/sync_h264.mp4 -c:v hevc_videotoolbox -tag:v hvc1 -b:v 3M -g 60 -c:a copy media/sync_hevc.mp4   # Pocket-4-like
# Pocket-4-like file for M1: HEVC Main 10, track 1 = "DJI Mic" (1 kHz tone L/R), track 2 = built-in mics (300 Hz)
ffmpeg -f lavfi -i testsrc2=size=1280x720:rate=30 -f lavfi -i sine=frequency=1000:sample_rate=48000 -f lavfi -i sine=frequency=300:sample_rate=48000 \
  -map 0:v -map 1:a -map 2:a -t 6 -c:v hevc_videotoolbox -profile:v main10 -pix_fmt p010le -tag:v hvc1 -b:v 1M \
  -c:a aac -b:a 96k -ac 2 media/pocket4-like-2tracks.mov
# FLV inputs for the generator (FFmpeg ≥ 6.1 writes HEVC as Enhanced FLV automatically)
ffmpeg -i media/sync_h264.mp4 -c copy -f flv flv/sync_h264.flv
ffmpeg -i media/sync_hevc.mp4 -c copy -f flv flv/sync_hevc.flv
```

Every fixture file stays at or below 2 MB (AGENTS.md).

### 18.3 RTMP cases (`rtmp/<case>/`)

Each `case.json` names the key, the client files, the injected `serverRandom` (zeros) and `serverTime` (0), and expects: the event summary, the SHA-256 of all server bytes per connection, the video codec, the SHA-256 of the sequence-header record, frame and keyframe counts, the per-frame SHA-256 list of the NAL payloads, the audio ASC, the audio frame count, the mapped DTS / PTS lists (in `timeline.json`), the audio placements and the markers.

| Case | Checks |
|---|---|
| `avc-legacy-bframes` | codec id 7 with SI24 CTS; DTS nudges counted; legacy AAC `0xAF` |
| `hevc-ertmp-codedframesx` | `0x90 'hvc1'` + `0x93`/`0xA3` (FFmpeg 6.1 form) |
| `hevc-ertmp-codedframes` | CodedFrames with SI24 CTS |
| `hevc-legacy-id12` | pre-standard codec id 12 (FFmpeg cannot emit it; built by the generator) |
| `ertmp-connect-fourcclist` | `fourCcList` and `capsEx` in `connect` are recorded and change nothing |
| `audio-ertmp-mp4a` | `soundFormat 9`, `mp4a`, zero-length frame → silence |
| `multitrack-one`, `multitrack-many` | only track 0 is used; others counted |
| `modex-nano-offset` | ModEx skipped correctly; payload intact |
| `aggregate` | sub-message timestamps rebased to the aggregate timestamp |
| `extended-timestamp` | starts at ts ≥ 0xFFFFFF; fmt-3 continuation chunks repeat the 4 bytes |
| `chunksize-128` | no Set Chunk Size from the client |
| `abort` | partial message dropped |
| `window-ack` | client sets W = 2,500,000; server Acks at the exact message boundaries |
| `handshake-digest`, `handshake-plain` | digest detected or not; server bytes byte-exact |
| `rtmpe-rejected` | C0 = 6 → close `rtmpeUnsupported`, no reply bytes |
| `wrong-key` | `NetStream.Publish.BadName` with description "Invalid stream key", then close |
| `key-in-app`, `key-in-tcurl`, `key-query`, `key-trailing-slash`, `key-capitalized`, `key-no-dashes` | section 6.6 normalization |
| `reconnect-same-config` | two connections, the second restarting at ts 0 → one take, one `reconnect` marker, forced audio re-anchor |
| `reconnect-changed-config` | two takes |
| `replace-publisher` | second publisher while the first is open → first closed `replaced`, one take |
| `sequence-change-midstream` | new SequenceStart → two takes |
| `ts-jump-forward`, `ts-jump-backward`, `ts-wrap` | markers, wrap-safe unwrapping |
| `oversize-message`, `amf-depth-bomb`, `command-flood`, `prepublish-media-flood` | close with the right reason before large allocations |
| `play-request` | `NetStream.Play.Failed`, close |
| `video-vp09`, `audio-opus` | `unsupported` handling of section 6.12 |
| `audio-only`, `video-only` | `preBufferMax` start rules |
| `ffmpeg-capture-hevc` | real FFmpeg 6.1 client bytes recorded through a capture proxy (`tools/fixtures/ingest/capture.mjs`) |
| `pocket4-fw01.04.12.16` | added after H1: the camera's real client bytes over a synthetic scene |

Socket-level cases not expressible as bytes (Tier B): handshake slow-loris (1 byte per second must time out at `handshakeTimeout`, injected as 0.5 s), half-open publisher (no FIN; the replacement publisher wins), `readIdleTimeout`, `maxPendingConnections`, throttle after 10 wrong keys, listener gone after `waitingAutoOff` (injected 1 s; checked with a refused connect).

### 18.4 Recording and sync assertions (Tier B, both platforms)

For `sync_h264`, `sync_hevc`, `reconnect-same-config` and `ffmpeg-capture-hevc` replayed through the real receiver into a `.mov`:

1. **Passthrough identity:** the SHA-256 list of compressed video samples read back (macOS `AVAssetReaderTrackOutput` with `outputSettings: nil`; Windows `av_read_frame`) equals the fixture's list. **Measured:** 600/600 frames and a 4K MD5 matched in the prototype.
2. **Container:** two tracks; video `avc1` or `hvc1` (never `hev1`); audio LPCM s16 (`sowt` / `pcm_s16le`) at 48,000 Hz, 2 channels; first presented video frame at time 0; AVFoundation lists both tracks.
3. **Sync:** with the platform's own reader, find flash frames (mean luma > 128) and beep onsets (first sample above −20 dBFS after silence). Pass when `|(beep − flash)_out − (beep − flash)_src| ≤ 1 ms` for every event, including after the reconnect.
4. **Feed:** beep onsets in the `--feed-wav` output equal the file's onsets within 1 ms.
5. **Markers:** exactly the expected markers; the sidecar matches the JSON output.
6. **Crash recovery:** kill the recorder mid-take (macOS: drop the actor without `finish`; Windows: dispose without trailer), run recovery, and check rules 1–3 on the recovered file up to the last flushed point.

### 18.5 Live FFmpeg pushes (Tier C)

Run against `voxclip-cli ingest rtmp --bind 127.0.0.1 --allow-loopback --port 19350 --key <k> --out <tmp> --json`:

```bash
ffmpeg -re -i media/sync_h264.mp4 -c copy -f flv rtmp://127.0.0.1:19350/live/<k>                                   # legacy AVC + AAC
ffmpeg -re -i media/sync_hevc.mp4 -c copy -f flv rtmp://127.0.0.1:19350/live/<k>                                   # E-RTMP hvc1
ffmpeg -re -i media/sync_hevc.mp4 -c copy -rtmp_enhanced_codecs hvc1,av01 -f flv rtmp://127.0.0.1:19350/live/<k>   # fourCcList in connect
ffmpeg -re -i media/sync_h264.mp4 -c copy -f flv rtmp://127.0.0.1:19350/live/WRONG                                 # must fail: "Invalid stream key"
# reconnect: kill the publisher at about 6.5 s and republish from 6 s within the window
ffmpeg -re -i media/sync_h264.mp4 -c copy -f flv rtmp://127.0.0.1:19350/live/<k> & sleep 6.5; kill -9 $!; sleep 2
ffmpeg -re -ss 6 -i media/sync_h264.mp4 -c copy -f flv rtmp://127.0.0.1:19350/live/<k>
```

Assertions: the CLI JSON (takes, markers, rejected publishers), then section 18.4 rules 2–5 on the output. Cross-reader check (manual or nightly on a Mac with FFmpeg): a take written on macOS reads with the same onsets in `ffprobe`, and a take written by the Windows code reads the same in AVFoundation (the Windows recorder also builds and runs on macOS against local FFmpeg libraries, as the prototype did).

Throughput (developer machine only, release build): a 20 s 4K30 HEVC 50 Mbps file generated into `/tmp` and pushed without `-re` must ingest at ≥ 200 Mbit/s on loopback. **Measured:** about 4 Gbit/s on the prototype, so this only guards against regressions.

### 18.6 Upload tests

- **Tier A (`tus.json`, `http.json`):** sequences of requests with injected free space and time, and the exact expected statuses and headers: create, `HEAD`, `PATCH`, partial body, `409` wrong offset, `413` over length and over `maxPatchBody`, `415` content type and file type, `429` too many uploads, `507` low disk including other uploads' reservations, `410` after close, `404` unknown token or id, `421` wrong `Host`, `403` wrong `Origin`, `411`, `501` chunked, `505` HTTP/1.0, `431` large head, `100 Continue` handling, session expiry at both idle limits.
- **Tier B:** an in-test HTTP client over loopback: upload a generated 50 MB file in 8 MiB chunks, abort mid-body, `HEAD`, resume, compare SHA-256; head slow-loris closes at the injected timeout; the server stops listening after the last session closes.
- **Tier C (curl, on both CI runners):** `--expect100-timeout`, a mid-chunk kill and resume, then SHA-256 equality, as measured in the prototype.
- **Tier D:** Chrome via automation: generate a `File` in the page, upload, switch the network offline and online, reload mid-upload, compare hashes; check `isSecureContext === false` and that the page makes no request outside the origin.

### 18.7 Network, security and logging tests

- `interfaces.json`: interface lists (including the measured `en0` + `bridge100` case, Windows WSL and Hyper-V adapters, two physical NICs, no candidates) → candidates and pick.
- `peers.json`: subnet admission (inside, outside, other private ranges, loopback in both modes, broadcast and network addresses).
- `secrets.json`: fixed random bytes → key and token strings; normalization and constant-time compare vectors.
- Binding (Tier B, `Category=RequiresLan` on Windows, enabled on macOS when a candidate interface exists): bound to the LAN address, a connect to 127.0.0.1 is refused.
- **Logging:** run the replay and upload tests with a capturing log sink and assert that the key, the tokens and every publish-name candidate never appear in any line. The live clipping replay cases add the same check for transcript text, titles, reasons, trigger phrases and instructions (section 9.13).

### 18.8 Windows-specific

- `FirewallManager` decision table against a fake `IFirewallPolicy`: each preflight branch of section 13.4.
- W-6 (manual, fresh Windows 11 VM, x64 and arm64): read the policy as a standard user; Public network → notice; switching to Private → the rule applies; UAC cancel → cancelled copy; a pre-existing block rule from Windows' own prompt is removed by the helper; `Get-NetFirewallRule -Group VoxClip` shows exactly one rule; **Remove firewall rule** removes it.
- The upload server runs as a standard user with no URL ACL.
- W-7 (manual, fresh Windows 11 VM, x64 and arm64, Velopack install): with AI watching on and VoxClip in the background, a strong clip shows one app notification; clicking it activates the running instance and selects the clip; a superseding clip replaces the notification; the global "clip that" shortcut works from another app and is unregistered when the take ends.

### 18.9 Platform and milestone checks

- **M1 (both platforms):** `pocket4-like-2tracks.mov` opens, previews, and the extracted 16 kHz WAV contains the 1 kHz tone (track 1), not the 300 Hz tone (track 2); export carries track 1. HEVC Main 10 decodes (Windows: FFmpeg; macOS: AVFoundation).
- **W-3:** the Windows recorder's PCM-in-MOV output passes section 18.4 rules 2–3 in **both** readers. If it does not, fall back to the measured non-fragmented MP4 with AAC passthrough, and replace audio gaps by re-anchoring with silent AAC frames from FFmpeg's native encoder; record the change in this spec.
- **macOS fresh account:** starting Receive and Send from your phone shows no Local Network alert (section 13.3).
- `bundle.sh` includes `shared/ingest/web/` and `shared/ingest/live-clip-triggers.json` in the app (section 20).
- **Live clipping (M2):** test L-B1 passes on both platforms before "clip that" ships (section 9.7.1); on macOS a Developer-ID build shows a live clip notification and the global shortcut works without an Accessibility prompt.

### 18.10 CI wiring

| Job | Adds |
|---|---|
| macOS | Swift Tier A and B; C# Tier A on macOS; Tier C when `VOXCLIP_TEST_FFMPEG` is set |
| Windows | C# Tier A and B (`RequiresFFmpeg` with the pinned build); Tier C with the pinned `ffmpeg.exe` and the system `curl.exe` |
| Fixtures | `npm --prefix tools/fixtures/ingest run generate && git diff --exit-code` (including `live/`); `shared/ingest/live-clip-triggers.json` equals the table in section 9.4.2; JSON validity; fixture size ≤ 2 MB |

---

## 19. Hardware verification (needs a real Osmo Pocket 4)

Setup: Pocket 4 on the latest firmware (v01.04.12.16 or newer), an iPhone with the current DJI Mimo, a Mac and a Windows 11 PC on the same Wi-Fi; ideally also a Pocket 3 (US baseline) and an Action 6. Record every result with the firmware and Mimo versions, and add captured client bytes as fixtures.

| # | Test | Decides |
|---|---|---|
| H1 | Mimo → Livestream → RTMP to VoxClip at 1080p / 6 Mbps. Log the handshake type, `flashVer`, `connect` fields, command order, codec signalling (legacy id 12 or `hvc1`; CodedFrames or CodedFramesX), HEVC profile (Main or Main 10), ASC, first timestamps, jitter, `@setDataFrame`, and latency | Parser scope confirmed; the `pocket4-fw…` fixture; marketing copy |
| H2 | The same on a router with no internet, and on an iPhone hotspot with the computer joined | Whether "works offline" can be claimed |
| H3 | Can Mimo's RTMP field take a paste from the helper page? Is the lowercase key kept? Do port 1936 and the trailing-slash path work? Does Mimo remember the address between sessions? | Helper page value; address format |
| H4 | Walk out of Wi-Fi range for 5, 15 and 60 s. Does the camera reconnect by itself, with which timestamps, and does the old socket linger? | `reconnectWindow`, `readIdleTimeout` |
| H5 | Stop from Mimo and from the camera: `FCUnpublish` / `deleteStream`, or only a TCP close? | `unpublishGrace` |
| H6 | Clap test at 1080p30, 6 Mbps: A/V offset of the received take | `audioOffsetMs` in `ingest-devices.json` |
| H7 | Does the camera keep an internal recording while streaming (any "save to card" option)? If so, record 20 minutes with two reconnects and keep both files | Copy about keeping a sharper original; whether live clips onto the camera file (section 9.8.2) ship; `cameraMatchMinCorrelation` |
| H8 | Camera Cloud Service → NAS pointed at a macOS File Sharing share and at a Windows 11 share: SMB dialect, encryption toggle, account type, folder layout, file names, whether originals or proxies arrive, re-upload behaviour, speed for a 10-minute 4K file, need for internet | Whether the DJI setup guide ships |
| H9 | UVC on macOS 26/27 and Windows 11: formats offered, whether a microphone appears (UAC), whether a linked DJI Mic is routed to it | Record view guidance |
| H10 | macOS firewall on and off; Windows Public and Private; a guest network with client isolation (expected to fail with the hint) | Hint copy |
| H11 | iPhone Safari (iOS 26/27): QR page, Photos picker with Automatic and Current, Files, screen lock and app switch mid-upload, reload mid-upload, `execCommand` copy on the helper page; Android Chrome; an 8 GB file | Page copy, resume behaviour |
| H12 | Import of real Pocket 4 files: 4K HEVC 10-bit D-Log, with and without a DJI Mic (two tracks), slow motion with its separate AAC file | M1 compatibility claim |
| H13 | Pocket 3 → Mimo RTMP (H.264, classic RTMP) | US baseline works |
| H14 | Live clipping on a real 30-minute Pocket 4 stream, on a base M1 Mac and a mid-range Windows PC: "clip that" by voice in English and Estonian, by ⌘K / Ctrl+K and by the phone page, and AI watching with one cloud and one local connector. Measure trigger-to-ready time for a 45 s 9:16 clip, false and missed voice triggers, how many AI clips were kept, and the receiver's stats compared with a stream without clipping | Release copy about live clips; `liveEvalMinInterval`, `liveSettleSeconds`, `minScore` and `maxPerHour` defaults |

---

## 20. Changes required in other documents

This spec only adds `doc/spec/ingest.md`. The owners of these documents apply the following in the M2 work:

| Document | Change |
|---|---|
| `doc/architecture.md` | §1.1 spec-map row for this file; §1 layout: `shared/ingest/web/`, `shared/ingest/live-clip-triggers.json`, `shared/fixtures/ingest/`, `tools/fixtures/ingest/`; §2 placement of the `Ingest` and `Ingest/LiveClips` folders (section 4.2); §2.5 the Received folder, `<data>/Ingest/` and `<data>/Cache/LiveClips/`; §5.1 and §6.4 the live clip renderer as a second caller of the one compose path (section 9.7); §7.1 the preview-renderer hand-off as an allowed exception with its invariant, and `LiveClipCoordinator` / `LiveClipRenderer` in the actor list; §7.2 the `vc-live-render` thread; §9.2 `ingest` subcommands, including `live-replay` and the `--clip-at` / `--live-words-out` options; §9.3 exit code 8; §10.2 the codes in section 17.1; §11.1 log category `ingest`; §11.3 both "What leaves this device" lines (section 14 rule 10); §11.4 secret account `ingest-rtmp-key`; §12 the fixtures-job line |
| `doc/design.md` | §2 information architecture (From camera or phone); §7 Welcome / Home menu button and sections; §10 Settings → Receive pane, including the Clip that and AI watching rows; §11.2 ⌘K / Ctrl+K as **Clip that** in the Receive window, and the optional global shortcut; §11.3 File menu items; §13 the states in sections 9.9 and 15 |
| `doc/decisions.md` | ING-1 to ING-15 as refinements of ADR-027 |
| `doc/release.md` | Info.plist `NSLocalNetworkUsageDescription` (section 13.3); `bundle.sh` copies `shared/ingest` (its list today is `design fonts captions prompts schemas models`); entitlement check unchanged (notifications and Carbon hot keys need no entitlement); Windows notes on the firewall helper, the leftover rule after uninstall, and `AppNotificationManager` registration in the unpackaged app (W-7) |
| `THIRD_PARTY_NOTICES.md` and About → Licences | QRCoder (MIT) for Windows; Moblin (MIT) only if code is copied. Live clipping adds no dependency |
| `shared/schemas/settings.schema.json` | the keys in section 4.4, including `ingest.liveClips.*` |
| `doc/spec/ai.md` | No behaviour change and no new preset; the prompt file and the §11.7 preset table stay as they are (section 9.5.4). Add: a §11 note that ingest's live clipping reuses the pipeline for windows of a live transcript; for requests tagged `live/…`, §6.1 omits `cache_control` (a growing block never reads the cache, and writes cost more) and §6.2 derives `prompt_cache_key` from the take id instead of the block, so one stream's requests share a cache. §7.1 rule 5 stays: AI watching never runs a CLI connector by itself |
| `shared/fixtures/llm/clip-finder-requests.json` | a live window case (section 9.5.4), regenerated with the prompt parity test |
| `doc/spec/editing.md` | none for M2: markers live in the take sidecar, and live clips become ordinary clip ranges (`origin: ai` with an `aiResult`, or `origin: manual`; section 9.8.1). A later project-schema version may carry markers inline or add a `live` origin |
| `doc/spec/captions.md` | none; live drafts use the session's style through the one renderer |
| `doc/publishing.md` | none; the tray's **Share…** uses the §2 share helpers, and VoxConvo posting stays an explicit action |
| `doc/spec/transcription.md` | none (the first enabled audio track is already the rule); the M1 test in 18.9 joins its acceptance list. Clip transcription (section 9.4.4) runs the existing batch engines on an excerpt |
| M2 Recording spec (to be written) | owns the live transcription engine and consumes the 16 kHz feed of section 8.9 unchanged; for each engine it states the finalisation rule and emits the `final` and `processed` events of section 9.2 |

---

## 21. Later, not in v1

- **SRT listener.** No Pocket camera speaks SRT ([SRT Mini Server](https://srtminiserver.com/blog/dji-osmo-pocket-4-rtmp-hevc/)); only phone apps such as Moblin or Larix would use it. Windows: the BtbN n9.0 LGPL build includes `--enable-libsrt` (measured from its configure line), so `avformat_open_input("srt://<ip>:9000?mode=listener&passphrase=…&streamid=<key>")` with the `mpegts` demuxer would work. macOS: no native SRT; it needs libsrt (MPL-2.0) and a TS demuxer, and replying over UDP to a LAN peer **does** need the Local Network privilege (TN3179), plus a UDP firewall rule on Windows. v2 at the earliest.
- **Phone-free Bluetooth control** (VoxClip sends Wi-Fi credentials, the RTMP URL, resolution, bitrate and `codec` to the camera, then start and stop). The protocol is public through MIT, CC0 and Apache-2.0 projects verified on the Pocket 4 ([Moblin](https://github.com/eerimoq/moblin/tree/main/Moblin/Integrations/Dji), [djictl](https://github.com/xaionaro-go/djictl), [Osmosis](https://github.com/KonradIT/osmosis), [OpenPocketCine](https://github.com/erik-sutton95/OpenPocketCine)). It is reverse-engineered, can break with any firmware, needs Bluetooth permission and `NSBluetoothAlwaysUsageDescription`, and needs a review of DJI's terms. A separate spec, behind an "experimental, unofficial" switch, if ever.
- **Offload from the camera's access point** (`192.168.2.1`, HTTP `/v2` with Range). Takes the computer off its own Wi-Fi unless it has Ethernet; outgoing LAN connections need the macOS Local Network privilege; joining networks needs CoreWLAN or WLAN APIs. Same status as Bluetooth control.
- **Swap the live take for the camera original.** Find the offset by cross-correlating the 16 kHz audio of both files, then relink. Needs a source time offset in the project format, because source word timings never change (ADR-024). Later. Live clips do not wait for it: section 9.8.2 places them in the camera file's own project (M2.x, after H7).
- **AI watching with the CLI connectors.** Automatic checks through Claude Code or Codex would need a superseding decision on ai.md §7.1 rule 5 and a confirmed reading of the vendors' terms. Until then those connectors run only on **Find clips now** (section 9.5.1).
- **AV1 over E-RTMP** (`av01`). Cheap to parse, but recording and preview need AV1 hardware decode that many supported Macs and PCs lack.
- **Bonjour discovery, HTTPS on the LAN, an iOS Shortcut using a background `URLSession` for uploads.** Revisit if users ask.

---

## 22. Sources (all accessed 2026-10-25)

**Camera and DJI**
- DJI Osmo Pocket 4 specs: https://www.dji.com/global/osmo-pocket-4/specs
- DJI Osmo Pocket 4 FAQ: https://www.dji.com/global/osmo-pocket-4/faq
- DJI Osmo Pocket 4 release notes, 2026-10-14 (v01.04.12.16): https://terra-1-g.djicdn.com/6189933d30024fc1b331bffe4fe41837/osmo-pocket-4/RN/20261014/DJI_Osmo_Pocket_4_Release_Notes_en.pdf
- DJI Osmo Pocket 4 release notes, 2026-08-04 (v01.03.10.05, Camera Cloud Service): https://terra-1-g.djicdn.com/6189933d30024fc1b331bffe4fe41837/osmo-pocket-4/RN/20260804/DJI_Osmo_Pocket_4_Release_Notes_en.pdf
- DJI Osmo Pocket 3 release notes (to 2025-08-26): https://dl.djicdn.com/downloads/DJI_Osmo_Pocket_3/RN/20250826/DJI_Osmo_Pocket_3_Release_Notes_en.pdf
- DJI Mimo livestream guide: https://support.dji.com/help/content?customId=en-us03400006728&spaceId=34&re=US&lang=en
- DJI webcam guide: https://support.dji.com/help/content?customId=en-us03400006962&spaceId=34&re=US&lang=en
- DJI footage export guide: https://support.dji.com/help/content?customId=en-us03400006849&spaceId=34&re=US&lang=en
- DJI Studio: https://www.dji.com/downloads/softwares/dji-studio ; LightCut: https://www.dji.com/global/lightcut
- CineD (2026-04-16): https://www.cined.com/dji-osmo-pocket-4-announced-4k-240fps-activetrack-7-0-and-built-in-107gb-storage/
- Newsshooter (2026-04-16): https://www.newsshooter.com/2026/04/16/dji-osmo-pocket-4-announced-but-not-available-in-the-us-due-to-pending-fcc-authorization/
- PetaPixel (2026-04-16): https://petapixel.com/2026/04/16/the-dji-osmo-pocket-4-isnt-available-in-the-us-and-it-might-never-be/
- SRT Mini Server, Pocket 4 RTMP HEVC (2026-09-25): https://srtminiserver.com/blog/dji-osmo-pocket-4-rtmp-hevc/
- Upstream DJI integration (2026-10-06): https://upstream.so/integrations/dji/
- IRLServer Pocket guide: https://irlserver.com/guides/connect-dji-osmo-pocket
- StreamableRun (2026-10-22): https://streamable.run/blog/dji-mimo-osmo-action-6-pocket-4-rtmp-streamablerun-setup
- DroneXL, Action 6 cloud backup (2026-01-12): https://dronexl.co/2026/01/12/dji-osmo-action-6-cloud-backup/
- Basic Tutorials, Pocket 4 NAS upload (2026-08-20): https://basic-tutorials.com/news/dji-osmo-pocket-4-and-4p-automatic-upload-to-the-cloud-and-nas-is-here/
- Osmosis MEDIA_PROTOCOL.md (MIT): https://github.com/KonradIT/osmosis/blob/master/MEDIA_PROTOCOL.md ; protocol map: https://github.com/KonradIT/osmosis/blob/master/docs/01-protocol-map.md
- Moblin (MIT), DJI integration: https://github.com/eerimoq/moblin/tree/main/Moblin/Integrations/Dji ; RTMP server: https://github.com/eerimoq/moblin/tree/main/Moblin/Media/RtmpServer
- djictl (CC0-1.0): https://github.com/xaionaro-go/djictl
- OpenPocketCine (Apache-2.0): https://github.com/erik-sutton95/OpenPocketCine

**Protocols and libraries**
- Adobe RTMP 1.0 (Veovera mirror): https://veovera.org/docs/legacy/rtmp-v1-0-spec.pdf
- RTMP errata and addenda: https://zenomt.github.io/rtmp-errata-addenda/rtmp-errata-addenda.html
- Enhanced RTMP v2 (`v2-2026-01-31-r2`): https://veovera.org/docs/enhanced/enhanced-rtmp-v2.html
- tus resumable upload 1.0: https://tus.io/protocols/resumable-upload
- FFmpeg Changelog (6.1 Enhanced RTMP HEVC, 8.0 Enhanced FLV v2): https://github.com/FFmpeg/FFmpeg/blob/master/Changelog
- HaishinKit releases (2.2.5, 2026-03-28): https://github.com/HaishinKit/HaishinKit.swift/releases
- BtbN FFmpeg builds: https://github.com/BtbN/FFmpeg-Builds
- QRCoder: https://www.nuget.org/packages/QRCoder

**Apple**
- TN3179, Understanding local network privacy (updated 2026-10-06): https://developer.apple.com/documentation/technotes/tn3179-understanding-local-network-privacy
- TN2258, AAC audio encoder delay: https://developer.apple.com/library/archive/technotes/tn2258/_index.html
- WWDC25 session 250, Network framework with structured concurrency: https://developer.apple.com/videos/play/wwdc2025/250/
- Block connections with the firewall (macOS 27): https://support.apple.com/guide/mac-help/block-connections-to-your-mac-with-a-firewall-mh34041/mac ; firewall settings: https://support.apple.com/guide/mac-help/change-firewall-settings-on-mac-mh11783/mac
- Set up SMB file sharing on Mac (macOS 27): https://support.apple.com/guide/mac-help/set-up-smb-file-sharing-on-mac-mchlp1657/mac ; Set up file sharing: https://support.apple.com/guide/mac-help/set-up-file-sharing-on-mac-mh17131/mac
- Safari upload compression: https://developer.apple.com/forums/thread/731042 ; picker options: https://developer.apple.com/forums/thread/743037
- AVFragmentedAsset (live clipping, section 9.7.1): https://developer.apple.com/documentation/avfoundation/avfragmentedasset ; AVFragmentedAssetMinder: https://developer.apple.com/documentation/avfoundation/avfragmentedassetminder
- UNUserNotificationCenter (section 9.9.5): https://developer.apple.com/documentation/usernotifications/unusernotificationcenter

**Microsoft, Velopack and web**
- Windows Firewall rules (updated 2026-10-08): https://learn.microsoft.com/en-us/windows/security/operating-system-security/network-security/windows-firewall/rules
- INetFwPolicy2: https://learn.microsoft.com/en-us/windows/win32/api/netfw/nn-netfw-inetfwpolicy2
- INetwork::GetCategory: https://learn.microsoft.com/en-us/windows/win32/api/netlistmgr/nf-netlistmgr-inetwork-getcategory
- Launch Windows Settings (ms.date 2026-09-26): https://learn.microsoft.com/en-us/windows/apps/develop/launch/launch-settings-app
- Windows network settings (Public by default): https://support.microsoft.com/en-us/windows/experience/connectivity-networking/essential-network-settings-and-tasks-in-windows
- File sharing over a network in Windows: https://support.microsoft.com/en-us/windows/experience/connectivity-networking/file-sharing-over-a-network-in-windows
- HttpListener (URL ACL requirement): https://learn.microsoft.com/en-us/dotnet/fundamentals/runtime-libraries/system-net-httplistener
- Velopack installers: https://docs.velopack.io/packaging/installer ; Windows overview: https://docs.velopack.io/packaging/operating-systems/windows ; hooks: https://docs.velopack.io/integrating/hooks
- MDN, Screen Wake Lock API (secure contexts only): https://developer.mozilla.org/en-US/docs/Web/API/Screen_Wake_Lock_API
- RegisterHotKey (system-wide hot keys; Windows-key combinations reserved for the system; F12 reserved for debuggers): https://learn.microsoft.com/en-us/windows/win32/api/winuser/nf-winuser-registerhotkey
- Windows App SDK app notifications quickstart (ms.date 2026-09-10; not supported for elevated apps): https://learn.microsoft.com/en-us/windows/apps/develop/notifications/app-notifications/app-notifications-quickstart
