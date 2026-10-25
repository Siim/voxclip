// Stable, diff-friendly JSON: 2-space indentation, with any array or object that fits on one
// line (at most WIDTH characters including indentation) written inline. Numbers and strings
// are written exactly as JSON.stringify writes them (shortest round-trip doubles).
const WIDTH = 140

function scalar(value) {
  if (typeof value === 'number' && !Number.isFinite(value)) throw new Error('non-finite number in fixture output; encode it as "NaN", "Infinity" or "-Infinity"')
  if (value === undefined) throw new Error('undefined in fixture output')
  return JSON.stringify(value)
}

function inline(value) {
  if (value === null || typeof value !== 'object') return scalar(value)
  if (Array.isArray(value)) return '[' + value.map(inline).join(', ') + ']'
  const entries = Object.entries(value).filter(([, v]) => v !== undefined)
  return '{' + entries.map(([k, v]) => JSON.stringify(k) + ': ' + inline(v)).join(', ') + '}'
}

function block(value, indent) {
  if (value === null || typeof value !== 'object') return scalar(value)
  const one = inline(value)
  if (indent.length + one.length <= WIDTH) return one
  const inner = indent + '  '
  if (Array.isArray(value)) {
    if (!value.length) return '[]'
    return '[\n' + value.map(v => inner + block(v, inner)).join(',\n') + '\n' + indent + ']'
  }
  const entries = Object.entries(value).filter(([, v]) => v !== undefined)
  if (!entries.length) return '{}'
  return '{\n' + entries.map(([k, v]) => inner + JSON.stringify(k) + ': ' + block(v, inner)).join(',\n') + '\n' + indent + '}'
}

export const formatJson = value => block(value, '') + '\n'
