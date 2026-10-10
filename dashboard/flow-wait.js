#!/usr/bin/env node
// Wait for the operator: blocks until a note (or a plan answer) is sent from
// the SousVide Flow chart, prints it, and exits. An agent runs this as a
// background command while idle; the exit wakes it, it acts on the note, and
// it starts this again. Retries quietly while the dashboard is down.
//
//   node flow-wait.js [--hours N]     give up after N hours (default 12)
const http = require("http");
const PORT = parseInt(process.env.PZTEST_DASH_PORT || "8760", 10);
const i = process.argv.indexOf("--hours");
const deadline = Date.now() + (i > 0 ? Number(process.argv[i + 1]) : 12) * 3600e3;

function wait() {
  if (Date.now() > deadline) { console.log("(stopped listening: time limit)"); process.exit(0); }
  const req = http.get({ host: "127.0.0.1", port: PORT, path: "/api/flow/wait" }, (res) => {
    let body = "";
    res.on("data", (c) => (body += c));
    res.on("end", () => {
      try {
        const out = JSON.parse(body);
        if (out.context) { console.log(out.context); process.exit(0); }
      } catch (_) {}
      setTimeout(wait, 1000);
    });
  });
  req.on("error", () => setTimeout(wait, 3000));
}
wait();
