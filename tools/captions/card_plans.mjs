// Caption copies for gen_cards.py and gen_gallery.py: reads {name: project} JSON on stdin and writes
// {name: {take, clips, durations}} to stdout, where take and clips[id] are the caption copy (editing spec 7.6) of the
// full take and of each stored clip, and durations.take and durations.clips[id] their edited durations in seconds.
// Planning comes from the editing fixture generator (tools/fixtures/editing), so the caption fixtures use the same
// reference planner as shared/fixtures/editing. Needs Node 22.13 or newer.
import { readFileSync } from 'node:fs'
import { timelineWith } from '../fixtures/editing/lib/reference.mjs'
import { projectPlans } from '../fixtures/editing/lib/voxclip.mjs'

const projects = JSON.parse(readFileSync(0, 'utf8'))
const out = {}
for (const name of Object.keys(projects).sort()) {
  const plans = await projectPlans(projects[name], timelineWith)
  out[name] = {
    take: plans.take.captions,
    clips: Object.fromEntries(plans.clips.map(clip => [clip.id, clip.captions])),
    durations: { take: plans.take.durationSeconds, clips: Object.fromEntries(plans.clips.map(clip => [clip.id, clip.durationSeconds])) }
  }
}
process.stdout.write(JSON.stringify(out))
