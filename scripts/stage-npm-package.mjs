#!/usr/bin/env node
// Stage and pack the npm tarball for `agrout-bridge`.
//
// Usage:
//   node scripts/stage-npm-package.mjs --out .
//
// Layout produced under <out>/stage/:
//   stage/
//     package.json
//     LICENSE
//     README.md
//     bin/agrout-bridge.js              # Node launcher
//     bin-executables/{app-linux,app-mac,app-win.exe}
//
// .npmignore excludes the source tree, dart_tool, build scripts.

import { copyFileSync, existsSync, mkdirSync, readdirSync, readFileSync, writeFileSync } from "node:fs";
import { join, resolve } from "node:path";
import { execSync } from "node:child_process";

const outDir = resolve(process.argv.indexOf("--out") !== -1 ? process.argv[process.argv.indexOf("--out") + 1] || "." : ".");
const stageDir = join(outDir, "stage");

if (existsSync(stageDir)) {
  execSync(`rm -rf "${stageDir}"`, { shell: true });
}
mkdirSync(join(stageDir, "bin"), { recursive: true });
mkdirSync(join(stageDir, "bin-executables"), { recursive: true });

for (const f of ["package.json", "LICENSE", "README.md"]) {
  copyFileSync(f, join(stageDir, f));
}
copyFileSync("bin/agrout-bridge.js", join(stageDir, "bin", "agrout-bridge.js"));

for (const bin of ["app-linux", "app-mac", "app-win.exe"]) {
  if (existsSync(bin)) {
    copyFileSync(bin, join(stageDir, "bin-executables", bin));
  } else {
    console.error(`Warning: ${bin} not found, skipping`);
  }
}

for (const f of ["bin-executables/app-linux", "bin-executables/app-mac", "bin-executables/app-win.exe", "bin/agrout-bridge.js"]) {
  const full = join(stageDir, f);
  if (existsSync(full)) {
    execSync(`chmod 755 "${full}"`, { shell: true });
  }
}

const pkg = JSON.parse(readFileSync(join(stageDir, "package.json"), "utf-8"));
const version = pkg.version;

writeFileSync(join(stageDir, ".npmignore"), [
  "node_modules/",
  ".dart_tool/",
  "test/",
  "lib/",
  "pubspec.*",
  "build",
  "build.bat",
  "run",
  "run.bat",
  "AGENTS.md",
  "scripts/",
  ".agrout/",
  "bin/agrout_bridge.dart",
  "dev/",
].join("\n") + "\n", "utf-8");

execSync(`npm pack 2>&1`, { cwd: stageDir, stdio: "inherit", shell: true });

const stageFiles = readdirSync(stageDir).filter((f) => f.endsWith(".tgz"));
if (stageFiles.length === 0) {
  console.error("npm pack produced no .tgz");
  process.exit(1);
}

const tgzName = `agrout-bridge-v${version}.tgz`;
const src = join(stageDir, stageFiles[0]);
const dst = join(outDir, tgzName);
copyFileSync(src, dst);
console.log(`Packaged: ${dst}`);

execSync(`rm -rf "${stageDir}"`, { shell: true });
