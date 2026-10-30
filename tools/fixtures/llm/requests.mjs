import assert from 'node:assert/strict'
import { createHash } from 'node:crypto'
import { cachedTranscript, estimateTokens, formatTime, instructionsText } from './reference.mjs'

export const sha256 = text => createHash('sha256').update(text, 'utf8').digest('hex')
const interpolate = (template, values) => template.replace(/\{([A-Za-z]+)\}/g, (match, name) => {
  assert(name in values, `unknown template placeholder ${name}`)
  return String(values[name])
})

export function clipInstruction({ words, preset, instructions = '', window = null }, prompt) {
  const userText = instructionsText(instructions, prompt.request.maxInstructionsLength)
  const parts = [interpolate(prompt.request.durationLine, { duration: formatTime(words.at(-1).end) })]
  if (preset.instruction) parts.push(preset.instruction)
  if (userText) parts.push((preset.instruction ? prompt.request.alsoPrefix : '') + userText)
  if (window && window.count > 1) {
    const values = { windowStart: formatTime(window.start), windowEnd: formatTime(window.end), maxClips: window.maxClips }
    parts.push(...prompt.request.windowLines.map(template => interpolate(template, values)))
    if (preset.id === 'topics' && window.index > 0 && window.lastEnd !== null && window.lastEnd !== undefined) {
      parts.push(interpolate(prompt.request.topicsContinuationLine, { lastEnd: window.lastEnd, nextWord: window.lastEnd + 1 }))
    }
  }
  return parts.join('\n')
}

export function canonicalRequest({ feature, words, lines, choice, instructions = '', window = null, language = 'en' }, prompts) {
  const prompt = feature === 'clipFinder' ? prompts.clipFinder : prompts.aiTighten
  const userText = instructionsText(instructions, prompt.request.maxInstructionsLength)
  let instruction
  if (feature === 'clipFinder') {
    const preset = prompt.presets.find(candidate => candidate.id === choice)
    assert(preset, `unknown clip preset ${choice}`)
    assert(words.length, prompt.messages.noWords)
    if (preset.requiresInstructions && !userText) return { error: 'needInstructions', message: prompt.messages.needInstructions }
    instruction = clipInstruction({ words, preset, instructions, window }, prompt)
  } else {
    const strength = prompt.request.strengths.find(candidate => candidate.id === choice)
    assert(strength, `unknown tighten strength ${choice}`)
    const parts = [strength.instruction]
    if (userText) parts.push(prompt.request.alsoPrefix + userText)
    if (window && window.count > 1) parts.push(interpolate(prompt.request.windowLine, { windowStart: formatTime(window.start), windowEnd: formatTime(window.end) }))
    instruction = parts.join('\n')
  }
  return {
    feature, system: prompt.system, cachedBlock: cachedTranscript(lines, prompt), instruction,
    schemaName: prompt.output.name, schema: prompt.output.schema,
    maxOutputTokens: prompt.generation.maxOutputTokens, effort: prompt.generation.effort, language
  }
}

// ai.md §11.5: local servers clamp the reserve to a quarter of the context (at least 1024).
function reserveFor(prompt, context, maxOutputTokensCap, localServer) {
  const reserve = Math.min(prompt.generation.maxOutputTokens, maxOutputTokensCap ?? prompt.generation.maxOutputTokens)
  return localServer ? Math.min(reserve, Math.max(1024, Math.floor(context / 4))) : reserve
}

export function windowBudget({ words, lines, preset, context, maxOutputTokensCap = null, instructions = '', localServer = false }, prompt) {
  assert(lines.length, 'windowBudget needs transcript lines')
  const longest = values => values.reduce((chosen, value) => Buffer.byteLength(value) > Buffer.byteLength(chosen) ? value : chosen, '')
  const base = clipInstruction({ words, preset, instructions }, prompt)
  const longestInstruction = [base,
    ...prompt.request.windowLines.map(template => interpolate(template, {
      windowStart: longest(lines.map(line => formatTime(line.start))),
      windowEnd: longest(lines.map(line => formatTime(line.end))), maxClips: 99
    })),
    ...(preset.id === 'topics' ? [interpolate(prompt.request.topicsContinuationLine, { lastEnd: words.length - 1, nextWord: words.length })] : [])
  ].join('\n')
  const outputReserve = reserveFor(prompt, context, maxOutputTokensCap, localServer)
  const overhead = estimateTokens(prompt.system) + estimateTokens(longestInstruction) + estimateTokens(JSON.stringify(prompt.output.schema)) + 64
  return { context, outputReserve, overhead, budget: Math.floor((context - overhead - outputReserve) * 0.9) }
}

