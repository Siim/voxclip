import assert from 'node:assert/strict'
import { cachedTranscript, estimateTokens, formatTranscript, jsTrim, toFixed1 } from './reference.mjs'

// One pass, so text substituted for one placeholder is never read as another.
const fill = (template, values) => {
  assert.equal(typeof template, 'string', 'missing prompt template')
  return template.replace(/\{([A-Za-z]+)\}/g, (match, name) => {
    assert(name in values, `unknown template placeholder ${name}`)
    return String(values[name])
  })
}

const canonical = (prompt, cachedBlock, instruction, language) => ({
  feature: 'voiceRewrite', system: prompt.system, cachedBlock, instruction,
  schemaName: prompt.schemaName, schema: prompt.schema, effort: 'medium', language
})

// voice-lab §8.1 and §8.9.1: the quote estimates the whole rendered request with est() (ai.md §11.5), at no known price.
export const voiceLabEstimate = ({ system, cachedBlock, instruction }) => ({ units: estimateTokens(system + cachedBlock + instruction), unit: 'token', basis: 'unknown' })

// voice-lab §8.9.1 "Rewrite request": the source block, the optional user request, then the length line.
export function voiceRewriteRequest({ scope, sourceWords, instruction, language, targetSeconds, minChars, maxChars }, prompt) {
  assert(['passage', 'fullTake'].includes(scope), `unknown rewrite scope ${scope}`)
  assert(Number.isFinite(targetSeconds) && targetSeconds > 0 && targetSeconds <= 600, 'targetSeconds is outside (0, 600]')
  assert(Number.isInteger(minChars) && Number.isInteger(maxChars) && minChars >= 1 && minChars <= maxChars && maxChars <= 5000,
    'the character range is outside 1 <= minChars <= maxChars <= 5000')
  const templates = prompt.request
  const cachedBlock = fill(templates.sourceBlock, { scope, language, source: sourceWords.map(word => word.text).join(' ') })
  const request = jsTrim(instruction)
  const parts = request ? [fill(templates.instructionBlock, { instruction: request })] : []
  parts.push(fill(templates.returnLine, {}) + '\n' + fill(templates.lengthLine, { targetSeconds: toFixed1(targetSeconds), minChars, maxChars }))
  return canonical(prompt, cachedBlock, parts.join('\n\n'), language)
}

// voice-lab §8.1 "Fix with AI": the clip finder's transcript block, then one range per line and the instruction.
export function patchRewriteRequest({ entries, ranges, instruction, language }, prompt) {
  const lines = formatTranscript(entries).lines
  assert.deepEqual(ranges.map(range => range.line), lines.map(line => `[${line.firstIndex}-${line.lastIndex}]`), 'one range per transcript line, in line order')
  for (const { minChars, maxChars } of ranges) {
    assert(Number.isInteger(minChars) && Number.isInteger(maxChars) && minChars >= 1 && minChars <= maxChars && maxChars <= 5000,
      'a line range is outside 1 <= minChars <= maxChars <= 5000')
  }
  const request = jsTrim(instruction)
  assert(request, 'Fix with AI needs an instruction')
  const templates = prompt.request
  const rangeLines = ranges.map(({ line, minChars, maxChars }) => fill(templates.rangeLine, { line, minChars, maxChars }))
  const text = [fill(templates.rangesLine, {}), ...rangeLines].join('\n') + '\n\n' + fill(templates.instructionLine, { instruction: request })
  return canonical(prompt, cachedTranscript(lines, prompt), text, language)
}
