export const f1Words = [
  ['So,', 0, 0.3], ['today', 0.35, 0.7], ['I', 0.75, 0.85], ['want', 0.85, 1.1], ['to', 1.1, 1.2], ['talk.', 1.2, 1.6],
  ['Um', 3.85, 4.1], ['why', 4.2, 4.45], ['cut', 4.5, 4.8], ['by', 4.85, 5], ['words?', 5, 5.4], ['"It', 5.5, 5.7], ['works."', 5.7, 6.2],
  ['Fast', 7.45, 7.8], ['and', 7.85, 8], ['clean', 8.05, 8.5], ['Tere!', 70, 70.4], ['Mis', 70.5, 70.7], ['toimub?', 70.75, 71.2],
  ['「本当', 71.3, 71.6], ['です。」', 71.6, 72], ['w21', 72.1, 72.35], ['w22', 72.4, 72.65], ['w23', 72.7, 72.95], ['w24', 73, 73.25],
  ['w25', 73.3, 73.55], ['w26', 73.6, 73.85], ['w27', 73.9, 74.15], ['w28', 74.2, 74.45], ['w29', 74.5, 74.75], ['w30', 74.8, 75.05],
  ['w31', 75.1, 75.35], ['w32', 75.4, 75.65], ['w33', 75.7, 75.95], ['w34', 76, 76.25], ['w35', 76.3, 76.55], ['w36', 76.6, 76.85],
  ['w37', 76.9, 77.15], ['w38', 77.2, 77.45], ['w39', 77.5, 77.75], ['w40', 77.8, 78.05], ['w41', 78.1, 78.35], ['w42', 78.4, 78.65],
  ['w43', 78.7, 78.95], ['w44', 79, 79.25], ['w45', 79.3, 79.55], ['w46', 79.6, 79.85], ['w47', 79.9, 80.15], ['w48', 80.2, 80.45],
  ['w49', 80.5, 80.75], ['w50', 80.8, 81.05], ['w51', 81.1, 81.35], ['w52', 81.4, 81.65], ['w53', 81.7, 81.95], ['w54', 82, 82.25],
  ['w55', 82.3, 82.55], ['w56', 82.6, 82.85], ['w57', 82.9, 83.15], ['w58', 83.2, 83.45], ['w59', 83.5, 83.75],
  ['w60', 83.8, 84.05], ['w61', 84.1, 84.35], ['w62', 84.4, 84.65], ['w63', 84.7, 84.95], ['w64', 85, 85.25], ['w65', 85.3, 85.55], ['end.', 200, 200.5]
].map(([text, start, end], index) => ({ id: `w${index}`, index, text, start, end }))

export const f1Rendered = [
  '[0-5] 0:00 So, today I want to talk.', '(pause 2.3s)', '[6-10] 0:03 Um why cut by words?', '[11-12] 0:05 "It works."',
  '[13-15] 0:07 Fast and clean', '(pause 61.5s)', '[16-16] 1:10 Tere!', '[17-18] 1:10 Mis toimub?',
  '[19-59] 1:11 「本当 です。」 w21 w22 w23 w24 w25 w26 w27 w28 w29 w30 w31 w32 w33 w34 w35 w36 w37 w38 w39 w40 w41 w42 w43 w44 w45 w46 w47 w48 w49 w50 w51 w52 w53 w54 w55 w56 w57 w58 w59',
  '[60-65] 1:23 w60 w61 w62 w63 w64 w65', '(pause 114.5s)', '[66-66] 3:20 end.'
].join('\n')

export const fixedVectors = [
  [0.05, '0.1'], [0.15, '0.1'], [0.25, '0.3'], [0.35, '0.3'], [0.45, '0.5'], [1.25, '1.3'], [1.45, '1.4'],
  [2.05, '2.0'], [2.25, '2.3'], [9.95, '9.9'], [99.95, '100.0'], [1.2499999999999998, '1.2'], [1.2500000000000002, '1.3']
]
export const timeVectors = [[0, '0:00'], [5.9, '0:05'], [70, '1:10'], [200, '3:20'], [4523.7, '75:23']]

export const u100Words = Array.from({ length: 100 }, (_, index) => ({ id: `w${index}`, index, text: `w${index}`, start: index, end: index + 0.8 }))
export const candidate = (title, start, end, score = 8, reason = title) => ({ title, start_word: start, end_word: end, reason, score })
const clip = (title, reason, score, startWord, endWord) => ({ title, reason, score, startWord, endWord })

