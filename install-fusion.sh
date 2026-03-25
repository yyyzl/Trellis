#!/bin/bash
# install-fusion.sh — Install Fusion skills into any Trellis project
#
# Usage:
#   ./install-fusion.sh /path/to/target/project
#   ./install-fusion.sh .                          # install into current dir
#
# Prerequisites:
#   - Target project must already have Trellis initialized (trellis init)
#   - This script copies files; it does not modify existing Trellis commands
#
# What it does:
#   1. Copies 6 Fusion skills into .agents/skills/
#   2. Copies 6 Fusion commands into .claude/commands/fusion/
#   3. Copies workflow documentation into .trellis/
#   4. Appends update.skip entries to .trellis/config.yaml

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TARGET="${1:-.}"

# Resolve to absolute path
TARGET="$(cd "$TARGET" && pwd)"

echo "=== Fusion Trellis Installer ==="
echo "Source: $SCRIPT_DIR"
echo "Target: $TARGET"
echo ""

# Verify target has Trellis
if [ ! -d "$TARGET/.trellis" ]; then
  echo "ERROR: $TARGET does not appear to have Trellis initialized."
  echo "Run 'trellis init' in the target project first."
  exit 1
fi

# --- Skills ---
echo "[1/4] Copying Fusion skills..."
SKILLS=(
  brainstorm-plus
  write-task-plan
  execute-plan-tdd
  harvest-learnings
  systematic-debugging
  review-with-agents
)

mkdir -p "$TARGET/.agents/skills"
for skill in "${SKILLS[@]}"; do
  if [ -d "$SCRIPT_DIR/.agents/skills/$skill" ]; then
    cp -r "$SCRIPT_DIR/.agents/skills/$skill" "$TARGET/.agents/skills/"
    echo "  + $skill"
  else
    echo "  ! $skill not found in source, skipping"
  fi
done

# --- Commands ---
echo "[2/4] Copying Fusion commands..."
mkdir -p "$TARGET/.claude/commands/fusion"
if [ -d "$SCRIPT_DIR/.claude/commands/fusion" ]; then
  cp "$SCRIPT_DIR/.claude/commands/fusion/"*.md "$TARGET/.claude/commands/fusion/"
  echo "  + $(ls "$SCRIPT_DIR/.claude/commands/fusion/"*.md | wc -l) command files"
else
  echo "  ! Source fusion commands directory not found"
fi

# --- Documentation ---
echo "[3/4] Copying workflow documentation..."
DOCS=(
  fusion-workflow.md
  fusion-workflow-quickref.md
  custom-trellis-maintenance.md
)

for doc in "${DOCS[@]}"; do
  if [ -f "$SCRIPT_DIR/.trellis/$doc" ]; then
    cp "$SCRIPT_DIR/.trellis/$doc" "$TARGET/.trellis/"
    echo "  + $doc"
  fi
done

# Copy FORK_CHANGELOG.md to root
if [ -f "$SCRIPT_DIR/FORK_CHANGELOG.md" ]; then
  cp "$SCRIPT_DIR/FORK_CHANGELOG.md" "$TARGET/"
  echo "  + FORK_CHANGELOG.md (root)"
fi

# --- Config update ---
echo "[4/4] Checking config.yaml for update.skip entries..."
CONFIG="$TARGET/.trellis/config.yaml"

if [ -f "$CONFIG" ]; then
  NEEDS_UPDATE=false

  for skill in "${SKILLS[@]}"; do
    if ! grep -q ".agents/skills/$skill/" "$CONFIG" 2>/dev/null; then
      NEEDS_UPDATE=true
      break
    fi
  done

  if ! grep -q ".claude/commands/fusion/" "$CONFIG" 2>/dev/null; then
    NEEDS_UPDATE=true
  fi

  if [ "$NEEDS_UPDATE" = true ]; then
    echo ""
    echo "  WARNING: Your config.yaml may need update.skip entries for Fusion files."
    echo "  Add the following to your .trellis/config.yaml under update.skip:"
    echo ""
    echo "  update:"
    echo "    skip:"
    echo "      - .claude/commands/fusion/"
    for skill in "${SKILLS[@]}"; do
      echo "      - .agents/skills/$skill/"
    done
    echo ""
    echo "  This prevents 'trellis update' from removing Fusion files."
  else
    echo "  config.yaml already has Fusion skip entries"
  fi
else
  echo "  ! config.yaml not found at $CONFIG"
fi

echo ""
echo "=== Installation complete ==="
echo ""
echo "Fusion commands available in Claude Code:"
echo "  /fusion:brainstorm-plus"
echo "  /fusion:write-task-plan"
echo "  /fusion:execute-plan-tdd"
echo "  /fusion:harvest-learnings"
echo "  /fusion:systematic-debugging"
echo "  /fusion:review-with-agents"
echo ""
echo "Fusion skills available in Codex:"
echo "  \$brainstorm-plus"
echo "  \$write-task-plan"
echo "  \$execute-plan-tdd"
echo "  \$harvest-learnings"
echo "  \$systematic-debugging"
echo "  \$review-with-agents"
echo ""
echo "See .trellis/fusion-workflow.md for usage guide."
