#!/usr/bin/env bash
# test-issue115-workflow-split.sh
#
# Issue #115, RC-8. .github/workflows/release.yml had grown to 3135 lines - more
# than twice the 1500-line limit the reference CI/CD template enforces. At that
# size a fix applied to one of the ten near-identical build jobs kept surviving
# in the other nine: RC-4 (the Docker Hub login failing a job whose GHCR push
# had succeeded) and RC-7 (no retry around a registry call) had both been fixed
# once and come back, because "once" meant one copy.
#
# The file is now a caller plus six `workflow_call` files, one per image family.
# That split introduces failure modes a single file cannot have, and every one
# of them fails *late*: at the end of a build, or not at all.
#
#   - workflow-level `env` is NOT inherited by a called workflow. A missing
#     GHCR_IMAGE_NAME does not fail the workflow, it pushes `ghcr.io/:2.5.0`.
#   - a called workflow's `permissions` are capped by the caller job's. A job
#     needing `packages: write` under a caller granting `contents: read` gets a
#     403 from the registry after the image has been built.
#   - `with:` and `secrets:` are a contract. An input the caller forgets is
#     empty at expansion time, and an empty string compares unequal to
#     'success', so the job silently skips - a false negative of exactly the
#     kind this issue is about.
#   - `on.push.paths` in the caller decides what triggers a build. Because the
#     build jobs no longer live in release.yml, a path list that names only
#     release.yml means editing a build job triggers nothing.
#   - a called workflow cannot expose `needs.<job>.result`; only
#     `jobs.<id>.outputs` crosses the boundary. Each family therefore has a
#     `status` job that republishes its jobs' results. A job added to a family
#     and not added to `status`'s `needs` is invisible to the caller's gating.
#
# None of these can be caught by running the pipeline on a pull request: the
# build jobs only run on `push` to main or a manual dispatch. So they are
# checked here, structurally, from the parsed YAML.
#
# The one-off proof that the split moved the jobs rather than changing them is
# separate, against a frozen snapshot of the pre-split file:
#   python3 dev/log/issues/115/pulls/116/analysis/verify-split-equivalence.py
#
# Usage: bash experiments/test-issue115-workflow-split.sh

set -uo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1

# Ruby ships with the runner image and with this box image, and it parses YAML
# without a pip install (this repository's other policy suite,
# test-issue90-release-workflow-policy.sh, already relies on that). Text
# matching is not enough here: most of the assertions below are about the
# relationship between two documents.
ruby <<'RUBY'
require "yaml"
require "set"

CALLER = ".github/workflows/release.yml"
CALLED = {
  "js"        => ".github/workflows/release-js.yml",
  "essentials"=> ".github/workflows/release-essentials.yml",
  "languages" => ".github/workflows/release-languages.yml",
  "full"      => ".github/workflows/release-full.yml",
  "dind"      => ".github/workflows/release-dind.yml",
  "pr-tests"  => ".github/workflows/pr-tests.yml",
}
# The image families. Which of them need a `status` job is not listed here: it
# is derived below from what the caller actually reads, so adding a read adds
# the requirement.
FAMILIES = %w[js essentials languages full dind]
LINE_LIMIT = 1500

$pass = 0
$fail = 0
def pass(m) = ($pass += 1; puts "PASS: #{m}")
def fail(m, detail = nil)
  $fail += 1
  puts "FAIL: #{m}"
  warn detail.to_s.lines.map { |l| "      #{l}" }.join unless detail.nil?
end

# Read with an explicit encoding, never YAML.load_file. Under a non-UTF-8
# locale - which is what a container without LANG set has - Ruby tags the file
# US-ASCII, and the first non-ASCII byte raises "invalid byte sequence" from
# String#scan. Two suites in this repository were crashing that way and nobody
# knew, because nothing ran them (RC-9).
def load(path) = YAML.load(File.read(path, encoding: "UTF-8"), aliases: true)
# Psych parses YAML 1.1, where the bare key `on` is the boolean true. Every
# workflow file in existence hits this; read both spellings.
def triggers(wf) = (wf[true] || wf["on"] || {})

caller_wf = load(CALLER)
caller_jobs = caller_wf.fetch("jobs")
called_wf = CALLED.transform_values { |p| load(p) }

puts "== Part 1: every called workflow is callable and nothing else =="

CALLED.each do |name, path|
  t = triggers(called_wf[name])
  if t.keys == ["workflow_call"]
    pass "#{path} is triggered by workflow_call and by nothing else"
  else
    # A second trigger here would start a run of its own on every push, in
    # parallel with the caller's - two builds racing for the same tags.
    fail "#{path} is triggered by workflow_call and by nothing else", "found: #{t.keys.inspect}"
  end
