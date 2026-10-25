import Foundation
import VoxClipCore

enum RecordedSpeech {
    static let scribe = Data(#"""
    {"language_code":"est","language_probability":0.98,"text":"Tere, ee täna (laughs)","words":[
      {"text":" Tere, ","type":"word","start":0.12,"end":0.48,"logprob":-0.02,"speaker_id":"speaker_0"},
      {"text":" ","type":"spacing","start":0.48,"end":0.6,"logprob":0},
      {"text":"ee","type":"word","start":0.6,"end":0.9,"logprob":-1,"speaker_id":"speaker_0"},
      {"text":"täna","type":"word","start":1.1,"end":1.5,"logprob":-0.1,"speaker_id":"speaker_1"},
      {"text":"(laughs)","type":"audio_event","start":2,"end":2.5,"logprob":0,"speaker_id":"speaker_1"},
      {"text":"untimed","type":"word","start":null,"end":null,"logprob":null},
      {"text":"ignored","type":"future_type","start":3,"end":4,"logprob":0}
    ],"transcription_id":"synthetic-recording-1","audio_duration_secs":4,"future_field":true}
    """#.utf8)
    static let whisper: [RawToken] = [
        RawToken(text: "T", start: 0, end: 0.04, conf: 0.9),
        RawToken(text: "ere", joinsPrevious: true, start: 0.04, end: 0.1, conf: 0.7),
        RawToken(text: ",", joinsPrevious: true, start: 0.1, end: 0.1, conf: 0.8),
        RawToken(text: "maailm", start: 0.5, end: 0.51, conf: 1),
        RawToken(text: "[BLANK_AUDIO]", start: 1, end: 1.2, group: 1),
        RawToken(text: "(soft", start: 2, end: 2.2, group: 2),
        RawToken(text: "music)", start: 2.2, end: 2.8, group: 2),
        RawToken(text: "[laughs]", start: 3, end: 3.5, group: 3)
    ]
}
