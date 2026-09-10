#!/usr/bin/env node
// Collect every artefact GitHub keeps about a set of workflow runs:
// the run record, its jobs, every annotation on every check run, and the
// full log archive. Written for issue #123; re-runnable and idempotent.
import { execFileSync } from 'node:child_process'
import { mkdirSync, writeFileSync, existsSync } from 'node:fs'
import { gzipSync } from 'node:zlib'
import { join } from 'node:path'

const REPO = process.env.REPO ?? 'link-foundation/box'
const OUT = process.env.OUT ?? 'dev/log/issues/123/pulls/124'
const VERBOSE = process.env.VERBOSE === '1'

const log = (...a) => VERBOSE && console.error('[collect]', ...a)

function api(path, { paginate = true } = {}) {
  const args = ['api', path, '-H', 'Accept: application/vnd.github+json']
  if (paginate) args.push('--paginate')
  log('GET', path)
  return execFileSync('gh', args, { encoding: 'utf8', maxBuffer: 256 * 1024 * 1024 })
}

// gh --paginate concatenates JSON objects; merge the arrays under `key`.
function apiList(path, key) {
  const raw = api(path)
  const out = []
  let depth = 0, start = 0, inStr = false, esc = false
  for (let i = 0; i < raw.length; i++) {
    const c = raw[i]
    if (esc) { esc = false; continue }
    if (c === '\\') { esc = true; continue }
    if (c === '"') { inStr = !inStr; continue }
    if (inStr) continue
    if (c === '{') { if (depth === 0) start = i; depth++ }
    else if (c === '}') { depth--; if (depth === 0) out.push(JSON.parse(raw.slice(start, i + 1))) }
  }
  return out.flatMap((o) => (key ? (o[key] ?? []) : [o]))
}

function save(rel, data) {
  const p = join(OUT, rel)
  mkdirSync(join(p, '..'), { recursive: true })
  writeFileSync(p, typeof data === 'string' ? data : JSON.stringify(data, null, 2) + '\n')
  log('wrote', p)
  return p
}

const runIds = process.argv.slice(2)
if (runIds.length === 0) {
  console.error('usage: collect-ci-evidence.mjs <run-id>...')
  process.exit(2)
}

const index = []
for (const id of runIds) {
  const run = JSON.parse(api(`repos/${REPO}/actions/runs/${id}`, { paginate: false }))
  save(`runs/${id}.run.json`, run)

  const jobs = apiList(`repos/${REPO}/actions/runs/${id}/jobs?per_page=100&filter=all`, 'jobs')
  save(`runs/${id}.jobs.json`, jobs)

  // Annotations live on check runs, whose ids equal job ids for Actions jobs.
  const annotations = []
  for (const job of jobs) {
    let anns = []
    try {
      anns = apiList(`repos/${REPO}/check-runs/${job.id}/annotations?per_page=100`)
    } catch (e) {
      log('annotations failed for job', job.id, e.message)
    }
    for (const a of anns) annotations.push({ run_id: Number(id), job_id: job.id, job_name: job.name, ...a })
  }
  save(`annotations/${id}.annotations.json`, annotations)

  // `ci-logs`, not `logs`, and gzipped, because .gitignore excludes both a
  // directory named `logs` (line 2) and `*.log` (line 3) -- either one would drop
  // the whole set silently. A release run's log is also ~800 kB of docker build
  // output that compresses about 9:1. Read one with `zcat`; both names are
  // checked so an already-collected run is never refetched.
  const logDir = join(OUT, 'ci-logs')
  const logPath = join(logDir, `${id}.log.gz`)
  mkdirSync(logDir, { recursive: true })
  if (!existsSync(logPath) && !existsSync(join(logDir, `${id}.log`))) {
    let text
    try {
      text = execFileSync('gh', ['run', 'view', id, '--repo', REPO, '--log'], {
        encoding: 'utf8', maxBuffer: 1024 * 1024 * 1024,
      })
    } catch (e) {
      // A cancelled/expired run may have no log archive.
      text = `LOG UNAVAILABLE: ${e.message}\n${e.stdout ?? ''}`
    }
    writeFileSync(logPath, gzipSync(text, { level: 9 }))
  }

  index.push({
    run_id: Number(id),
    workflow: run.name,
    status: run.status,
    conclusion: run.conclusion,
    head_sha: run.head_sha,
    head_branch: run.head_branch,
    event: run.event,
    created_at: run.created_at,
    updated_at: run.updated_at,
    jobs: jobs.length,
    job_conclusions: jobs.reduce((m, j) => ({ ...m, [j.conclusion ?? 'null']: (m[j.conclusion ?? 'null'] ?? 0) + 1 }), {}),
    annotations: annotations.length,
    annotation_levels: annotations.reduce((m, a) => ({ ...m, [a.annotation_level]: (m[a.annotation_level] ?? 0) + 1 }), {}),
    url: run.html_url,
  })
  console.log(`${id} ${run.name} ${run.conclusion} jobs=${jobs.length} annotations=${annotations.length}`)
}
save('runs/index.json', index)
