# Offline own-voice consent fixtures

`consent-scribe.json` is a stored, synthetic Scribe v2 response in the provider's JSON shape, not a live request, a real person's statement, or evidence of consent. Tests replay it through the existing Scribe response mapper. It includes all expected tokens, a language code and a fixture transcription id; tests remove nonce words, change the language and remove most words to exercise refusal. No recordings or personal data are included.

`consent-record.json` is a synthetic `voxclip-consent/1` record for schema and state tests. Its zero audio hashes are placeholders, not claims about an existing audio file. Store tests replace the statement hash with the hash of locally generated PCM16 WAV bytes. The two-dimensional embedding and threshold are **test-only**, never a calibrated production speaker model. No provider credentials are present. Paid create and delete tests use the existing URLProtocol fake transport.
