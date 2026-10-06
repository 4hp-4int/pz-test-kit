#!/usr/bin/env node
// pztest down: stop every SousVide process on this machine -- dashboards
// (dashboard/server.js), the VMs they started (single and MP sides) and stray
// test runs: anything running the kit's Java. MCP servers (dashboard/mcp.js)
// are left alone; they belong to editor sessions.
//
//   pztest down          stop them
//   pztest down --list   only show what would be stopped
const { execFileSync } = require("child_process");
const path = require("path");

const KIT = path.resolve(__dirname, "..");
const listOnly = process.argv.includes("--list");

function processes() {
  if (process.platform === "win32") {
    const ps = "Get-CimInstance Win32_Process | Where-Object { $_.CommandLine } | " +
      "Select-Object ProcessId, Name, CommandLine | ConvertTo-Json -Compress";
    const out = execFileSync("powershell.exe", ["-NoProfile", "-Command", ps], { encoding: "utf8", maxBuffer: 64 << 20 });
    const list = JSON.parse(out || "[]");
    return (Array.isArray(list) ? list : [list]).map((p) => ({ pid: p.ProcessId, name: p.Name, cmd: p.CommandLine }));
  }
  const out = execFileSync("ps", ["-eo", "pid=,comm=,args="], { encoding: "utf8" });
  return out.split("\n").filter(Boolean).map((l) => {
    const m = /^\s*(\d+)\s+(\S+)\s+(.*)$/.exec(l);
    return m && { pid: +m[1], name: m[2], cmd: m[3] };
  }).filter(Boolean);
}

const kitPath = KIT.replace(/\\/g, "/").toLowerCase();
const norm = (s) => s.replace(/\\/g, "/").toLowerCase();
const targets = processes().filter((p) => {
  if (p.pid === process.pid) return false;
  const cmd = norm(p.cmd);
  if (/node/i.test(p.name) && /dashboard\/server\.js|(^|[\s"])server\.js\s+\d{4}/.test(cmd) && !cmd.includes("mcp.js")) {
    // a dashboard: started from the kit (by path), or `node server.js <port>` from dashboard/
    return cmd.includes(kitPath) || /(^|[\s"])server\.js\s+87\d\d/.test(cmd) || cmd.includes("dashboard/server.js");
  }
  if (/java/i.test(p.name)) return cmd.includes(kitPath) || cmd.includes("pztestkitlauncher");
  // the bash wrappers (pztest) exit on their own once their JVM is gone
  return false;
});

if (!targets.length) { console.log("[pztest down] nothing running"); process.exit(0); }
for (const p of targets) {
  const label = /java/i.test(p.name) ? "VM" : "dashboard";
  const short = p.cmd.length > 110 ? p.cmd.slice(0, 107) + "..." : p.cmd;
  if (listOnly) { console.log(`  ${label.padEnd(9)} ${String(p.pid).padStart(6)}  ${short}`); continue; }
  try {
    if (process.platform === "win32") execFileSync("taskkill", ["/pid", String(p.pid), "/T", "/F"], { stdio: "ignore" });
    else process.kill(p.pid, "SIGKILL");
    console.log(`  stopped ${label} ${p.pid}`);
  } catch (_) { /* already gone (a parent's /T took it) */ }
}
console.log(listOnly ? `[pztest down] ${targets.length} process(es) would stop` : `[pztest down] done`);
