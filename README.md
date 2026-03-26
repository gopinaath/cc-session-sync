# Claude Code Session Sync PoC

Tooling to push Claude Code session state to GitHub and restore it on a different machine, enabling cross-machine session continuity.

## Problem

There is no built-in way to continue a Claude Code session on a different machine. `claude --continue` only works locally.

## Solution

Scripts + CloudFormation infrastructure to sync session artifacts via GitHub between two EC2 Ubuntu instances.

```
Machine A (/home/ubuntu/project)          Machine B (/home/ubuntu/project)
  claude session running                     clone project repo
  ~/.claude/projects/...                     cc-pull.sh → restore ~/.claude/...
  cc-push.sh → GitHub                       claude --continue ✓
        ↓                                         ↑
   [GitHub: project-repo]  ←──────────────────────┘
   [GitHub: session-state-repo]  ←────────────────┘
```

## Quick Start

### Prerequisites

- AWS CLI configured with appropriate permissions
- GitHub CLI (`gh`) authenticated
- An EC2 key pair in your target region

### 1. Create GitHub repos

```bash
./scripts/setup-github-repos.sh <your-github-username>
```

### 2. Deploy infrastructure

```bash
./infra/deploy.sh <key-pair-name>
```

### 3. Run end-to-end test

```bash
./test/e2e-test.sh <path-to-key.pem> <github-username>
```

### Manual usage (on any two machines with identical paths)

Push session state from Machine A:
```bash
./scripts/cc-push.sh [--dry-run] [--no-scan] /home/ubuntu/project git@github.com:user/cc-sync-test-state.git
```

Pull and restore on Machine B:
```bash
./scripts/cc-pull.sh /home/ubuntu/project git@github.com:user/cc-sync-test-state.git
```

Then on Machine B:
```bash
cd /home/ubuntu/project && claude --continue
```

## File Structure

```
├── infra/
│   ├── cfn-template.yaml    # CloudFormation: 2 EC2 instances, IAM, security groups
│   ├── deploy.sh             # Deploy the stack
│   └── teardown.sh           # Delete the stack
├── scripts/
│   ├── cc-push.sh            # Push session state to GitHub
│   ├── cc-pull.sh            # Pull and restore session state
│   ├── setup-github-repos.sh # Create test GitHub repos
│   └── install-claude.sh     # Install Claude Code on EC2
├── test/
│   ├── e2e-test.sh           # End-to-end test orchestrator
│   ├── seed-session.sh       # Create a test session with known interactions
│   └── validate-continue.sh  # Verify --continue works after restore
```

## What Gets Synced

| Path | Required | Purpose |
|------|----------|---------|
| `projects/<enc>/sessions-index.json` | **Yes** | `--continue` reads this to find the latest session |
| `projects/<enc>/<session-id>.jsonl` | **Yes** | Conversation transcript |
| `projects/<enc>/<session-id>/subagents/` | Recommended | Subagent threads |
| `projects/<enc>/<session-id>/tool-results/` | Optional | Cached tool outputs |
| `file-history/<session-id>/` | Optional | File edit undo history |
| `tasks/<session-id>/` | Optional | Task list state |
| `plans/*.md` | Optional | Plan files |

**Never synced**: `settings.json`, `debug/`, `cache/`, `session-env/`, `ide/`

## Dry Run

Both sync scripts support `--dry-run` to preview what would be transferred:

```bash
./scripts/cc-push.sh --dry-run /home/ubuntu/project <state-repo-url>
./scripts/cc-pull.sh --dry-run /home/ubuntu/project <state-repo-url>
```

## Secret Scanning

`cc-push.sh` scans staged files for secrets before pushing. Session JSONL files can capture credentials from tool output (e.g., `aws sts get-caller-identity`), `.env` reads, or user-pasted keys.

The scan runs two complementary checks:

1. **[gitleaks](https://github.com/gitleaks/gitleaks)** (if installed) — ~150 built-in rules for context-aware detection (generic API keys, high-entropy strings, Slack tokens, private key files, etc.)
2. **Built-in grep patterns** (always runs) — catches specific token formats that gitleaks misses in JSONL context: AWS keys (`AKIA`/`ASIA`), GitHub tokens (`ghp_`/`gho_`/`ghs_`/`github_pat_`), Anthropic keys (`sk-ant-`), OpenAI/Stripe keys (`sk-`), SSH private keys, Slack tokens, and email addresses.

Neither check is exhaustive on its own — together they provide broad coverage. Install gitleaks for best results.

- `--no-scan` — skip the scan entirely
- `.cc-push-scanignore` — place in the project root with one pattern per line to suppress grep false positives (matched via `grep -vF`). For gitleaks, use a `.gitleaks.toml` allowlist.

## Phase 1 Limitations

- Both machines must use **identical project paths** (e.g., `/home/ubuntu/project`)
- No path rewriting — session JSONL references absolute paths
- Last-push-wins — no locking or merge for concurrent edits
- GitHub's 100MB file limit may block very large sessions (need Git LFS)

## Phase 2 (Future)

- Path rewriting for different usernames/directories
- Incremental sync (only new JSONL lines)
- Git LFS for large sessions
- Bidirectional merge
- Memory directory sync
