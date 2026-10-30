namespace VoxClip.App.ViewModels;

internal static class VoiceLabCopy
{
    internal const string StopLooking = "I've checked my ElevenLabs account — stop looking";
    internal const string StopLookingExplanation = "Stops recovery without deleting any voice from ElevenLabs. Records that the remote state is unknown; the voice may stay in your ElevenLabs account. This action is free.";
    internal const string StoppedLooking = "Stopped looking. The remote state is unknown; the voice may stay in your ElevenLabs account.";
    internal const string SpeakerUnavailable = "The speaker check is not ready on Windows yet. Creating a voice is unavailable.";
    internal const string ProviderConsent = "Voice Lab sends audio of your voice and the words to speak to ElevenLabs with your key. Under ElevenLabs' terms, ElevenLabs may use uploaded content, including your voice, to improve its services unless you opt out in your ElevenLabs account. Generated audio can be traced to your account.";
    internal const string AccountCheck = "Reads your subscription, plan, available voice slots and pending voice verification status. No audio, video or transcript is sent. This check is free.";
    internal const string DeleteExplanation = "Deletes this voice from ElevenLabs, removes the local statement recording, and marks the local consent record deleted. Existing rendered takes stay playable and labelled. This action is free.";
    internal const string RemoveLocalExplanation = "Removes the local consent statement and records that the remote state is unknown. The voice may stay in your ElevenLabs account. This action is free.";
    internal const string Deleted = "Voice deleted. Existing rendered takes remain playable and labelled.";
    internal const string RemovedLocal = "Voice removed from VoxClip only. The remote state is unknown; it may stay in your ElevenLabs account.";
    internal const string VerificationRequired = "ElevenLabs needs to verify this voice before it can be used. Finish verification on elevenlabs.io, then come back.";
    internal const string NonCommercial = "Free ElevenLabs plans allow non-commercial use only.";
    internal const string RecoveryFailed = "Couldn't finish a voice operation. Retry below. No create request was repeated.";
    internal const string ReadFailed = "The local voice records could not be read. No audio was sent.";
    internal const string MicrophonePermission = "Microphone access is off. Turn on Microphone access and Let desktop apps access your microphone in Settings → Privacy & security → Microphone to record your consent.";
    internal const string MicrophoneNoDevice = "No microphone found. Connect one and try again.";
    internal const string MicrophoneSilent = "The microphone sent only silence. Check that it isn't muted, and that Settings → Privacy & security → Microphone lets desktop apps use it.";
    internal const string MicrophoneUnavailable = "The microphone isn't available. Check your input device and try again.";
    internal const string MicrophoneDeviceLost = "The microphone stopped sending audio. This take was discarded. Check your input device and record again.";
    internal const string MicrophoneWaiting = "Waiting for the microphone…";
    internal const string MicrophoneSettingsUri = "ms-settings:privacy-microphone";
    internal const string TrainingAudio = "Training audio";
    internal const string ProjectChoice = "Use this project's audio (recommended)";
    internal const string ReadAloudChoice = "Record a read-aloud (about 90 s)";
    internal const string ProjectUnreadable = "VoxClip can't read this project's audio. Record a read-aloud instead.";
    internal const string NoProject = "Open a project to use its audio instead.";
    internal const string NoTranscript = "Transcribe this project to use its audio instead.";
    internal const string ProjectMismatch = "Some of this project's audio doesn't sound like the voice in your consent statement. Record a read-aloud instead.";
    internal const string RecordReadAloud = "Record a Read-Aloud";
    internal static string ProjectFinding(string project) => "Finding clear speech in " + project + "…";
    internal static string ProjectFound(long seconds, string project) => Seconds(seconds) + " s of clear speech found in " + project;
    internal static string ProjectTooLittle(long seconds) => seconds == 0 ? "This project has no clear speech to use. Record a read-aloud instead."
        : "This project has only " + Seconds(seconds) + " s of clear speech. Record a read-aloud instead.";
    internal static string Seconds(long seconds) => seconds.ToString(System.Globalization.CultureInfo.InvariantCulture);
    internal const string MicrophoneOpenSettings = "Open Settings";
    internal static string MicrophoneDeviceLine(string name) => "Microphone: " + name;
    internal static string MicrophoneFailure(VoxClip.Media.Audio.MicrophoneError error) => error switch
    {
        VoxClip.Media.Audio.MicrophoneError.Permission => MicrophonePermission,
        VoxClip.Media.Audio.MicrophoneError.NoDevice => MicrophoneNoDevice,
        VoxClip.Media.Audio.MicrophoneError.Silent => MicrophoneSilent,
        VoxClip.Media.Audio.MicrophoneError.DeviceLost => MicrophoneDeviceLost,
        _ => MicrophoneUnavailable
    };
    internal const string BetaNotice = "Voice Lab can clone your own voice, change your voice and re-voice a few words. Everything it makes is labelled 'AI MODIFIED' in exports, as EU law requires. It uses your ElevenLabs key and, for lip sync, your fal.ai or sync.so key.";
    internal const string ToggleCaption = "Voice Lab is optional. Import, cut, captions, clips and export work without it.";
    internal const string KeyFootnote = "The key is encrypted for your Windows account. No request is made when you save it.";
    internal const string KeyGuidance = "Create a key just for VoxClip on elevenlabs.io → Developers → API keys. Allow only the permissions listed for the features you use, and set a monthly credit limit. Never enable voice-library publishing, sharing or workspace permissions for this key.";
    internal const string KeyPermissions = "My voice: create_instant_voice_clone, voices_read, voices_write, speech_to_text. Account check: user_read. Never allow create_professional_voice_clone, share_voice_externally, publish_voice_to_voice_library, workspace_*, dubbing_*, convai_*, service_account_write or create_user_api_key.";
    internal const string LabelHelper = "AI MODIFIED is required for synthetic exports. You can change its position, not turn it off.";
    internal const string C2paHelper = "Applies to Clean-audio-only exports when the C2PA component is available. Exports that need disclosure always carry a machine-readable mark.";
    internal const string Storage = "Consent statements stay on this PC until you delete the voice. Training audio is discarded after upload. Local consent records keep an audit trail; they never go into project files.";
    internal const string CapError = "Enter an amount in dollars with up to two decimals, such as 20 or 12.50.";
    internal const string SharedKeyFootnote = "The key is encrypted for your Windows account and is shared with Voice Lab when you turn it on.";
    internal const string EmptyStorage = "Nothing is stored yet.";
}
