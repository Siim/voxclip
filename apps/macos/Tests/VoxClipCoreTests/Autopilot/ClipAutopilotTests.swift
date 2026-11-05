import Foundation
import Testing
@testable import VoxClipCore

/// The "Make it postable" planner (ai.md §16): the prompt file, the indexed transcript, the validator's repairs, the
/// operation mapping and pricing. Shared vectors: shared/fixtures/autopilot/plan-validation-cases.json. No send leaves
/// the process: every connector here is a stub.
@Suite struct ClipAutopilotTests {
    static func shared() throws -> SharedResources { SharedResources(root: try FixtureLoader.sharedRoot()) }

    static func fixture() throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: FixtureLoader.data("fixtures/autopilot/plan-validation-cases.json"))
    }

    static func transcript() throws -> Transcript {
        let words = try fixture()[ai: "transcript"][ai: "words"].aiArray.map { item in
            TimedWord(id: try #require(item[ai: "id"].aiString), text: try #require(item[ai: "text"].aiString),
                      kind: item[ai: "kind"].aiString == "event" ? .event : .word,
                      start: try #require(item[ai: "start"].aiDouble), end: try #require(item[ai: "end"].aiDouble))
        }
        return Transcript(words: words, language: "en", durationSeconds: 12, engine: EngineRef(id: .whispercpp, engineVersion: "fixture"),
                          verbatim: false, refined: false, rawKey: String(repeating: "0", count: 64), createdAt: Date(timeIntervalSince1970: 0))
    }

    static func edits(_ value: JSONValue) -> ProjectEdits {
        ProjectEdits(pauseThresholdSeconds: 1, cutWordIds: value[ai: "cutWordIds"].aiArray.compactMap(\.aiString),
                     cutPauseIds: value[ai: "cutPauseIds"].aiArray.compactMap(\.aiString),
                     corrections: (value[ai: "corrections"].aiObject ?? [:]).compactMapValues(\.aiString))
    }

    static func context(scope: ClosedRange<Int>, edits: ProjectEdits = ProjectEdits(pauseThresholdSeconds: 1),
                        preference: ClipAutopilotCaptionPreference? = nil) throws -> ClipAutopilotContext {
        let shared = try shared()
        let transcript = try transcript()
        let state = try EditState(transcript: transcript, edits: edits)
        return ClipAutopilotContext(words: transcript.words, corrections: edits.corrections, cutWordIDs: Set(edits.cutWordIds),
            pauses: state.pauses, cutPauseIDs: Set(edits.cutPauseIds), scope: scope,
            styleIDs: Set(try CaptionStyleLibrary(shared: shared).styles.map(\.id)), fonts: try ClipAutopilotFonts.load(shared: shared),
            preference: preference, prompt: try ClipAutopilotPrompt(shared: shared))
    }

    static func range(_ value: JSONValue) throws -> ClosedRange<Int> {
        let ends = value.aiArray.compactMap(\.aiInt)
        try #require(ends.count == 2)
        return ends[0]...ends[1]
    }

    static func repairs(_ repairs: [ClipAutopilotPlan.Repair]) -> [[String]] {
        repairs.map { [$0.field, $0.action.rawValue] }.sorted { $0.lexicographicallyPrecedes($1) }
    }

    static func expected(_ value: JSONValue) -> [[String]] {
        value.aiArray.map { $0.aiArray.compactMap(\.aiString) }.sorted { $0.lexicographicallyPrecedes($1) }
    }

    static func reply(_ id: String) throws -> JSONValue {
        try #require(try fixture()[ai: "cases"].aiArray.first { $0[ai: "id"].aiString == id })[ai: "reply"]
    }

    // MARK: Prompt file

    @Test func promptFileFillsItsLimitsAndKeepsBothSchemasInStep() throws {
        let prompt = try ClipAutopilotPrompt(shared: Self.shared())
        #expect(prompt.promptVersion == 3)
        #expect(!prompt.system.contains("{") && !prompt.system.contains("}"))
        #expect(prompt.system.contains("Never more than \(prompt.limits.maxRewrites) in a clip"))
        #expect(prompt.system.contains("never over \(Int(prompt.limits.maxClipSeconds)) s"))
        #expect(prompt.system.contains("from 1.05 to 1.35"))
        #expect(CanonicalResponseParser.validateSchemaSubset(prompt.schema))
        #expect(prompt.seriesSchema[ai: "properties"][ai: "clips"][ai: "items"] == prompt.schema)
        #expect(prompt.schema[ai: "required"].aiArray.count == prompt.schema[ai: "properties"].aiObject?.count)
        #expect(prompt.defaults.font == .init(family: "Roboto", weight: 900))
        #expect(prompt.limits.maxZoomScale <= MotionCue.maximumScale)
        #expect(prompt.minimumTimeout == .seconds(1200))
        let sources = try Self.fixture()[ai: "sources"][ai: ClipAutopilotPrompt.path.replacingOccurrences(of: "prompts/", with: "shared/prompts/")]
        #expect(sources.aiString == prompt.sha256, "Update plan-validation-cases.json sources when the prompt changes")
    }

    @Test func promptFileDefectsRefuseToLoad() throws {
        let data = try FixtureLoader.data("prompts/clip-autopilot.json")
        let document = try JSONDecoder().decode(JSONValue.self, from: data)
        guard case .object(var root) = document else { Issue.record("not an object"); return }
        var broken = root
        broken["seriesSchema"] = .object(["type": .string("object"), "additionalProperties": .bool(false), "required": .array([]),
                                          "properties": .object([:])])
        #expect(throws: VoxClipError.sharedResourcesMissing) { try ClipAutopilotPrompt(document: .object(broken), sha256: "") }
        root["system"] = .string("Use {unknownLimit} rewrites.")
        #expect(throws: VoxClipError.sharedResourcesMissing) { try ClipAutopilotPrompt(document: .object(root), sha256: "") }
    }

    // MARK: Request

    @Test(arguments: ["whole", "edited"])
    func renderedTranscriptMatchesTheSharedVector(_ id: String) throws {
        let vector = try #require(try Self.fixture()[ai: "rendering"].aiArray.first { $0[ai: "id"].aiString == id })
        let shared = try Self.shared()
        let edits = Self.edits(vector[ai: "edits"])
        let transcript = try Self.transcript()
        let rendered = try ClipAutopilotRequestBuilder.render(ClipAutopilotRequest(transcript: transcript, edits: edits, mode: .clip(try Self.range(vector[ai: "scope"]))),
            prompt: ClipAutopilotPrompt(shared: shared), styles: CaptionStyleLibrary(shared: shared).styles, fonts: ClipAutopilotFonts.load(shared: shared),
            pauses: EditState(transcript: transcript, edits: edits).pauses)
        let expected = try #require(vector[ai: "transcript"].aiString)
        #expect(rendered.cachedBlock.hasSuffix(expected))
    }

    @Test func requestSendsExtraHighEffortWithTheStylesFontsAndPreference() async throws {
        let shared = try Self.shared()
        let service = ClipAutopilotService(runner: try Self.runner(), shared: shared)
        let input = ClipAutopilotRequest(transcript: try Self.transcript(), edits: ProjectEdits(pauseThresholdSeconds: 1), mode: .clip(2...26),
            captionPreference: .init(styleId: "karaoke", textCase: .asSaid), note: "Keep the laugh.")
        let request = try await service.request(input, connector: .claudeCode)
        #expect(request.effort == .xhigh)
        #expect(request.feature == .clipAutopilot)
        #expect(request.schemaName == "clip_autopilot_plan")
        #expect(request.tag == "clip-autopilot")
        #expect(request.timeout >= .seconds(1200))
        #expect(request.maxOutputTokens == 16_000)
        let block = try #require(request.cachedBlock)
        // 23 spoken words over 8.3 s, less 0.7 s of filler and laughter and the 1.05 s a tightened pause loses: 6.55 s.
        let head = "Language: en\nRecording: 8.3 s\nPace: about 211 words a minute once fillers and pauses are cut, so 45 s holds about 158 words.\n"
            + "Caption preference: karaoke, font Roboto weight 900, case asSaid\n\nCaption styles:\n- vox-bold: Bold."
        #expect(String(block.prefix(head.count)) == head)
        #expect(block.contains("Fonts:\n- Roboto, weight 900 (default)\n- Anton, weight 400\n"))
        #expect(!block.contains("[1]um") && block.contains("0:00 [2]the [3]big"))
        #expect(request.instruction.hasPrefix("Plan the clip from word 2 to word 26 (8.3 s) as one finished, postable short."))
        #expect(request.instruction.hasSuffix("\n\nThe creator adds: Keep the laugh."))
        let series = try await service.request(ClipAutopilotRequest(transcript: try Self.transcript(), mode: .series(nil)), connector: .claudeCode)
        #expect(series.schemaName == "clip_autopilot_series")
        #expect(series.maxOutputTokens == 64_000)
        #expect(series.instruction.hasPrefix("Find every clip in this video worth posting, at most 12, ranked best first"))
        #expect(series.cachedBlock?.contains("Recording: 12.0 s\nPace: about ") == true)
        #expect(series.cachedBlock?.contains("\nCaption preference: none; choose what suits the clip\n") == true)
    }

    @Test func requestRefusesAnEmptyScopeABadLanguageAndALongNote() async throws {
        let service = ClipAutopilotService(runner: try Self.runner(), shared: try Self.shared())
        let transcript = try Self.transcript()
        for input in [ClipAutopilotRequest(transcript: transcript, mode: .clip(16...16)),
                      ClipAutopilotRequest(transcript: transcript, mode: .clip(20...40)),
                      ClipAutopilotRequest(transcript: transcript, edits: ProjectEdits(cutWordIds: (17...29).map { "w\($0)" }), mode: .clip(16...29)),
                      ClipAutopilotRequest(transcript: transcript, mode: .clip(0...29), language: "english!"),
                      ClipAutopilotRequest(transcript: transcript, mode: .clip(0...29), note: String(repeating: "a", count: 2_001))] {
            await #expect(throws: VoiceLabError.invalidInput) { try await service.request(input, connector: .claudeCode) }
        }
    }

    // MARK: Validation

    @Test(arguments: ["valid-clip", "out-of-range", "overlaps", "unknown-style", "off-style-bundled-font", "bridge-words", "rewrite-limit",
                      "malformed", "cut-everything", "span-tightened-no-music"])
    func validatorRepairsOrDropsEachItem(_ id: String) throws {
        let vector = try #require(try Self.fixture()[ai: "cases"].aiArray.first { $0[ai: "id"].aiString == id })
        let wanted = vector[ai: "preference"]
        let preference = wanted == .null ? nil : ClipAutopilotCaptionPreference(styleId: wanted[ai: "styleId"].aiString)
        let context = try Self.context(scope: try Self.range(vector[ai: "scope"]), preference: preference)
        let plan = try #require(ClipAutopilotValidator.plan(vector[ai: "reply"], context: context))
        let expect = vector[ai: "expect"]
        #expect(plan.startWord...plan.endWord == (try Self.range(expect[ai: "span"])))
        func cells(_ key: String) -> [[String]] {
            expect[ai: key].aiArray.map { item in item.aiArray.map { cell in cell.aiString ?? toFixed1(cell.aiDouble ?? -1) } }
        }
        let cuts: [[String]] = plan.cuts.map { [toFixed1(Double($0.startWord)), toFixed1(Double($0.endWord)), $0.kind.rawValue] }
        #expect(cuts == cells("cuts"))
        #expect(plan.pauseCuts.map(\.afterWord) == expect[ai: "pauseCuts"].aiArray.compactMap(\.aiInt))
        let rewrites: [[String]] = plan.rewrites.map { [toFixed1(Double($0.startWord)), toFixed1(Double($0.endWord)), $0.text] }
        #expect(rewrites == cells("rewrites"))
        let captions = expect[ai: "captions"]
        let font = ClipAutopilotPlan.Font(family: captions[ai: "family"].aiString ?? "", weight: captions[ai: "weight"].aiInt ?? 0)
        let textCase = ClipAutopilotPlan.CaptionCase(rawValue: captions[ai: "case"].aiString ?? "") ?? .upper
        let wantedCaptions = ClipAutopilotPlan.Captions(styleId: captions[ai: "styleId"].aiString ?? "", font: font, textCase: textCase,
                                                        wordsPerCaption: captions[ai: "wordsPerCaption"].aiInt ?? 0)
        #expect(plan.captions == wantedCaptions)
        let music: [[String]] = plan.music.map { [$0.title, $0.prompt, toFixed1($0.underVoiceDb)] }
        #expect(music == cells("music"))
        #expect(plan.musicPick == expect[ai: "musicPick"].aiInt)
        let zooms: [[String]] = plan.zooms.map { [toFixed1(Double($0.word)), toFixed1(Double($0.untilWord)), String($0.scale)] }
        let wantedZooms: [[String]] = expect[ai: "zooms"].aiArray.map { item in
            let cells = item.aiArray.compactMap(\.aiDouble)
            return [toFixed1(cells[0]), toFixed1(cells[1]), String(cells[2])]
        }
        #expect(zooms == wantedZooms)
        #expect(plan.title == expect[ai: "title"].aiString)
        #expect(plan.hook == expect[ai: "hook"].aiString)
        #expect(plan.score == expect[ai: "score"].aiInt)
        #expect(plan.verdict.rawValue == expect[ai: "verdict"].aiString)
        #expect(plan.questions.count == expect[ai: "questions"].aiInt)
        #expect(Self.repairs(plan.repairs) == Self.expected(expect[ai: "repairs"]))
    }

    @Test func seriesLeavesOutOverlappingShortAndUnreadableClips() throws {
        let vector = try #require(try Self.fixture()[ai: "cases"].aiArray.first { $0[ai: "id"].aiString == "series" })
        let series = ClipAutopilotValidator.series(vector[ai: "reply"], context: try Self.context(scope: 0...29))
        #expect(series.plans.map { [$0.startWord, $0.endWord] } == vector[ai: "expect"][ai: "plans"].aiArray.map { $0.aiArray.compactMap(\.aiInt) })
        #expect(Self.repairs(series.repairs) == Self.expected(vector[ai: "expect"][ai: "repairs"]))
    }

    @Test func seriesKeepsAtMostTheLimitAndAPlanRoundTripsAsJSON() throws {
        let context = try Self.context(scope: 0...29)
        let clip = try Self.reply("valid-clip")
        guard case .object(var first) = clip else { Issue.record("not an object"); return }
        first["startWord"] = .number(0); first["endWord"] = .number(26)
        let many = JSONValue.object(["clips": .array(Array(repeating: .object(first), count: 1) + (0..<14).map { _ in
            var later = first; later["startWord"] = .number(27); later["endWord"] = .number(29); return .object(later)
        })])
        let series = ClipAutopilotValidator.series(many, context: context)
        #expect(series.plans.count == 1)
        #expect(series.repairs.count == 14)
        let plan = try #require(ClipAutopilotValidator.plan(clip, context: context))
        let data = try JSONEncoder().encode(plan)
        #expect(try JSONDecoder().decode(ClipAutopilotPlan.self, from: data) == plan)
        let text = String(decoding: data, as: UTF8.self).replacingOccurrences(of: "\"version\":1", with: "\"version\":2")
        #expect(throws: DecodingError.self) { try JSONDecoder().decode(ClipAutopilotPlan.self, from: Data(text.utf8)) }
        #expect(String(decoding: data, as: UTF8.self).contains("\"case\":\"upper\""))
    }

    @Test func alreadyCutWordsAreNeverListedOrRewritten() throws {
        let edits = ProjectEdits(pauseThresholdSeconds: 1, cutWordIds: ["w19"], cutPauseIds: ["pause-after-w6"])
        let context = try Self.context(scope: 0...29, edits: edits)
        let reply = JSONValue.object(["rewrites": .array([.object(["startWord": .number(17), "endWord": .number(23),
            "text": .string("You still need to feed the plants"), "reason": .string("")])]),
            "pauseCuts": .array([.object(["afterWord": .number(6), "reason": .string("")])]),
            "zooms": .array([.object(["word": .number(19), "untilWord": .number(20), "scale": .number(1.2), "reason": .string("")])])])
        let plan = try #require(ClipAutopilotValidator.plan(reply, context: context))
        #expect(plan.rewrites.isEmpty && plan.pauseCuts.isEmpty && plan.zooms.isEmpty)
        #expect(Set(plan.repairs.filter { $0.action == .dropped }.map(\.field)) == ["rewrites[0]", "pauseCuts[0]", "zooms[0]"])
    }

    // MARK: Service

    @Test func servicePlansThroughTheRunnerAndChecksTheReply() async throws {
        let reply = try Self.reply("overlaps")
        let stub = AutopilotStub(replies: ["not json", try reply.aiCompact()])
        let service = ClipAutopilotService(runner: try Self.runner(), shared: try Self.shared())
        let result = try await service.plan(ClipAutopilotRequest(transcript: try Self.transcript(), edits: ProjectEdits(pauseThresholdSeconds: 1),
                                                                 mode: .clip(0...29)), connector: stub, model: "fixture")
        let plan = try #require(result.plan)
        #expect(plan.rewrites.count == 1 && plan.cuts.count == 2)
        #expect(result.promptVersion == 3 && result.promptSHA256.count == 64)
        let sent = await stub.requests
        #expect(sent.count == 2)
        #expect(sent.allSatisfy { $0.effort == .xhigh && $0.feature == .clipAutopilot })
        #expect(sent[1].instruction.contains("Your previous reply was not valid JSON"))
    }

    @Test func serviceSeriesDropsTypeInvalidClipsAndTheRestStands() async throws {
        let valid = try Self.reply("valid-clip")
        let reply = JSONValue.object(["clips": .array([.object(["startWord": .string("x")]), valid])])
        let stub = AutopilotStub(replies: [try reply.aiCompact()])
        let service = ClipAutopilotService(runner: try Self.runner(), shared: try Self.shared())
        let result = try await service.plan(ClipAutopilotRequest(transcript: try Self.transcript(), edits: ProjectEdits(pauseThresholdSeconds: 1),
                                                                 mode: .series(nil)), connector: stub, model: "fixture")
        #expect(result.droppedItems == 1)
        #expect(result.series.plans.map(\.startWord) == [0])
        #expect(await stub.requests.first?.schemaName == "clip_autopilot_series")
    }

    @Test func serviceFailsOnlyWhenTheReplyIsNeverJSON() async throws {
        let stub = AutopilotStub(replies: ["no", "still no"])
        let service = ClipAutopilotService(runner: try Self.runner(), shared: try Self.shared())
        await #expect(throws: LLMError.self) {
            try await service.plan(ClipAutopilotRequest(transcript: try Self.transcript(), mode: .clip(0...29)), connector: stub, model: "fixture")
        }
    }

    // MARK: Mapping

    static func project(clips: [ClipRange] = [ClipRange(id: "c1", startWordId: "w0", endWordId: "w29", title: "Old")], cut: [String] = []) throws -> Project {
        Project(id: "00000000-0000-4000-8000-000000000000", createdAt: Date(timeIntervalSince1970: 0), modifiedAt: Date(timeIntervalSince1970: 0),
                savedBy: ProjectWriter(version: "1.0.0"),
                media: ProjectMedia(source: MediaReference(absolutePath: "/tmp/fixture.mp4", sizeBytes: 1, durationSeconds: 12,
                                                           contentKey: String(repeating: "0", count: 64))),
                transcript: try transcript(), edits: ProjectEdits(pauseThresholdSeconds: 1, cutWordIds: cut, clips: clips))
    }

    @Test func planMapsToTheEditorsCommandsAndAppliesWhatItCan() throws {
        let shared = try Self.shared()
        let fonts = try ClipAutopilotFonts.load(shared: shared)
        var plan = try #require(ClipAutopilotValidator.plan(try Self.reply("valid-clip"), context: try Self.context(scope: 0...29)))
        plan.startWord = 2
        let project = try Self.project(cut: ["w9"])
        let operations = try ClipAutopilotMapping.operations(for: plan, clipID: "c1", project: project, fonts: fonts)
        #expect(operations.map(\.id) == ["clip", "title", "cut-0", "cut-2", "pause-0", "rewrite-0", "captions", "zoom-0", "music", "hook", "post"])
        #expect(operations[0].action == .edit(.updateClip(id: "c1", startIndex: 2, endIndex: 29)))
        #expect(operations[1].action == .edit(.renameClip(id: "c1", title: "Coffee is great")))
        #expect(operations[2].action == .edit(.cutSelection(ids: ["w1"])))
        #expect(operations[4].action == .edit(.cutSelection(ids: ["pause-after-w6"])))
        #expect(operations[5].action == .rewrite(scope: .selection(17...23), text: "You still need to feed the plants"))
        guard case .captions(let settings, let pending) = operations[6].action else { Issue.record("no captions"); return }
        #expect(settings.styleId == "vox-bold")
        // Roboto Black ships in shared/fonts/roboto (captions set 2), so the plan's font is applied, not left pending.
        let robotoFile = try #require(fonts[.init(family: "Roboto", weight: 900)])
        #expect(settings.overrides == ["text": .object(["transform": .string("uppercase")]), "layout": .object(["maxWords": .number(3)]),
                                       "font": .object(["file": .string(robotoFile), "family": .string("Roboto"), "weight": .number(900)])])
        #expect(pending == nil)
        guard case .motion(let cue) = operations[7].action else { Issue.record("no zoom"); return }
        #expect(cue.clipID == "c1" && cue.sourceStart == 4.9 && cue.sourceEnd == 5.9)
        #expect(cue.transform(atSourceTime: 5.0).scale == 1.2)
        guard case .music(let music) = operations[8].action else { Issue.record("no music"); return }
        #expect(music.picked.title == "Pulse" && music.alternatives.map(\.title) == ["Glass", "Grit"])
        let (applied, left) = try ClipAutopilotMapping.apply(operations, to: project)
        #expect(Set(applied.edits.cutWordIds) == ["w1", "w9", "w11"])
        #expect(applied.edits.cutPauseIds == ["pause-after-w6"])
        #expect(applied.edits.clips.first?.startWordId == "w2" && applied.edits.clips.first?.title == "Coffee is great")
        #expect(applied.captions.styleId == "vox-bold")
        #expect(applied.motionCues.map(\.id) == ["c1-zoom-0"])
        #expect(applied.share.captions["c1"] == "Coffee is great. Sleep is better.")
        #expect(left.map(\.decision) == [.rewrite, .music, .hook])
        try ProjectValidation.validateModel(applied)
    }

    @Test func aBundledFontBecomesAnOverrideAndASeriesClipIsAdded() throws {
        let shared = try Self.shared()
        let context = try Self.context(scope: 0...29)
        let plan = try #require(ClipAutopilotValidator.plan(try Self.reply("off-style-bundled-font"), context: context))
        let project = try Self.project(clips: [])
        let operations = try ClipAutopilotMapping.operations(for: plan, clipID: "autopilot-1", project: project, fonts: try ClipAutopilotFonts.load(shared: shared))
        guard case .edit(.addClip(let clip)) = operations[0].action else { Issue.record("no clip"); return }
        #expect(clip.id == "autopilot-1" && clip.origin == .ai && clip.title == "Coffee is great")
        guard case .captions(let settings, let pending) = try #require(operations.first { $0.decision == .captions }).action else { return }
        #expect(pending == nil)
        #expect(settings.overrides["font"] == .object(["file": .string("Montserrat-Black.ttf"), "family": .string("Montserrat"), "weight": .number(900)]))
        #expect(settings.overrides["layout"] == .object(["maxWords": .number(1), "maxLines": .number(1)]))
        #expect(settings.overrides["text"] == .object(["transform": .string("none")]))
        let applied = try ClipAutopilotMapping.apply(operations, to: project).project
        #expect(applied.edits.clips.map(\.id) == ["autopilot-1"])
        try ProjectValidation.validateModel(applied)
        #expect(throws: VoiceLabError.invalidInput) { try ClipAutopilotMapping.operations(for: plan, clipID: "-bad id", project: project, fonts: [:]) }
    }

    @Test func editedLengthTakesOffCutsAndTightenedPauses() throws {
        let plan = try #require(ClipAutopilotValidator.plan(try Self.reply("valid-clip"), context: try Self.context(scope: 0...29)))
        let state = try EditState(transcript: try Self.transcript(), edits: ProjectEdits(pauseThresholdSeconds: 1))
        // 11.3 s, less 0.2 + 0.1 + 0.2 s of cut words, less the 1.2 s pause beyond the 0.15 s kept.
        #expect(abs(ClipAutopilotMapping.editedSeconds(plan, state: state) - 9.75) < 1e-9)
    }

    // MARK: Pricing

    @Test func priceAddsTheVoiceAndTheMusicAndNothingForAPlanSend() throws {
        let plan = try #require(ClipAutopilotValidator.plan(try Self.reply("valid-clip"), context: try Self.context(scope: 0...29)))
        let voice = try VoiceLabPriceCatalog(data: FixtureLoader.data("catalog/voice-lab.json"))
        let music = try VoiceLabPriceCatalog(data: FixtureLoader.data(ClipAutopilotPricing.musicCatalogPath))
        #expect(music.entries.count == 1)
        let price = try ClipAutopilotPricing.price(plan, voiceModel: "eleven_v3", candidates: 1, voiceCatalog: voice, musicCatalog: music,
                                                   musicSeconds: 9.75, connector: .claudeCode, signIn: .plan)
        // 33 characters at $0.08 per 1,000, and 10 s of music at $0.15 a minute.
        #expect(price.voice?.units == 33)
        #expect(price.voice?.usd == Decimal(string: "0.00264"))
        #expect(price.music?.units == 10)
        #expect(price.music?.usd == Decimal(string: "0.025"))
        #expect(price.usd == Decimal(string: "0.02764"))
        #expect(price.llm == .none)
        #expect(try ClipAutopilotPricing.price(plan, voiceModel: "eleven_v3", candidates: 1, voiceCatalog: voice, musicCatalog: music,
                                               musicSeconds: 9.75, connector: .claudeCode, signIn: nil).llm == .unknown)
        #expect(try ClipAutopilotPricing.price(plan, voiceModel: "eleven_v3", candidates: 1, voiceCatalog: voice, musicCatalog: music,
                                               musicSeconds: 9.75, connector: .anthropic, signIn: nil).llm == .unknown)
        #expect(try ClipAutopilotPricing.price(plan, voiceModel: "eleven_v3", candidates: 1, voiceCatalog: voice, musicCatalog: music,
                                               musicSeconds: 9.75, connector: .ollama, signIn: nil).llm == .none)
        let unknown = try ClipAutopilotPricing.price(plan, voiceModel: "eleven_v3", candidates: 1, voiceCatalog: voice, musicCatalog: nil,
                                                     musicSeconds: 9.75, connector: .claudeCode, signIn: .plan)
        #expect(unknown.music?.usd == nil && unknown.usd == nil)
        var bare = plan; bare.rewrites = []; bare.musicPick = nil
        let free = try ClipAutopilotPricing.price(bare, voiceModel: "eleven_v3", candidates: 1, voiceCatalog: voice, musicCatalog: music,
                                                  musicSeconds: 9.75, connector: .claudeCode, signIn: .plan)
        #expect(free.voice == nil && free.music == nil && free.usd == 0)
    }

    // MARK: Effort

    @Test func extraHighEffortCapsToTheHighestSupportedLevel() {
        #expect(Effort.xhigh.capped(to: [.low, .medium, .high]) == .high)
        #expect(Effort.xhigh.capped(to: [.xhigh]) == .xhigh)
        #expect(Effort.medium.capped(to: [.low, .high]) == .low)
        #expect(Effort.low.capped(to: [.high]) == nil)
        #expect(Effort.allCases.map(\.rawValue) == ["low", "medium", "high", "xhigh", "max"])
    }

    static func runner() throws -> LLMRunner {
        let catalog = try LLMCatalog(shared: shared())
        return LLMRunner(keys: LLMEnvironmentKeyProvider(catalog: catalog), catalog: catalog, log: AutopilotLog())
    }
}

