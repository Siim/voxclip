// Caption copies for gen_cards.py: reads {name: project} JSON on stdin and writes {name: {take, clips}} to stdout,
// where take and clips[id] are the caption copy (editing spec 7.6) of the full take and of each stored clip.
// Planning comes from the editing fixture generator (tools/fixtures/editing), so the card fixtures use the same
// reference planner as shared/fixtures/editing. Needs Node 22.13 or newer.
import { readFileSync } from 'node:fs'
import { timelineWith } from '../fixtures/editing/lib/reference.mjs'
import { projectPlans } from '../fixtures/editing/lib/voxclip.mjs'

const projects = JSON.parse(readFileSync(0, 'utf8'))
const out = {}
for (const name of Object.keys(projects).sort()) {
  const plans = await projectPlans(projects[name], timelineWith)
  out[name] = { take: plans.take.captions, clips: Object.fromEntries(plans.clips.map(clip => [clip.id, clip.captions])) }
}
process.stdout.write(JSON.stringify(out))
