#!/usr/bin/env node

const fs = require("fs");
const path = require("path");

// ── Config ──────────────────────────────────────────────
const PACKAGE_ROOT = path.resolve(__dirname, "..");
const SKILLS_DIR = path.join(PACKAGE_ROOT, "skills");
const VERSION = require(path.join(PACKAGE_ROOT, "package.json")).version;

// ── Colors (no dependencies) ────────────────────────────
const c = {
  reset: "\x1b[0m",
  bold: "\x1b[1m",
  dim: "\x1b[2m",
  green: "\x1b[32m",
  yellow: "\x1b[33m",
  red: "\x1b[31m",
  cyan: "\x1b[36m",
  magenta: "\x1b[35m",
};

// ── Helpers ─────────────────────────────────────────────

function detectSkillType(skillName) {
  const skillRoot = path.join(SKILLS_DIR, skillName);
  if (!fs.existsSync(skillRoot)) return null;

  const hasSkillMd = fs.existsSync(path.join(skillRoot, "SKILL.md"));
  const hasPluginManifest = fs.existsSync(
    path.join(skillRoot, ".claude-plugin", "plugin.json")
  );

  if (hasSkillMd) return "single";
  if (hasPluginManifest) return "bundle";
  return null;
}

function getAvailableSkills() {
  if (!fs.existsSync(SKILLS_DIR)) return [];
  return fs
    .readdirSync(SKILLS_DIR)
    .filter((name) => detectSkillType(name) !== null)
    .sort();
}

function getSkillDescription(skillName) {
  const type = detectSkillType(skillName);

  if (type === "single") {
    const skillMd = path.join(SKILLS_DIR, skillName, "SKILL.md");
    const content = fs.readFileSync(skillMd, "utf-8");
    const match = content.match(/description:\s*>?\s*\n?([\s\S]*?)(?=\n---|\n\w+:)/);
    if (match) {
      return match[1].trim().split("\n")[0].trim().slice(0, 80);
    }
    return "";
  }

  if (type === "bundle") {
    const pluginJson = path.join(
      SKILLS_DIR,
      skillName,
      ".claude-plugin",
      "plugin.json"
    );
    try {
      const manifest = JSON.parse(fs.readFileSync(pluginJson, "utf-8"));
      const subSkillsDir = path.join(SKILLS_DIR, skillName, "skills");
      let subSkillCount = 0;
      if (fs.existsSync(subSkillsDir)) {
        subSkillCount = fs
          .readdirSync(subSkillsDir)
          .filter((sub) =>
            fs.existsSync(path.join(subSkillsDir, sub, "SKILL.md"))
          ).length;
      }
      const bundleSuffix = subSkillCount > 0 ? ` [bundle: ${subSkillCount} skills]` : " [bundle]";
      return (manifest.description || "").slice(0, 80 - bundleSuffix.length) + bundleSuffix;
    } catch {
      return "[bundle]";
    }
  }

  return "";
}

function getGlobalDir() {
  return path.join(
    process.env.HOME || process.env.USERPROFILE || "~",
    ".claude",
    "skills"
  );
}

function getProjectDir() {
  return path.join(process.cwd(), ".claude", "skills");
}

function getOpenClawGlobalDir() {
  return path.join(
    process.env.HOME || process.env.USERPROFILE || "~",
    ".openclaw",
    "skills"
  );
}

function getOpenClawProjectDir() {
  return path.join(process.cwd(), ".openclaw", "skills");
}

function getHermesGlobalDir() {
  return path.join(
    process.env.HOME || process.env.USERPROFILE || "~",
    ".hermes",
    "skills"
  );
}

function getHermesProjectDir() {
  return path.join(process.cwd(), ".hermes", "skills");
}

// ── OpenClaw content transformer ────────────────────────

// Applied longest-first to avoid partial replacements.
const TOOL_REWRITES = [
  ["use the Bash tool", "use the exec tool"],
  ["use the Write tool", "use the write tool"],
  ["use the Read tool", "use the read tool"],
  ["use the Edit tool", "use the edit tool"],
  ["use the Agent tool", "use sessions_spawn"],
  ["Use AskUserQuestion", "Ask the user directly"],
  ["use AskUserQuestion", "ask the user directly"],
  ["the Bash tool", "the exec tool"],
  ["the Write tool", "the write tool"],
  ["the Read tool", "the read tool"],
  ["the Edit tool", "the edit tool"],
  ["the Agent tool", "sessions_spawn"],
  ["Agent tool", "sessions_spawn"],
  ["AskUserQuestion", "ask the user directly in chat"],
  ["subagent_type", "task parameter"],
  ["TodoWrite", "task tracker"],
  ["CLAUDE.md", "AGENTS.md"],
];