export function tightenWindowBudget({ lines, context, maxOutputTokensCap = null, strength = 'normal', instructions = '', localServer = false }, prompt) {
  assert(lines.length, 'tightenWindowBudget needs transcript lines')
  const longest = values => values.reduce((chosen, value) => Buffer.byteLength(value) > Buffer.byteLength(chosen) ? value : chosen, '')
  const userText = instructionsText(instructions, prompt.request.maxInstructionsLength)
  const instruction = [prompt.request.strengths.find(candidate => candidate.id === strength).instruction,
    ...(userText ? [prompt.request.alsoPrefix + userText] : []),
    interpolate(prompt.request.windowLine, {
      windowStart: longest(lines.map(line => formatTime(line.start))), windowEnd: longest(lines.map(line => formatTime(line.end)))
    })
  ].join('\n')
  const outputReserve = reserveFor(prompt, context, maxOutputTokensCap, localServer)
  const overhead = estimateTokens(prompt.system) + estimateTokens(instruction) + estimateTokens(JSON.stringify(prompt.output.schema)) + 64
  return { context, outputReserve, overhead, budget: Math.floor((context - overhead - outputReserve) * 0.9) }
}

export function tomlBasicString(text) {
  let escaped = '"'
  const escapes = new Map([['\\', '\\\\'], ['"', '\\"'], ['\b', '\\b'], ['\t', '\\t'], ['\n', '\\n'], ['\f', '\\f'], ['\r', '\\r']])
  for (const scalar of text) {
    const code = scalar.codePointAt(0)
    escaped += escapes.get(scalar) ?? (code <= 0x1F || code === 0x7F ? `\\u${code.toString(16).toUpperCase().padStart(4, '0')}` : scalar)
  }
  return escaped + '"'
}

export function appleSchema(schema, name, clipBudget = null, propertyName = null) {
  if (schema.type === 'object') return {
    name, properties: Object.entries(schema.properties).map(([property, child]) => ({
      name: property, schema: appleSchema(child, `${name}_${property}`, clipBudget, property), isOptional: false
    }))
  }
  if (schema.type === 'array') return { arrayOf: appleSchema(schema.items, `${name}_item`, clipBudget), maximumElements: propertyName === 'clips' ? clipBudget : null }
  if (schema.enum) return { name, anyOf: schema.enum }
  return { type: { string: 'String', integer: 'Int', number: 'Double', boolean: 'Bool' }[schema.type] }
}

