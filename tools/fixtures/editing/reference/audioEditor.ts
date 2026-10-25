import type { WordSegment } from '../hooks/useVoiceRecording'
import { buildMediaEditPlan, mapWordsToEditedTimeline } from './mediaTimeline'

/** Render the same sample-exact edit plan used to retime captions. */
export async function removeWordSegments(
  audioBuffer: AudioBuffer,
  words: WordSegment[]
): Promise<{ buffer: AudioBuffer; blob: Blob; updatedWords: WordSegment[] }> {
  const sampleRate = audioBuffer.sampleRate
  const plan = buildMediaEditPlan(words, audioBuffer.length / sampleRate, sampleRate)
  const audioContext = new AudioContext({ sampleRate })
  try {
    // AudioBuffer requires a positive length, even if the complete clip was cut.
    const newBuffer = audioContext.createBuffer(audioBuffer.numberOfChannels, Math.max(1, plan.outputSamples), sampleRate)
    for (let channel = 0; channel < audioBuffer.numberOfChannels; channel++) {
      const source = audioBuffer.getChannelData(channel)
      const target = newBuffer.getChannelData(channel)
      let offset = 0
      for (const part of plan.kept) {
        const length = part.endSample - part.startSample
        target.set(source.subarray(part.startSample, part.endSample), offset)
        // Fades alter amplitude only; they never overlap or shorten the timeline.
        const fadeLength = Math.min(Math.round(0.005 * sampleRate), Math.floor(length / 2))
        for (let i = 0; i < fadeLength; i++) {
          if (part.startSample > 0) target[offset + i] *= i / fadeLength
          if (part.endSample < audioBuffer.length) target[offset + length - 1 - i] *= i / fadeLength
        }
        offset += length
      }
    }
    return {
      buffer: newBuffer,
      blob: await audioBufferToBlob(newBuffer),
      updatedWords: mapWordsToEditedTimeline(words, plan)
    }
  } finally {
    await audioContext.close()
  }
}

/**
 * Convert AudioBuffer to WAV Blob
 */
async function audioBufferToBlob(audioBuffer: AudioBuffer): Promise<Blob> {
  const numberOfChannels = audioBuffer.numberOfChannels
  const sampleRate = audioBuffer.sampleRate
  const length = audioBuffer.length
  const bytesPerSample = 2 // 16-bit PCM
  const blockAlign = numberOfChannels * bytesPerSample

  // WAV file header
  const buffer = new ArrayBuffer(44 + length * blockAlign)
  const view = new DataView(buffer)

  // Write WAV header
  writeString(view, 0, 'RIFF')
  view.setUint32(4, 36 + length * blockAlign, true)
  writeString(view, 8, 'WAVE')
  writeString(view, 12, 'fmt ')
  view.setUint32(16, 16, true) // Subchunk1Size (16 for PCM)
  view.setUint16(20, 1, true) // AudioFormat (1 for PCM)
  view.setUint16(22, numberOfChannels, true)
  view.setUint32(24, sampleRate, true)
  view.setUint32(28, sampleRate * blockAlign, true) // ByteRate
  view.setUint16(32, blockAlign, true)
  view.setUint16(34, 16, true) // BitsPerSample
  writeString(view, 36, 'data')
  view.setUint32(40, length * blockAlign, true)

  // Write interleaved audio data
  const offset = 44
  const channels: Float32Array[] = []
  for (let i = 0; i < numberOfChannels; i++) {
    channels.push(audioBuffer.getChannelData(i))
  }

  let pos = offset
  for (let i = 0; i < length; i++) {
    for (let channel = 0; channel < numberOfChannels; channel++) {
      const sample = Math.max(-1, Math.min(1, channels[channel][i]))
      view.setInt16(pos, sample < 0 ? sample * 0x8000 : sample * 0x7fff, true)
      pos += 2
    }
  }

  return new Blob([buffer], { type: 'audio/wav' })
}

function writeString(view: DataView, offset: number, string: string) {
  for (let i = 0; i < string.length; i++) {
    view.setUint8(offset + i, string.charCodeAt(i))
  }
}

/**
 * Get audio duration from blob
 */
export async function getAudioDuration(blob: Blob): Promise<number> {
  const audioContext = new AudioContext()
  const arrayBuffer = await blob.arrayBuffer()
  const audioBuffer = await audioContext.decodeAudioData(arrayBuffer)
  const duration = audioBuffer.duration
  audioContext.close()
  return duration
}