end

puts ""
puts "== Part 2: the caller calls each of them, and each call resolves =="

uses = caller_jobs.filter_map { |id, j| [id, j["uses"]] if j["uses"].to_s.start_with?("./") }.to_h

CALLED.each do |name, path|
  if uses[name] == "./#{path}"
    pass "#{CALLER} job '#{name}' calls #{path}"
  else
    fail "#{CALLER} job '#{name}' calls #{path}", "found: #{uses[name].inspect}"
  end
end

uses.each do |id, ref|
  # A `uses:` pointing at a file that is not there fails the whole workflow at
  # parse time, before any job runs, with no annotation on the job that caused
  # it. Renaming a called workflow without updating the caller is the way in.
  if File.exist?(ref.delete_prefix("./"))
    pass "job '#{id}' points at a file that exists"
  else
    fail "job '#{id}' points at a file that exists", "missing: #{ref}"
  end
end

puts ""
puts "== Part 3: every release-*.yml carries the caller's env, with the same values =="

# The assertion the header comment in each release-*.yml names. Workflow-level
# `env` is per-file: a called workflow that does not re-declare these builds
# tags out of empty strings and pushes them, and the push succeeds.
caller_env = caller_wf.fetch("env")
FAMILIES.each do |name|
  env = called_wf[name]["env"]
  if env == caller_env
    pass "#{CALLED[name]} declares the same #{caller_env.size} env values as the caller"
  else
    missing = caller_env.reject { |k, v| env && env[k] == v }
    fail "#{CALLED[name]} declares the same env values as the caller",
         "differs or missing: #{missing.inspect}"
  end
end

puts ""
puts "== Part 4: editing a called workflow triggers a build =="

paths = triggers(caller_wf).dig("push", "paths") || []
([CALLER] + CALLED.values).each do |path|
  if paths.include?(path)
    pass "on.push.paths lists #{path}"
  else
    # Without this the build jobs are unreachable from the change that touched
    # them: a fix to a build job would be merged and never built.
    fail "on.push.paths lists #{path}", "on.push.paths = #{paths.inspect}"
  end
end

puts ""
puts "== Part 5: the with:/secrets: contract is complete on both sides =="

CALLED.each do |name, path|
  call = triggers(called_wf[name]).fetch("workflow_call")
  declared_in = (call["inputs"] || {})
  declared_sec = (call["secrets"] || {})
  passed_in = (caller_jobs[name]["with"] || {})
  passed_sec = (caller_jobs[name]["secrets"] || {})

  required = declared_in.select { |_, spec| spec["required"] }.keys
  # An input the caller does not pass expands to the empty string. Nothing
  # errors; the job's `if:` compares "" against 'success' and skips. That is a
  # build that silently does not happen.
  missing = required - passed_in.keys
  if missing.empty?
    pass "#{path}: caller passes all #{required.size} required inputs"
  else
    fail "#{path}: caller passes all required inputs", "missing: #{missing.inspect}"
  end

  unknown = passed_in.keys - declared_in.keys
  # This one GitHub does report - but as a workflow-level error before any job
  # starts, so it takes out the whole run, not just this job.
  if unknown.empty?
    pass "#{path}: caller passes no input the workflow does not declare"
  else
    fail "#{path}: caller passes no undeclared input", "unknown: #{unknown.inspect}"
  end

  missing_sec = declared_sec.keys - passed_sec.keys
  if missing_sec.empty?
    pass "#{path}: caller passes all #{declared_sec.size} declared secrets"
  else
    # Secrets are not inherited either. A missing DOCKERHUB_TOKEN logs in as
    # nobody, and the mirror push fails at the end of the build.
    fail "#{path}: caller passes all declared secrets", "missing: #{missing_sec.inspect}"
  end

  unknown_sec = passed_sec.keys - declared_sec.keys
  if unknown_sec.empty?
    pass "#{path}: caller passes no secret the workflow does not declare"
  else
    fail "#{path}: caller passes no undeclared secret", "unknown: #{unknown_sec.inspect}"
  end
end

puts ""
puts "== Part 6: every output the caller reads is declared by the callee =="

caller_text = File.read(CALLER, encoding: "UTF-8")
read = caller_text.scan(/needs\.([a-z0-9-]+)\.outputs\.([a-z0-9_-]+)/)
                  .group_by(&:first)
                  .transform_values { |v| v.map(&:last).uniq.sort }

