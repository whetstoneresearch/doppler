---
name: fix-review
description: Reviews commits for bug introduction and verifies audit finding remediation
argument-hint: "<source-commit> <target-commit(s)> [--report <path-or-url>]"
allowed-tools:
  - Read
  - Write
  - Grep
  - Glob
  - Bash
  - WebFetch
  - Task
---

# Fix Review Command

Verify that commits address security audit findings without introducing bugs.

**Arguments:** $ARGUMENTS

## Argument Parsing

Parse the provided arguments:

1. **Source commit** (required): First argument - baseline commit before fixes
2. **Target commit(s)** (required): One or more commits to analyze
3. **Report** (optional): `--report <path-or-url>` - Security audit report

**Examples:**
```
/fix-review abc123 def456
# Source: abc123, Target: def456, No report

/fix-review main fix-branch --report ./audit-report.pdf
# Source: main, Target: fix-branch, Report: ./audit-report.pdf

/fix-review v1.0.0 commit1 commit2 commit3 --report https://example.com/report.md
# Source: v1.0.0, Targets: commit1, commit2, commit3, Report: URL
```

## Workflow

### Step 1: Validate Inputs

Verify the commits exist:

```bash
git rev-parse <source-commit>
git rev-parse <target-commit>
```

If validation fails, report the error and ask for correct commit references.

### Step 2: Retrieve Report (if provided)

**Local file:**
```
Read <path>
```

**URL:**
```
WebFetch <url>
```

**Google Drive URL that fails:**
1. Check for gdrive: `which gdrive`
2. If available: Extract file ID and download
3. If not available: Instruct user to download manually

```bash
# Check gdrive availability
if command -v gdrive &> /dev/null && gdrive about &> /dev/null 2>&1; then
    # Extract file ID from URL
    FILE_ID=$(echo "<url>" | grep -oP '(?:file/d/|document/d/|id=)[^/&]+' | sed 's/.*[=/]//')
    gdrive files download "$FILE_ID" --path /tmp/
else
    echo "gdrive not available"
fi
```

If gdrive is unavailable:
```
Unable to access the Google Drive URL directly. Please either:
1. Download the file and provide the local path
2. Install and configure gdrive: brew install gdrive && gdrive about
```

### Step 3: Extract Findings (if report provided)

Parse the report to identify findings:

**Trail of Bits format:** Look for `TOB-[A-Z]+-[0-9]+` pattern in "Detailed Findings" section

**Other formats:** Look for numbered findings, severity sections, or JSON structure

Create a findings list with:
- ID
- Title
- Severity
- Affected files
- Description summary

### Step 4: Analyze Commits

For each target commit:

```bash
# Get commit range
git log <source>..<target> --oneline

# Get full diff
git diff <source>..<target>

# Get changed files
git diff <source>..<target> --name-only
```

Analyze each commit for:
- Bug introduction patterns (validation removal, access control changes, etc.)
- Security anti-patterns
- Changes that may address findings

### Step 5: Match Findings to Commits

For each finding from the report:

1. Search for commits touching relevant files
2. Check if changes address the finding's root cause
3. Assign status: FIXED, PARTIALLY_FIXED, NOT_ADDRESSED, CANNOT_DETERMINE
4. Document evidence (commit hash, file, lines)

### Step 6: Generate Report

Create `FIX_REVIEW_REPORT.md` with:

```markdown
# Fix Review Report

**Source:** <commit>
**Target:** <commit>
**Report:** <path or "none">
**Date:** <current date>

## Executive Summary

Reviewed X commits from <source> to <target>.
- Findings addressed: Y of Z
- Bug introduction concerns: N

## Finding Status

| ID | Title | Severity | Status | Evidence |
|----|-------|----------|--------|----------|
| ... | ... | ... | ... | ... |

## Bug Introduction Concerns

[List any potential bugs detected in the changes]

## Per-Commit Analysis

### Commit <hash>: "<message>"

**Files:** <list>
**Findings addressed:** <IDs or "none">
**Concerns:** <list or "none">

[Analysis details]

## Recommendations

[Follow-up actions needed]
```

### Step 7: Provide Summary

After generating the report, provide a conversation summary:

```
## Fix Review Complete

**Report:** FIX_REVIEW_REPORT.md

**Summary:**
- Commits analyzed: X
- Findings in report: Y
- FIXED: Z
- PARTIALLY_FIXED: W
- NOT_ADDRESSED: V
- Bug concerns: N

[Brief highlights of key findings]
```

## Usage Tips

- **Specific commits:** Use full commit hashes for precision
- **Branch names:** Can use branch names (e.g., `main`, `fix-branch`)
- **Tags:** Can use tags (e.g., `v1.0.0`, `audit-baseline`)
- **Multiple targets:** Analyze multiple fix commits against same baseline
- **Report formats:** Supports PDF, Markdown, JSON, HTML

## Error Handling

**Invalid commit:**
```
Error: Could not resolve commit '<ref>'
Please provide a valid commit hash, branch name, or tag.
```

**Report not found:**
```
Error: Could not access report at '<path>'
Please verify the path/URL is correct and accessible.
```

**No changes found:**
```
No changes found between <source> and <target>.
These commits may be identical or the range may be inverted.
```

## Integration

This command uses the `fix-review` skill for detailed analysis guidance.
For comprehensive security review (not just fix verification), use `differential-review`.
