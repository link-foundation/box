# Data Collection: Issue #46 CI/CD Failure

## Raw Data Sources

### CI Run Information

- **Workflow Run URL**: https://github.com/link-foundation/box/actions/runs/22261112919/job/64399507098
- **Run ID**: 22261112919
- **Job ID**: 64399507098
- **Job Name**: "Measure Component Disk Space"
- **Workflow**: "Measure Disk Space and Update README"
- **Runner**: ubuntu-24.04 (version 20260201.15.1)
- **Commit**: 38673b0f4aa8c91069a9473a5df1d157c8522584 (main branch)
- **Trigger**: Push to main

### Log Collection Commands

```bash
# List recent runs
gh run list --repo link-foundation/box --limit 5 --json databaseId,conclusion,createdAt,headSha

# Download run logs
gh run view 22261112919 --repo link-foundation/box --log > ci-logs/measure-disk-space-22261112919.log

# View specific job
gh run view 22261112919 --repo link-foundation/box --job 64399507098
```

## Key Log Excerpts

### Error Occurrence (Lines 1618-1619 of full log)

```
2026-02-21T17:32:58.8658778Z cat: data/disk-space-measurements.json: No such file or directory
2026-02-21T17:32:58.8708101Z ##[error]Process completed with exit code 1.
```

### JSON Initialization (Line 254 of full log)

```
2026-02-21T17:31:26.0172612Z [*] Initialized JSON output at data/disk-space-measurements.json
```

### Context Switch to Box User (Lines 1598-1617)

```
2026-02-21T17:32:57.2186148Z [✓] Recorded: GitLab CLI - 27MB
2026-02-21T17:32:57.2186516Z
2026-02-21T17:32:57.2186621Z ==> Preparing Homebrew Directory
...
2026-02-21T17:32:57.2266635Z ==> Measuring Box User Installations
...
2026-02-21T17:32:57.4165096Z [*] Measuring: Bun
2026-02-21T17:32:58.0291267Z #=#=#
2026-02-21T17:32:58.0292030Z
2026-02-21T17:32:58.0480819Z #########################################################                 80.3%
2026-02-21T17:32:58.0481863Z ######################################################################## 100.0%
2026-02-21T17:32:58.8174069Z bun was installed successfully to ~/.bun/bin/bun
2026-02-21T17:32:58.8182037Z
2026-02-21T17:32:58.8235749Z Added "~/.bun/bin" to $PATH in "~/.bash_profile"
2026-02-21T17:32:58.8236217Z
2026-02-21T17:32:58.8237067Z To get started, run:
2026-02-21T17:32:58.8237409Z
2026-02-21T17:32:58.8284531Z   source /home/box/.bash_profile
2026-02-21T17:32:58.8285158Z   bun --help
2026-02-21T17:32:58.8658778Z cat: data/disk-space-measurements.json: No such file or directory
2026-02-21T17:32:58.8708101Z ##[error]Process completed with exit code 1.
```

### Workflow Step Command (Lines 224-246)

```
2026-02-21T17:31:25.9988774Z ##[group]Run set -o pipefail
2026-02-21T17:31:25.9991794Z sudo ./scripts/measure-disk-space.sh --json-output data/disk-space-measurements.json 2>&1 | tee measurement.log
```

## Environment

### Runner Configuration

| Property | Value |
|----------|-------|
| OS | Ubuntu 24.04.3 LTS |
| Runner Version | 2.331.0 |
| Image Version | 20260201.15.1 |
| Azure Region | westus |
| Initial Disk Space | 145G total, 53G used, 92G available |

### Disk Space After Free-up Step

```
2026-02-21T17:31:26.0172612Z Baseline disk usage: 33541MB
```

Directories removed:
- `/usr/share/dotnet`
- `/usr/local/lib/android`
- `/opt/ghc`
- `/opt/hostedtoolcache`
- `/usr/local/share/boost`
- `$AGENT_TOOLSDIRECTORY`

## Script Analysis

### `scripts/measure-disk-space.sh` Key Sections

**Argument Parsing (lines 13-16)**:
```bash
JSON_OUTPUT_FILE="${1:-/tmp/disk-space-measurements.json}"
if [[ "$1" == "--json-output" ]] && [[ -n "${2:-}" ]]; then
  JSON_OUTPUT_FILE="$2"
fi
```
The path `data/disk-space-measurements.json` is stored as-is (relative).

**JSON Initialization (lines 85-94)**:
```bash
init_json_output() {
  cat > "$JSON_OUTPUT_FILE" << 'EOF'
{...}
EOF
  log_info "Initialized JSON output at $JSON_OUTPUT_FILE"
}
```
File created successfully at the relative path — works because CWD is the runner's workspace.

**Box User Execution (lines 644-649)**:
```bash
if [ "$EUID" -eq 0 ]; then
  su - box -c "bash /tmp/box-measure.sh '$JSON_OUTPUT_FILE'"
else
  sudo -i -u box bash /tmp/box-measure.sh "$JSON_OUTPUT_FILE"
fi
```
The `-` flag to `su` and `-i` flag to `sudo` both create login shells, changing CWD to `/home/box`.

**box-measure.sh `add_measurement` (lines 335-353)**:
```bash
add_measurement() {
  local current_json
  current_json=$(cat "$JSON_OUTPUT_FILE")  # <-- FAILS: reads wrong path
  ...
  echo "$current_json" > "$JSON_OUTPUT_FILE"  # Would also fail
  ...
}
```

## Proof of Root Cause

The evidence chain:

1. **JSON initialized at relative path** in runner's CWD (`/home/runner/work/box/box/data/disk-space-measurements.json`) — log line 254 confirms this.

2. **`su - box` changes CWD** to `/home/box` — this is documented behavior of login shells.

3. **First read of JSON fails** in box-measure.sh's `add_measurement`, which runs after `install_bun` succeeds — log lines 1605-1618 show Bun installing successfully before the error.

4. **No other errors** in the log between GitLab CLI recording and the JSON error — confirming no other failure points.

## Files Collected

| File | Description |
|------|-------------|
| `ci-run-log.txt` | Full CI run log (1633 lines, 198KB) |
| `issue-46-raw.json` | Raw GitHub issue JSON |
| `pr-47-raw.json` | Raw PR #47 JSON |
| `pr-47-conversation-comments.json` | PR conversation comments (empty) |
| `pr-47-review-comments.json` | PR review comments (empty) |
| `issue-46-comments.json` | Issue comments (empty) |