CALLED.each_key do |name|
  wanted = read[name] || []
  next if wanted.empty?
  declared = (triggers(called_wf[name]).fetch("workflow_call")["outputs"] || {}).keys
  missing = wanted - declared
  if missing.empty?
    pass "#{CALLED[name]} declares the #{wanted.size} output(s) the caller reads"
  else
    # An undeclared output is the empty string, and every condition that reads
    # it goes false. The build after it does not run and nothing is red.
    fail "#{CALLED[name]} declares the outputs the caller reads", "missing: #{missing.inspect}"
  end
end

puts ""
puts "== Part 7: the results the caller reads are exported completely =="

# A called workflow cannot expose `needs.<job>.result`; only `jobs.<id>.outputs`
# crosses the boundary, and four of the results the caller's conditions read
# belong to matrix jobs, whose rollup result no per-leg step output can
# reproduce. Hence the `status` job - but only in the families the caller reads
# something from. dind has none because nothing downstream consumes its results;
# start reading one and this check will ask for the job.
FAMILIES.each do |name|
  wanted = read[name] || []
  status = called_wf[name].fetch("jobs")["status"]

  if wanted.empty?
    if status.nil?
      pass "#{CALLED[name]}: no status job, and the caller reads no output from it"
    else
      pass "#{CALLED[name]}: has a status job"
    end
    next unless status
  elsif status.nil?
    fail "#{CALLED[name]} has a status job", "the caller reads #{wanted.inspect} from it"
    next
  else
    pass "#{CALLED[name]}: has the status job the caller's #{wanted.size} read(s) need"
  end

  jobs = called_wf[name].fetch("jobs")
  needs = Array(status["needs"])
  missing = jobs.keys - needs - ["status"]
  if missing.empty?
    pass "#{CALLED[name]}: status needs all #{needs.size} of its sibling jobs"
  else
    # A job the status job does not need is a job whose failure the caller
    # cannot see: `status` runs on `!cancelled()` and reports success, and the
    # family looks green with one leg missing.
    fail "#{CALLED[name]}: status needs all of its sibling jobs", "not needed: #{missing.inspect}"
  end

  # `status` must not gate on its siblings succeeding, or a failed leg makes it
  # skip and the caller reads empty strings instead of results.
  cond = status["if"].to_s
  if cond.include?("!cancelled()")
    pass "#{CALLED[name]}: status runs even when a sibling fails"
  else
    fail "#{CALLED[name]}: status runs even when a sibling fails", "if: #{cond.inspect}"
  end
end

# Each workflow-level output is an expression over `jobs.<id>.outputs.<k>`. A
# job id that does not exist there is not an error: the output is the empty
# string, and every caller condition reading it goes quietly false.
CALLED.each do |name, path|
  outputs = (triggers(called_wf[name]).fetch("workflow_call")["outputs"] || {})
  ids = called_wf[name].fetch("jobs").keys
  dangling = outputs.filter_map do |k, spec|
    refs = spec["value"].to_s.scan(/jobs\.([a-z0-9_-]+)\.outputs/).flatten
    [k, refs - ids] if (refs - ids).any?
  end
  next if outputs.empty?
  if dangling.empty?
    pass "#{path}: all #{outputs.size} workflow outputs read jobs that exist"
  else
    fail "#{path}: all workflow outputs read jobs that exist", "dangling: #{dangling.inspect}"
  end
end

puts "== Part 8: the caller grants at least the permissions the callee's jobs ask for =="

RANK = { "none" => 0, "read" => 1, "write" => 2 }

CALLED.each do |name, path|
  granted = caller_jobs[name]["permissions"] || {}
  needed = {}
  called_wf[name].fetch("jobs").each_value do |j|
    (j["permissions"] || {}).each do |scope, level|
      needed[scope] = level if RANK.fetch(level, 0) > RANK.fetch(needed[scope], -1)
    end
  end
  short = needed.reject { |scope, level| RANK.fetch(granted[scope], 0) >= RANK.fetch(level, 0) }
  if short.empty?
    pass "#{path}: caller grants #{needed.inspect}"
  else
    # A called workflow cannot widen what the caller job grants. This fails at
    # the push, after the image is built - forty minutes of runner time for a
    # 403.
    fail "#{path}: caller grants what the callee's jobs ask for",
         "granted #{granted.inspect}, short of #{short.inspect}"
  end
end

puts ""
puts "== Part 9: no workflow is back over the line limit =="

Dir[".github/workflows/*.yml"].sort.each do |path|
  n = File.readlines(path, encoding: "UTF-8").size
  if n <= LINE_LIMIT
    pass "#{path}: #{n} lines"
  else
    fail "#{path}: #{n} lines exceeds the #{LINE_LIMIT}-line limit",
         "This is RC-8 returning: split it by family, as release.yml was."
  end
end

puts ""
puts "passed: #{$pass}"
puts "failed: #{$fail}"
exit($fail.zero? ? 0 : 1)
RUBY
