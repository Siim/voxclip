# Estonian draft — user review required before release

Every Estonian string in `statements.json` (the entire `et` template and all twelve month names), every entry in `nonce-words-et.txt`, and every sentence in `scripts-et.txt` is **pending the user's native-language review**. The statement is the verbatim draft in voice-lab §6.2; it is not newly authored legal wording. Do not treat the files' presence or automated validation as approval.

Review pronunciation, commonness, ambiguity, unintended names, homophones, and suitability of every nonce entry. Review the script at a natural reading pace for the 90-second recording. The recorder accepts only 60–120 seconds of training audio. English nonce commonness and pronunciation should also receive a human pass; automated checks cover structure, not pronunciation.

File format: UTF-8, LF, one nonce word per line; plain-text read-aloud scripts with paragraphs; statement templates and fixed month tables in versioned JSON. These files are shared by both platforms, not app resources. Nonce selection uses four distinct entries without replacement and the system random-number generator. No recording or personal information belongs here.

## Disclosure and UI copy review

The four disclosure sentences in `shared/fixtures/share/cases.json` (`lines`, every `et` value, including combinations) and the matching derivation in `VoiceLabRenderContract.swift` are also pending review:

- Mõned sõnad selles videos on loetud minu enda hääle tehisintellekti-koopiaga.
- Selle video hääl on tehisintellektiga muudetud minu enda hääle koopiaks.
- Selle video häält on muudetud tehisintellektiga.
- Osa huulte liikumisest on loodud tehisintellektiga.

Review all five copy surfaces together: consent statement, read-aloud script, nonce list, fixed date month names, and disclosure sentences. The script's stop-recording sentence now comes last; no Estonian sentence or nonce entry has been rewritten.

Open wording decisions for the user's Estonian review: `tehisintellekti koopia` versus `tehisintellekti-koopiaga`; possible `särg`/`särk` homophones; and compound nonce words that Scribe may split into separate words. Automated word counts are not language approval.