extension HTTPConnectorTests {
    @Test(arguments: [ConnectorID.anthropic, .openai, .gemini])
    func extraHighEffortMapsToEachProvidersLevel(_ id: ConnectorID) async throws {
        let harness = try HTTPHarness(id, replies: [HTTPFixtures.success(id)])
        defer { harness.finish() }
        var request = try HTTPFixtures.f1()
        request.effort = .xhigh
        _ = try await harness.connector.send(request, model: harness.model)
        let body = try #require(HTTPStubProtocol.requests.last).json()
        switch id {
        case .anthropic: #expect(body[ai: "output_config"][ai: "effort"].aiString == "xhigh")
        case .openai: #expect(body[ai: "reasoning"][ai: "effort"].aiString == "high")
        default: #expect(body[ai: "generationConfig"][ai: "thinkingConfig"][ai: "thinkingLevel"].aiString == "HIGH")
        }
    }
}

private actor AutopilotLog: Redacting {
    func write(_ entry: LogEntry) {}
    func register(secret: String) {}
    func redact(_ message: String) -> String { message }
}

private actor AutopilotStub: LLMConnector {
    nonisolated let id = ConnectorID.ollama
    private var replies: [String]
    private(set) var requests: [LLMRequest] = []
    init(replies: [String]) { self.replies = replies }
    func status() -> ConnectorStatus { .ready }
    func models(refresh: Bool) -> [LLMModel] { [.init(id: "fixture", name: "Fixture", contextTokens: 256_000, source: .curated)] }
    func contextTokens(model: String) -> Int? { 256_000 }
    func send(_ request: LLMRequest, model: String) -> RawCompletion {
        requests.append(request)
        let text = replies.isEmpty ? "" : replies.removeFirst()
        return RawCompletion(text: text, model: model, stop: .complete)
    }
}