export function renderConnector(request, connector, catalog, options = {}) {
  const model = options.model ?? connector.defaultModel ?? (connector.id === 'ollama' ? 'gemma4:12b' : 'local-model')
  const modelInfo = connector.models.find(candidate => candidate.id === model)
  const maxOut = Math.min(request.maxOutputTokens, connector.maxOutputTokensCap ?? request.maxOutputTokens)
  const user = request.cachedBlock === null ? request.instruction : request.cachedBlock + '\n\n' + request.instruction
  const chunks = request.cachedBlock === null ? [request.instruction] : [request.cachedBlock, request.instruction]
  const schema = request.schema
  const compactSchema = JSON.stringify(schema)
  const timeout = catalog.policy.timeoutsSeconds[request.feature === 'test'
    ? connector.cli ? 'cliTest' : 'test'
    : connector.cli ? 'cli' : connector.id === 'apple-foundation' ? 'appleFoundation' : connector.privacy === 'local' || ['ollama', 'lmstudio'].includes(connector.id) ? 'localServer' : 'cloud']
  const messages = [{ role: 'system', content: request.system }, { role: 'user', content: user }]
  if (connector.cli) {
    const flags = new Set(options.supportedFlags ?? [...connector.cli.detect.help.requiredFlags, ...connector.cli.detect.help.optionalFlags])
    const supportedEfforts = options.supportedEfforts ?? []
    const effort = request.effort && (connector.id !== 'codex' || model === 'default' || supportedEfforts.includes(request.effort)) ? request.effort : null
    const fallbackModel = flags.has('--fallback-model') ? connector.fallbackOrder.find(candidate => candidate !== model) : null
    const values = {
      schemaJson: compactSchema, system: request.system, systemToml: tomlBasicString(request.system),
      model: model === 'default' ? '' : model, fallbackModel, effort,
      cwd: '<cwd>', schemaFile: '<io>/schema.json', outFile: '<io>/last.json'
    }
    const features = new Set((options.features ?? connector.cli.disableFeatures ?? []).map(feature => typeof feature === 'string' ? feature : feature.stage === 'removed' ? null : feature.name))
    const argv = []
    const expand = (args, replacements = values) => args.map(argument => interpolate(argument, replacements))
    for (const part of connector.cli.invocation.args) {
      if (typeof part === 'string') argv.push(interpolate(part, values))
      else if (part.forEach) {
        for (const feature of connector.cli.disableFeatures.filter(candidate => features.has(candidate))) argv.push(...expand(part.args, { ...values, feature }))
      } else {
        const enabled = part.when.startsWith('supports:') ? flags.has(part.when.slice(9)) && (part.when !== 'supports:--effort' || effort !== null) : Boolean(values[part.when])
        if (enabled) argv.push(...expand(part.args))
      }
    }
    for (const forbidden of connector.cli.forbiddenFlags) assert(!argv.includes(forbidden), `forbidden CLI flag ${forbidden}`)
    return { kind: 'cli', model, timeoutSeconds: timeout, executable: connector.cli.executable, argv, stdin: user, cwd: '<cwd>', files: connector.id === 'codex' ? { '<io>/schema.json': compactSchema } : {} }
  }
  if (connector.id === 'apple-foundation') {
    return {
      kind: 'logical', model, timeoutSeconds: timeout,
      session: { fresh: true, instructions: request.system }, prompt: user,
      schema: { root: appleSchema(schema, request.schemaName, options.clipBudget ?? null), dependencies: [] },
      options: { [options.macOSMajor === 26 ? 'sampling' : 'samplingMode']: 'greedy', maximumResponseTokens: maxOut },
      language: request.language
    }
  }
  const headers = { ...connector.headers }
  if (connector.auth?.type === 'apiKey') headers[connector.auth.header] = interpolate(connector.auth.valueTemplate, { key: '<key>' })
  headers['content-type'] ??= 'application/json'
  let body
  switch (connector.id) {
    case 'anthropic': {
      const fallback = modelInfo?.serverSideFallback && options.serverSideFallback !== false
      if (fallback) headers['anthropic-beta'] = connector.serverSideFallback.betaHeader
      let instruction = request.instruction
      const structured = !(options.structuredOutputsSupported === false && !modelInfo)
      if (!structured) instruction += '\n\nReply with only a JSON object that matches this JSON Schema: ' + compactSchema
      const content = request.cachedBlock === null ? [{ type: 'text', text: instruction }] : [
        { type: 'text', text: request.cachedBlock, cache_control: { type: 'ephemeral' } }, { type: 'text', text: instruction }
      ]
      const outputConfig = {}
      if (request.effort && (modelInfo?.effort || options.effortSupported || (!modelInfo && /^claude-(opus|sonnet|haiku|fable)-5/.test(model)))) outputConfig.effort = request.effort
      if (structured) outputConfig.format = { type: 'json_schema', schema }
      body = { model, max_tokens: maxOut, system: request.system, messages: [{ role: 'user', content }], output_config: outputConfig }
      if (fallback) Object.assign(body, connector.serverSideFallback.body)
      break
    }
    case 'openai':
      body = {
        model, instructions: request.system, input: [{ role: 'user', content: chunks.map(text => ({ type: 'input_text', text })) }],
        text: { format: { type: 'json_schema', name: request.schemaName, strict: true, schema } }, max_output_tokens: maxOut
      }
      if (request.effort && (modelInfo?.effort || (!modelInfo && /^(gpt-5|gpt-6|o[0-9])/.test(model)))) body.reasoning = { effort: request.effort }
      body.store = false
      if (request.cachedBlock !== null) body.prompt_cache_key = 'voxclip-' + sha256(request.cachedBlock).slice(0, 16)
      break
    case 'xai':
      body = { model, max_completion_tokens: maxOut, messages, response_format: { type: 'json_schema', json_schema: { name: request.schemaName, strict: true, schema } } }
      break
    case 'gemini':
      body = {
        systemInstruction: { parts: [{ text: request.system }] }, contents: [{ role: 'user', parts: chunks.map(text => ({ text })) }],
        generationConfig: { maxOutputTokens: maxOut, responseMimeType: 'application/json', responseJsonSchema: schema }
      }
      if (request.effort && /^gemini-([3-9]|[1-9][0-9]+)([.-]|$)/.test(model.replace(/^models\//, ''))) body.generationConfig.thinkingConfig = { thinkingLevel: request.effort.toUpperCase() }
      break
    case 'ollama': {
      const needed = estimateTokens(request.system) + estimateTokens(request.cachedBlock) + estimateTokens(request.instruction) + estimateTokens(compactSchema) + maxOut + 256
      body = { model, stream: false, messages, format: schema, options: { num_ctx: Math.min(options.modelContext ?? 32768, Math.max(8192, Math.ceil(needed / 1024) * 1024)), num_predict: maxOut, temperature: 0 } }
      if ((options.capabilities ?? ['completion', 'thinking']).includes('thinking')) body.think = false
      body.keep_alive = '10m'
      break
    }
    case 'lmstudio':
      body = { model, max_tokens: maxOut, temperature: 0, messages, response_format: { type: 'json_schema', json_schema: { name: request.schemaName, strict: true, schema } } }
      break
    default: throw new Error(`unknown connector ${connector.id}`)
  }
  const escapedModel = encodeURIComponent(model.replace(/^models\//, '')).replace(/[!'()*]/g, scalar => '%' + scalar.codePointAt(0).toString(16).toUpperCase())
  const url = (options.baseUrl ?? connector.baseUrl).replace(/\/$/, '') + connector.generate.path.replace('{model}', escapedModel)
  assert(!url.includes('key='), 'API keys must never appear in URLs')
  return { kind: 'http', model, timeoutSeconds: timeout, method: connector.generate.method, url, headers, body }
}