export const finalizeVectors = [
  {
    id: 'C1', preset: 'best', candidates: [
      candidate('  Strong opener  ', 0, 20, 8.6, ' r1 '), candidate('Best', 10, 30, 9, 'r2'), candidate('Duplicate of best', 10, 30, 7, 'r3'),
      candidate('Too short', 50, 55, 10, 'r4'), candidate('Out of range', 40, 130, 10, 'r5'), candidate('Reversed', 60, 59, 10, 'r6'),
      candidate('Clamped score', 60, 99, 12, 'r7'), candidate('Fractional index', 5.5, 30, 10, 'r8'), candidate('T'.repeat(130), 20, 45, 6, 'R'.repeat(310)),
      candidate('Low score', 70, 90, -3.5, 'r10'), candidate('Too long', 0, 99, 9, 'r11'), candidate('Tie A', 30, 50, 6, 'r12')
    ],
    expected: [clip('Strong opener', 'r1', 9, 0, 20), clip('Best', 'r2', 9, 10, 30), clip('T'.repeat(120), 'R'.repeat(300), 6, 20, 45), clip('Tie A', 'r12', 6, 30, 50), clip('Clamped score', 'r7', 10, 60, 99)]
  },
  {
    id: 'C2', preset: 'topics', candidates: [candidate('A', 0, 30, 7, 'a'), candidate('B overlaps A', 30, 60, 8, 'b'), candidate('C', 61, 99, 6, 'c'), candidate('D inside C', 70, 90, 9, 'd'), candidate('E', 0, 20, 5, 'e')],
    expected: [clip('E', 'e', 5, 0, 20), clip('B overlaps A', 'b', 8, 30, 60), clip('D inside C', 'd', 9, 70, 90)]
  },
  {
    id: 'C3', preset: 'quotes', candidates: Array.from({ length: 8 }, (_, index) => candidate(`Q${index}`, 12 * index, 12 * index + 5, index % 2 === 0 ? 7 : 8, 'q')),
    expected: [clip('Q0', 'q', 7, 0, 5), clip('Q1', 'q', 8, 12, 17), clip('Q2', 'q', 7, 24, 29), clip('Q3', 'q', 8, 36, 41), clip('Q5', 'q', 8, 60, 65), clip('Q7', 'q', 8, 84, 89)]
  }
]

export const snapVectors = [
  [[7, 14], [6, 15]], [[2, 9], [0, 10]], [[12, 14], [11, 15]], [[30, 40], [30, 40]], [[17, 17], [17, 18]], [[15, 15], [15, 15]]
]
export const w1Bounds = [[0, 7994, 7995], [7800, 15794, 7995], [15600, 19999, 4400]]

const entries = (firstIndex, text) => text.map((word, position) => ({ id: `w${firstIndex + position}`, index: firstIndex + position, text: word, start: position * 0.3, end: position * 0.3 + 0.25 }))
export const t1Entries = entries(40, ['So,', 'um,', 'we', 'we', 'went', 'to', 'the', 'uh', 'the', 'store.'])
const edit = (line, keep, kind = 'filler') => ({ line, keep, kind })
const proposal = (lineLabel, cutIndices, preselected = true, kind = 'filler') => ({ lineLabel, kind, cutWordIds: cutIndices.map(index => `w${index}`), preselected })
const accepted = proposals => ({ proposals, rejectedCount: 0, rejected: [] })
const rejected = reason => ({ proposals: [], rejectedCount: 1, rejected: [{ editIndex: 0, reason }] })
export const tightenVectors = [
  { id: 'T1', entries: t1Entries, edits: [edit('[40-49]', 'So, we went to the store.')], expected: accepted([proposal('[40-49]', [41, 42, 46, 47])]) },
  { id: 'T2', entries: t1Entries, edits: [edit('[40-49]', 'So we went to the shop.')], expected: rejected('notSubsequence') },
  { id: 'T3', entries: t1Entries, edits: [edit('[40-49]', '')], expected: accepted([proposal('[40-49]', Array.from({ length: 10 }, (_, index) => 40 + index))]) },
  { id: 'T4', entries: t1Entries, edits: [edit('[40-49]', 'store')], expected: accepted([proposal('[40-49]', Array.from({ length: 9 }, (_, index) => 40 + index), false)]) },
  { id: 'T5', entries: t1Entries, edits: [edit('[99-120]', '')], expected: rejected('unknownLine') },
  { id: 'T6', entries: entries(50, ['going to', 'win.']), edits: [edit('[50-51]', 'going win')], expected: rejected('splitWord') },
  { id: 'T7', entries: entries(60, ['Well', '—', 'um', 'yes.']), edits: [edit('[60-63]', 'Well yes.')], expected: accepted([proposal('[60-63]', [62])]) },
  { id: 'T8', entries: t1Entries, edits: [edit('[40-49]', 'so WE went to the store')], expected: accepted([proposal('[40-49]', [41, 42, 46, 47])]) }
]

export function syntheticWords(descriptor) {
  if (descriptor.generator === 'U100') return u100Words
  if (descriptor.generator === 'W1') return Array.from({ length: 20000 }, (_, index) => ({
    id: `w${index}`, index, text: `w${index}${index % 15 === 14 ? '.' : ''}`, start: 0.3 * index, end: 0.3 * index + 0.25
  }))
  throw new Error(`unknown synthetic generator ${descriptor.generator}`)
}

export function randomValues({ seed, count, scale }) {
  let state = seed
  return Array.from({ length: count }, () => {
    state = (Math.imul(1664525, state) + 1013904223) >>> 0
    return (state / 4294967296) * scale
  })
}