const PATH_REWRITES = [
  ["~/.claude/skills", "~/.openclaw/skills"],
  ["~/.claude/projects", "~/.openclaw/projects"],
  ["~/.claude/", "~/.openclaw/"],
  [".claude/skills", ".openclaw/skills"],
  [".claude/", ".openclaw/"],
];

function transformFrontmatter(fmContent, version) {
  // Parse top-level YAML fields by tracking indentation.
  // A new field starts when a line matches /^\w+:/ (no leading whitespace).
  const lines = fmContent.split("\n");
  const fields = {};
  let currentField = null;
  let currentLines = [];

  const flush = () => {
    if (currentField) fields[currentField] = currentLines.join("\n");
  };

  for (const line of lines) {
    const topLevel = line.match(/^(\w[\w-]*):/);
    if (topLevel && !line.startsWith(" ") && !line.startsWith("\t")) {
      flush();
      currentField = topLevel[1];
      currentLines = [line];
    } else if (currentField) {
      currentLines.push(line);
    }
  }
  flush();

  const parts = [];
  if (fields.name) parts.push(fields.name);
  if (fields.description) parts.push(fields.description);
  parts.push(`version: ${version}`);
  return parts.join("\n");
}

function transformForOpenClaw(content, version) {
  let result = content;

  // 1. Tool + keyword rewrites (applied to full content incl. frontmatter description)
  for (const [from, to] of TOOL_REWRITES) {
    result = result.split(from).join(to);
  }

  // 2. Path rewrites
  for (const [from, to] of PATH_REWRITES) {
    result = result.split(from).join(to);
  }

  // 3. Frontmatter: strip extra fields, add version
  result = result.replace(/^(---\n)([\s\S]*?)(\n---)/, (_match, open, fmContent, close) => {
    return open + transformFrontmatter(fmContent, version) + close;
  });

  return result;
}

// ── Directory resolution ─────────────────────────────────

function resolveTargetDir(args, hostMode) {
  let globalDir = getGlobalDir();
  let projectDir = getProjectDir();
  let host = "Claude";
  let dotDir = ".claude";

  if (hostMode === "openclaw") {
    globalDir = getOpenClawGlobalDir();
    projectDir = getOpenClawProjectDir();
    host = "OpenClaw";
    dotDir = ".openclaw";
  } else if (hostMode === "hermes") {
    globalDir = getHermesGlobalDir();
    projectDir = getHermesProjectDir();
    host = "Hermes";
    dotDir = ".hermes";
  }

  if (args.includes("-g") || args.includes("--global")) {
    return { target: globalDir, scope: "global" };
  }
  if (args.includes("-p") || args.includes("--project")) {
    return { target: projectDir, scope: "project" };
  }

  if (process.stdin.isTTY) {
    const readline = require("readline");
    const rl = readline.createInterface({
      input: process.stdin,
      output: process.stdout,
    });

    return new Promise((resolve) => {
      console.log(`${c.bold}Where do you want to install? (${host})${c.reset}`);
      console.log(`  ${c.cyan}1)${c.reset} ${c.bold}Global${c.reset}  → ~/${dotDir}/skills/ ${c.dim}(available in all projects)${c.reset}`);
      console.log(`  ${c.cyan}2)${c.reset} ${c.bold}Project${c.reset} → ./${dotDir}/skills/ ${c.dim}(current project only)${c.reset}`);
      console.log();
      rl.question(`${c.bold}Choose [1/2]:${c.reset} `, (answer) => {
        rl.close();
        const trimmed = answer.trim();
        if (trimmed === "1" || trimmed.toLowerCase() === "g" || trimmed.toLowerCase() === "global") {
          resolve({ target: globalDir, scope: "global" });
        } else {
          resolve({ target: projectDir, scope: "project" });
        }
      });
    });
  }

  // Non-interactive fallback: auto-detect
  if (fs.existsSync(path.join(process.cwd(), dotDir))) {
    return { target: projectDir, scope: "project" };
  }
  return { target: globalDir, scope: "global" };
}

// ── File operations ──────────────────────────────────────

