#!/usr/bin/env node

const fs = require("fs");
const path = require("path");
const { spawnSync } = require("child_process");

const ROOT = path.resolve(__dirname, "..");

function fail(message) {
  throw new Error(message);
}

function assert(condition, message) {
  if (!condition) fail(message);
}

function readJson(relativePath) {
  const absolutePath = path.join(ROOT, relativePath);
  try {
    return JSON.parse(fs.readFileSync(absolutePath, "utf8"));
  } catch (error) {
    fail(`${relativePath}: ${error.message}`);
  }
}

function listInventorySkills() {
  const skillsDir = path.join(ROOT, "skills");
  return fs
    .readdirSync(skillsDir, { withFileTypes: true })
    .filter((entry) => entry.isDirectory())
    .map((entry) => entry.name)
    .filter((name) => {
      const skillRoot = path.join(skillsDir, name);
      return (
        fs.existsSync(path.join(skillRoot, "SKILL.md")) ||
        fs.existsSync(path.join(skillRoot, ".claude-plugin", "plugin.json"))
      );
    })
    .sort();
}

function validateInventory() {
  const packageJson = readJson("package.json");
  const marketplace = readJson(".claude-plugin/marketplace.json");
  const inventorySkills = listInventorySkills();
  const marketplaceNames = marketplace.plugins.map((plugin) => plugin.name).sort();
  const cliPath = packageJson.bin && packageJson.bin["verzth-skills"];

  assert(cliPath === "bin/cli.js", "package bin must map verzth-skills to bin/cli.js");
  assert(fs.existsSync(path.join(ROOT, cliPath)), `package bin is missing: ${cliPath}`);
  assert(
    fs.readFileSync(path.join(ROOT, cliPath), "utf8").startsWith("#!/usr/bin/env node"),
    "package bin must start with a Node.js shebang"
  );

  assert(
    packageJson.version === marketplace.metadata.version,
    `version mismatch: package=${packageJson.version}, marketplace=${marketplace.metadata.version}`
  );
  assert(
    JSON.stringify(inventorySkills) === JSON.stringify(marketplaceNames),
    `inventory mismatch: disk=${inventorySkills.join(",")}, marketplace=${marketplaceNames.join(",")}`
  );

  for (const plugin of marketplace.plugins) {
    const source = plugin.source.replace(/^\.\//, "");
    const sourcePath = path.join(ROOT, source);
    const manifestPath = path.join(sourcePath, ".claude-plugin", "plugin.json");

    assert(fs.existsSync(sourcePath), `${plugin.name}: marketplace source is missing`);
    assert(fs.existsSync(manifestPath), `${plugin.name}: plugin.json is missing`);

    const manifest = JSON.parse(fs.readFileSync(manifestPath, "utf8"));
    assert(manifest.name === plugin.name, `${plugin.name}: plugin manifest name mismatch`);
    assert(
      manifest.version === plugin.version,
      `${plugin.name}: version mismatch between marketplace (${plugin.version}) and plugin manifest (${manifest.version})`
    );
  }

  return { packageJson, marketplace, inventorySkills };
}

function validateManifests(inventorySkills) {
  for (const skill of inventorySkills) {
    const skillRoot = path.join(ROOT, "skills", skill);
    const manifestPath = path.join(skillRoot, "MANIFEST");
    if (!fs.existsSync(manifestPath)) continue;

    const entries = fs
      .readFileSync(manifestPath, "utf8")
      .split(/\r?\n/)
      .map((line) => line.trim())
      .filter((line) => line && !line.startsWith("#"));

    for (const entry of entries) {
      assert(
        fs.existsSync(path.join(skillRoot, entry)),
        `${skill}/MANIFEST references missing file: ${entry}`
      );
    }
  }
}

function validateReadme(marketplace, inventorySkills) {
  const readmePath = path.join(ROOT, "README.md");
  const readme = fs.readFileSync(readmePath, "utf8");

  const localLinkPattern = /\[[^\]]*\]\(([^)]+)\)/g;
  for (const match of readme.matchAll(localLinkPattern)) {
    const target = match[1];
    if (/^(https?:|mailto:|#)/.test(target)) continue;
    const localTarget = target.split("#")[0];
    assert(
      fs.existsSync(path.resolve(ROOT, localTarget)),
      `README has a broken local link: ${target}`
    );
  }

  const documentedInstalls = Array.from(
    readme.matchAll(/\/plugin install ([a-z0-9-]+)@verzth-skills/g),
    (match) => match[1]
  );
  const missingExamples = marketplace.plugins
    .map((plugin) => plugin.name)
    .filter((name) => !documentedInstalls.includes(name));
  assert(
    missingExamples.length === 0,
    `README marketplace examples missing: ${missingExamples.join(", ")}`
  );

  const documentedTypes = new Map(
    Array.from(
      readme.matchAll(/^\| `([^`]+)` \| (single|bundle) \|/gm),
      (match) => [match[1], match[2]]
    )
  );
  for (const skill of inventorySkills) {
    const actualType = fs.existsSync(path.join(ROOT, "skills", skill, "SKILL.md"))
      ? "single"
      : "bundle";
    assert(
      documentedTypes.get(skill) === actualType,
      `README type mismatch for ${skill}: documented=${documentedTypes.get(skill)}, actual=${actualType}`
    );
  }
}

function validateMockerizeBenchmarks() {
  const quality = readJson("skills/mockerize/evals/evals.json");
  const triggers = readJson("skills/mockerize/evals/trigger-evals.json");

  assert(quality.skill_name === "mockerize", "mockerize quality suite name mismatch");
  assert(quality.evals.length >= 8, "mockerize needs at least 8 quality evals");

  const positive = triggers.filter((entry) => entry.should_trigger === true).length;
  const negative = triggers.filter((entry) => entry.should_trigger === false).length;
  assert(positive >= 8 && negative >= 8, "mockerize trigger suite is too small");
  assert(Math.abs(positive - negative) <= 2, "mockerize trigger suite is unbalanced");
}

function npmPackList() {
  const npmArgs = ["pack", "--dry-run", "--ignore-scripts", "--json"];
  let result;

  if (process.env.npm_execpath) {
    result = spawnSync(process.execPath, [process.env.npm_execpath, ...npmArgs], {
      cwd: ROOT,
      encoding: "utf8",
    });
  } else {
    result = spawnSync("npm", npmArgs, {
      cwd: ROOT,
      encoding: "utf8",
      shell: process.platform === "win32",
    });
  }

  if (result.status !== 0) {
    fail(`npm pack inspection failed: ${(result.stderr || result.stdout).trim()}`);
  }

  let payload;
  try {
    payload = JSON.parse(result.stdout);
  } catch (error) {
    fail(`npm pack returned invalid JSON: ${error.message}`);
  }
  assert(Array.isArray(payload) && payload[0], "npm pack returned no package metadata");
  return payload[0];
}

function validatePackageContents() {
  const packed = npmPackList();
  const blockedPathPatterns = [
    /(^|\/)[^/]*-workspace(\/|$)/,
    /(^|\/)agent_id_map\.json$/,
    /\/trigger-eval\/results\//,
  ];
  const blockedContentPatterns = [
    /\/Users\/[^/\s]+\/(?:Workspace|Documents)\//,
    /\/home\/[^/\s]+\/(?:workspace|Workspace|Documents)\//,
  ];
  const textExtensions = new Set([
    ".css",
    ".go",
    ".html",
    ".js",
    ".json",
    ".md",
    ".proto",
    ".py",
    ".sh",
    ".sql",
    ".tf",
    ".ts",
    ".tsx",
    ".txt",
    ".yaml",
    ".yml",
  ]);

  for (const file of packed.files) {
    for (const pattern of blockedPathPatterns) {
      assert(!pattern.test(file.path), `blocked internal path in npm package: ${file.path}`);
    }

    if (!textExtensions.has(path.extname(file.path).toLowerCase())) continue;
    const absolutePath = path.join(ROOT, file.path);
    if (!fs.existsSync(absolutePath)) continue;
    const content = fs.readFileSync(absolutePath, "utf8");
    for (const pattern of blockedContentPatterns) {
      assert(
        !pattern.test(content),
        `absolute local workspace path found in npm package file: ${file.path}`
      );
    }
  }

  return packed;
}

function main() {
  const { marketplace, inventorySkills } = validateInventory();
  validateManifests(inventorySkills);
  validateReadme(marketplace, inventorySkills);
  validateMockerizeBenchmarks();
  const packed = validatePackageContents();

  console.log(
    `Publication checks passed: ${inventorySkills.length} skills, ` +
      `${packed.entryCount} packaged files, ${packed.size} packed bytes`
  );
}

try {
  main();
} catch (error) {
  console.error(`Publication check failed: ${error.message}`);
  process.exit(1);
}
