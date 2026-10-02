#!/bin/bash
# ============================================================
# verzth/skills — Installer
#
# Install all:        curl -fsSL https://raw.githubusercontent.com/verzth/skills/main/install.sh | bash
# Install one:        curl -fsSL https://raw.githubusercontent.com/verzth/skills/main/install.sh | bash -s -- humanoid-thinking
# Install many:       curl -fsSL https://raw.githubusercontent.com/verzth/skills/main/install.sh | bash -s -- humanoid-thinking public-awareness
# Install (OpenClaw): curl -fsSL https://raw.githubusercontent.com/verzth/skills/main/install.sh | bash -s -- --openclaw public-awareness
# Install (Hermes):   curl -fsSL https://raw.githubusercontent.com/verzth/skills/main/install.sh | bash -s -- --hermes public-awareness
# ============================================================

set -e

REPO="verzth/skills"
REPO_URL="https://github.com/$REPO"
RAW_BASE="https://raw.githubusercontent.com/$REPO/main"

# All available skills (update when adding new skills)
ALL_SKILLS=(
    "humanoid-thinking"
    "golang-developer"
    "pm-thinking"
    "em-thinking"
    "public-awareness"
    "board-thinking"
    "cso-thinking"
    "mockerize"
)

# Parse flags
OPENCLAW=false
HERMES=false
REMAINING_ARGS=()
for arg in "$@"; do
    if [ "$arg" = "--openclaw" ] || [ "$arg" = "-o" ]; then
        OPENCLAW=true
    elif [ "$arg" = "--hermes" ] || [ "$arg" = "-H" ]; then
        HERMES=true
    else
        REMAINING_ARGS+=("$arg")
    fi
done

if [ "$OPENCLAW" = true ] && [ "$HERMES" = true ]; then
    echo "❌ --openclaw and --hermes are mutually exclusive. Run twice if you want both." >&2
    exit 1
fi

# Detect target directory
if [ "$OPENCLAW" = true ]; then
    if [ -d ".openclaw/skills" ]; then
        BASE_TARGET=".openclaw/skills"
    elif [ -d "$HOME/.openclaw/skills" ]; then
        BASE_TARGET="$HOME/.openclaw/skills"
    else
        BASE_TARGET="$HOME/.openclaw/skills"
        mkdir -p "$BASE_TARGET"
    fi
    echo "🦅 OpenClaw mode — installing to $BASE_TARGET/"
elif [ "$HERMES" = true ]; then
    if [ -d ".hermes/skills" ]; then
        BASE_TARGET=".hermes/skills"
    elif [ -d "$HOME/.hermes/skills" ]; then
        BASE_TARGET="$HOME/.hermes/skills"
    else
        BASE_TARGET="$HOME/.hermes/skills"
        mkdir -p "$BASE_TARGET"
    fi
    echo "🪽 Hermes mode — installing to $BASE_TARGET/"
else
    if [ -d ".claude/skills" ]; then
        BASE_TARGET=".claude/skills"
    elif [ -d "$HOME/.claude/skills" ]; then
        BASE_TARGET="$HOME/.claude/skills"
    else
        BASE_TARGET=".claude/skills"
        mkdir -p "$BASE_TARGET"
    fi
fi