function copyDirSync(src, dest, contentTransformer) {
  fs.mkdirSync(dest, { recursive: true });
  const entries = fs.readdirSync(src, { withFileTypes: true });
  for (const entry of entries) {
    const srcPath = path.join(src, entry.name);
    const destPath = path.join(dest, entry.name);
    if (entry.name === "MANIFEST") continue;
    if (entry.isDirectory()) {
      copyDirSync(srcPath, destPath, contentTransformer);
    } else if (contentTransformer && entry.name.endsWith(".md")) {
      const raw = fs.readFileSync(srcPath, "utf-8");
      fs.writeFileSync(destPath, contentTransformer(raw));
    } else {
      fs.copyFileSync(srcPath, destPath);
    }
  }
}

function backupPersonality(targetSkillDir) {
  const personalityPath = path.join(targetSkillDir, "personality.md");
  if (!fs.existsSync(personalityPath)) return null;

  const content = fs.readFileSync(personalityPath, "utf-8");
  if (content.includes("status: configured")) {
    const backupPath = path.join(
      require("os").tmpdir(),
      `personality-backup-${Date.now()}.md`
    );
    fs.copyFileSync(personalityPath, backupPath);
    return backupPath;
  }
  return null;
}

function restorePersonality(targetSkillDir, backupPath) {
  if (backupPath && fs.existsSync(backupPath)) {
    fs.copyFileSync(backupPath, path.join(targetSkillDir, "personality.md"));
    fs.unlinkSync(backupPath);
    return true;
  }
  return false;
}

// ── Commands ────────────────────────────────────────────

async function cmdInstall(args) {
  const isOpenClaw = args.includes("--openclaw") || args.includes("-o");
  const isHermes = args.includes("--hermes") || args.includes("-H");

  if (isOpenClaw && isHermes) {
    throw new Error("--openclaw and --hermes are mutually exclusive");
  }

  const cleanArgs = args.filter(
    (a) =>
      a !== "--openclaw" &&
      a !== "-o" &&
      a !== "--hermes" &&
      a !== "-H"
  );
  const hostMode = isOpenClaw ? "openclaw" : isHermes ? "hermes" : "claude";

  const available = getAvailableSkills();
  const skillArgs = cleanArgs.filter((a) => !a.startsWith("-"));
  let toInstall = [];

  if (skillArgs.length === 0 || cleanArgs.includes("--all")) {
    toInstall = available;
    console.log(
      `\n${c.cyan}${c.bold}📦 Installing ALL skills...${c.reset}\n`
    );
  } else {
    toInstall = skillArgs;
    const invalid = toInstall.filter((s) => !available.includes(s));
    if (invalid.length > 0) {
      console.log(
        `\n${c.red}❌ Unknown skill(s): ${invalid.join(", ")}${c.reset}`
      );
      console.log(`\nAvailable: ${available.join(", ")}`);
      process.exit(1);
    }
    console.log(
      `\n${c.cyan}${c.bold}📦 Installing: ${toInstall.join(", ")}${c.reset}\n`
    );
  }

  if (isOpenClaw) {
    console.log(`${c.magenta}${c.bold}   Host: OpenClaw${c.reset} ${c.dim}(content will be adapted for openclaw)${c.reset}`);
  } else if (isHermes) {
    console.log(`${c.magenta}${c.bold}   Host: Hermes${c.reset} ${c.dim}(skill content is copied without adaptation)${c.reset}`);
  }

  const result = await resolveTargetDir(cleanArgs, hostMode);
  const targetBase = result.target;
  const scope = result.scope;

  fs.mkdirSync(targetBase, { recursive: true });
  console.log(`\n${c.dim}   Scope:  ${scope}${c.reset}`);
  console.log(`${c.dim}   Target: ${targetBase}/${c.reset}\n`);

  const transformer = isOpenClaw
    ? (content) => transformForOpenClaw(content, VERSION)
    : null;

  let success = 0;
  let fail = 0;

  for (const skill of toInstall) {
    const src = path.join(SKILLS_DIR, skill);
    const dest = path.join(targetBase, skill);

    process.stdout.write(`   ${c.bold}${skill}${c.reset} `);

    try {
      const backup = backupPersonality(dest);

      if (fs.existsSync(dest)) {
        fs.rmSync(dest, { recursive: true, force: true });
      }

      copyDirSync(src, dest, transformer);

      if (restorePersonality(dest, backup)) {
        console.log(`${c.green}✅ installed${c.reset} ${c.dim}(personality restored)${c.reset}`);
      } else {
        console.log(`${c.green}✅ installed${c.reset}`);
      }
      success++;
    } catch (err) {
      console.log(`${c.red}❌ failed: ${err.message}${c.reset}`);
      fail++;
    }
  }

  const hostLabel = isOpenClaw
    ? "OpenClaw"
    : isHermes
      ? "Hermes"
      : scope === "global"
        ? "Global"
        : "Project";
  console.log(`\n${"═".repeat(40)}`);
  console.log(`  ${c.green}✅ Installed: ${success}${c.reset}`);
  if (fail > 0) console.log(`  ${c.red}❌ Failed: ${fail}${c.reset}`);
  console.log(`  ${c.dim}📁 ${hostLabel}: ${targetBase}/${c.reset}`);
  console.log(`${"═".repeat(40)}\n`);
}

