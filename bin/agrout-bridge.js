#!/usr/bin/env node
import { existsSync, readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const platform = process.platform;
let binaryName = "";

if (platform === "win32") {
  binaryName = "app-win.exe";
} else if (platform === "darwin") {
  binaryName = "app-mac";
} else if (platform === "linux") {
  binaryName = "app-linux";
} else {
  console.error(`Unsupported operating system: ${platform}`);
  process.exit(1);
}

const __dirname = dirname(dirname(fileURLToPath(import.meta.url)));
const binaryPath = join(__dirname, "bin-executables", binaryName);

function getVersion() {
  try {
    const pkgPath = join(__dirname, "package.json");
    const pkg = JSON.parse(readFileSync(pkgPath, "utf-8"));
    return pkg.version;
  } catch {
    return "0.0.0";
  }
}

const args = process.argv.slice(2);

if (args.includes("--version") || args.includes("-v")) {
  console.log(`agrout-bridge v${getVersion()}`);
  process.exit(0);
}

if (!existsSync(binaryPath)) {
  console.error(`Binary not found: ${binaryPath}`);
  console.error("The agrout-bridge package appears to be corrupted or incomplete.");
  console.error("Try reinstalling from a fresh tarball.");
  process.exit(1);
}

const { spawn } = await import("node:child_process");

const child = spawn(binaryPath, args, {
  stdio: "inherit",
  shell: false,
});

// Forward termination signals to the child so killing the wrapper does
// not orphan the dart server process (an orphan would keep holding the
// bridge port, causing the port to be reported as in-use on next start).
for (const sig of ["SIGINT", "SIGTERM", "SIGHUP"]) {
  process.on(sig, () => {
    child.kill(sig);
  });
}

child.on("exit", (code) => {
  process.exit(code ?? 0);
});

// Safety net: if the wrapper dies for any other reason (uncaught error,
// process.kill without signal), make sure the child does not linger.
process.on("exit", () => {
  if (child.exitCode === null && child.signalCode === null) {
    child.kill("SIGKILL");
  }
});