# Resolve the destination before entering temporary checkout directories.
if [[ "$BASE_TARGET" != /* ]]; then
    BASE_TARGET="$(pwd)/${BASE_TARGET#./}"
fi

# Determine which skills to install
REQUESTED_SKILLS=("${REMAINING_ARGS[@]}")
if [ ${#REQUESTED_SKILLS[@]} -eq 0 ]; then
    REQUESTED_SKILLS=("${ALL_SKILLS[@]}")
    echo "📦 Installing ALL skills from $REPO..."
else
    echo "📦 Installing selected skills from $REPO..."
fi

echo "   Target: $BASE_TARGET/"
echo ""

# Try git sparse checkout first (most efficient for mono-repo)
install_via_git() {
    local skill=$1
    local target="$BASE_TARGET/$skill"
    local tmp_dir=$(mktemp -d)

    if (
        cd "$tmp_dir"
        git init -q
        git remote add origin "$REPO_URL.git"
        git config core.sparseCheckout true
        echo "skills/$skill/" > .git/info/sparse-checkout
        git pull -q --depth 1 origin main 2>/dev/null

        [ -d "skills/$skill" ]
        rm -rf "$target"
        mkdir -p "$(dirname "$target")"
        cp -R "skills/$skill" "$target"
    ); then
        rm -rf "$tmp_dir"
        return 0
    fi

    rm -rf "$tmp_dir"
    return 1
}

# Fallback: download via curl using manifest
install_via_curl() {
    local skill=$1
    local target="$BASE_TARGET/$skill"
    local manifest_url="$RAW_BASE/skills/$skill/MANIFEST"

    rm -rf "$target"

    local manifest
    manifest=$(curl -fsSL "$manifest_url" 2>/dev/null) || {
        mkdir -p "$target/references"
        curl -fsSL "$RAW_BASE/skills/$skill/SKILL.md" -o "$target/SKILL.md" 2>/dev/null || return 1
        curl -fsSL "$RAW_BASE/skills/$skill/personality.md" -o "$target/personality.md" 2>/dev/null || true
        curl -fsSL "$RAW_BASE/skills/$skill/references/onboarding.md" -o "$target/references/onboarding.md" 2>/dev/null || true
        find "$target" -type d -empty -delete 2>/dev/null || true
        return 0
    }

    mkdir -p "$target"
    while IFS= read -r file; do
        [ -z "$file" ] && continue
        [[ "$file" == \#* ]] && continue
        local dir=$(dirname "$file")
        [ "$dir" != "." ] && mkdir -p "$target/$dir"
        curl -fsSL "$RAW_BASE/skills/$skill/$file" -o "$target/$file" || return 1
    done <<< "$manifest"

    return 0
}

# Backup personality files before install
backup_personality() {
    local skill=$1
    local target="$BASE_TARGET/$skill"
    if [ -f "$target/personality.md" ]; then
        local status=$(grep "^status:" "$target/personality.md" 2>/dev/null | head -1)
        if [[ "$status" == *"configured"* ]]; then
            cp "$target/personality.md" "/tmp/${skill}-personality-$(date +%s).md"
            echo "   💾 Backed up personality.md"
            return 0
        fi
    fi
    return 1
}

# Restore personality after install
restore_personality() {
    local skill=$1
    local target="$BASE_TARGET/$skill"
    local backup=$(ls -t /tmp/${skill}-personality-*.md 2>/dev/null | head -1)
    if [ -n "$backup" ] && [ -f "$backup" ]; then
        cp "$backup" "$target/personality.md"
        echo "   🔄 Restored personality settings"
    fi
}

# Install each skill
SUCCESS=0
FAIL=0
for skill in "${REQUESTED_SKILLS[@]}"; do
    echo "── $skill"

    KNOWN_SKILL=false
    for available_skill in "${ALL_SKILLS[@]}"; do
        if [ "$skill" = "$available_skill" ]; then
            KNOWN_SKILL=true
            break
        fi
    done

    if [ "$KNOWN_SKILL" = false ]; then
        echo "   ❌ Unknown skill"
        FAIL=$((FAIL + 1))
        continue
    fi

    if ! curl -fsSL "$RAW_BASE/skills/$skill/SKILL.md" -o /dev/null 2>/dev/null &&
       ! curl -fsSL "$RAW_BASE/skills/$skill/.claude-plugin/plugin.json" -o /dev/null 2>/dev/null; then
        echo "   ❌ Skill not found in published repository"
        FAIL=$((FAIL + 1))
        continue
    fi

    HAS_BACKUP=false
    backup_personality "$skill" && HAS_BACKUP=true

    if command -v git &> /dev/null && install_via_git "$skill" 2>/dev/null; then
        echo "   ✅ Installed (via git)"
    elif install_via_curl "$skill"; then
        echo "   ✅ Installed (via curl)"
    else
        echo "   ❌ Failed to install"
        FAIL=$((FAIL + 1))
        continue
    fi

    [ "$HAS_BACKUP" = true ] && restore_personality "$skill"

    SUCCESS=$((SUCCESS + 1))
done

echo ""
echo "════════════════════════════════════"
echo "  ✅ Installed: $SUCCESS"
[ $FAIL -gt 0 ] && echo "  ❌ Failed: $FAIL"
echo "  📁 Location: $BASE_TARGET/"
if [ "$OPENCLAW" = true ]; then
    echo "  Note: For full content adaptation (tool rewrites), use:"
    echo "        npx @verzth/skills install <skill> --openclaw"
elif [ "$HERMES" = true ]; then
    echo "  Hermes loads SKILL.md natively — no content adaptation needed."
    echo "  Alternative install via Hermes CLI:"
    echo "        hermes skills install github:verzth/skills/skills/<name>"
fi
echo "════════════════════════════════════"

if [ "$FAIL" -gt 0 ]; then
    exit 1
fi