function cmdList() {
  const available = getAvailableSkills();
  console.log(
    `\n${c.cyan}${c.bold}📋 Available Skills (v${VERSION})${c.reset}\n`
  );
  if (available.length === 0) {
    console.log("   No skills found.");
  } else {
    for (const skill of available) {
      const desc = getSkillDescription(skill);
      console.log(`   ${c.bold}${skill}${c.reset}`);
      if (desc) console.log(`   ${c.dim}${desc}${c.reset}`);
      console.log();
    }
  }
  console.log(
    `${c.dim}Install with: npx @verzth/skills install <name>${c.reset}\n`
  );
}

function cmdHelp() {
  console.log(`
${c.cyan}${c.bold}@verzth/skills${c.reset} v${VERSION}
Custom skills for Claude Code, OpenClaw, and Hermes Agent

${c.bold}USAGE${c.reset}
  npx @verzth/skills <command> [options]

${c.bold}COMMANDS${c.reset}
  install [skill...]    Install skills (interactive scope picker)
  install --all         Install all available skills
  update [skill...]     Reinstall one or all skills from this package
  list                  Show available skills
  help                  Show this help

${c.bold}FLAGS${c.reset}
  -g, --global          Install to ~/.claude/skills/ (all projects)
  -p, --project         Install to ./.claude/skills/ (current project)
  -o, --openclaw        Install for OpenClaw (~/.openclaw/skills/)
  -H, --hermes          Install for Hermes (~/.hermes/skills/)
  ${c.dim}Combine a host flag with --global or --project${c.reset}
  ${c.dim}--openclaw and --hermes are mutually exclusive${c.reset}
  ${c.dim}If no scope flag given, you'll be prompted to choose.${c.reset}

${c.bold}EXAMPLES${c.reset}
  npx @verzth/skills install public-awareness
  npx @verzth/skills install public-awareness --global
  npx @verzth/skills install public-awareness --openclaw
  npx @verzth/skills install public-awareness --openclaw --global
  npx @verzth/skills install public-awareness --hermes --global
  npx @verzth/skills update public-awareness --global
  npx @verzth/skills install --all --project
  npx @verzth/skills list

${c.bold}OPENCLAW${c.reset}
  The --openclaw flag adapts skill content for OpenClaw:
  • Installs to ~/.openclaw/skills/ or .openclaw/skills/
  • Rewrites tool names (Bash→exec, Write→write, Agent→sessions_spawn)
  • Rewrites paths (.claude/→.openclaw/)
  • Normalizes frontmatter (name + description + version only)

${c.bold}HERMES${c.reset}
  The --hermes flag copies skill content without adaptation:
  • Installs to ~/.hermes/skills/ or .hermes/skills/
  • Supports the same global and project scopes

${c.bold}NOTES${c.reset}
  - Personality settings are preserved on upgrade
  - Global skills apply to all projects
  - Project skills only apply to the current project
`);
}

// ── Main ────────────────────────────────────────────────
async function main() {
  const [command, ...args] = process.argv.slice(2);

  switch (command) {
    case "install":
    case "i":
    case "add":
      await cmdInstall(args);
      break;
    case "update":
      await cmdInstall(args);
      break;
    case "list":
    case "ls":
      cmdList();
      break;
    case "help":
    case "--help":
    case "-h":
    case undefined:
      cmdHelp();
      break;
    default:
      await cmdInstall([command, ...args]);
      break;
  }
}

main().catch((err) => {
  console.error(`${c.red}❌ ${err.message}${c.reset}`);
  process.exit(1);
});
