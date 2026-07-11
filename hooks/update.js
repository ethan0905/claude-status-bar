#!/usr/bin/env node
// Maps a Claude Code hook event to this session's file: ~/.claude/statusbar/state.d/<session_id>.json
// Usage: node update.js <prompt|pre|post|notify|permreq|stop>

const fs = require("fs");
const os = require("os");
const path = require("path");

const dir = path.join(os.homedir(), ".claude", "statusbar");
const stateDir = path.join(dir, "state.d");
const event = process.argv[2] || "";

// Controlling tty of this session, for exact terminal-tab focus and permission keystroke delivery
// (the app matches a Terminal/iTerm tab — or a tmux pane — by tty). Two strategies:
//   1. Inside tmux ($TMUX_PANE set): ask tmux for the pane's tty directly. This is authoritative and
//      works even when the claude process itself has no controlling tty (e.g. inside VS Code's
//      integrated terminal, where the `ps` walk below returns "??").
//   2. Otherwise: walk up the process tree to the first real ttysNNN (stdio may be piped).
// "" = no tty (e.g. the desktop app). Stable per session, so callers carry it over.
function ttyDev() {
  const { execSync } = require("child_process");
  // 1. tmux pane tty (most reliable inside tmux, incl. VS Code integrated terminal).
  const pane = process.env.TMUX_PANE;
  if (pane) {
    for (const tmux of ["tmux", "/opt/homebrew/bin/tmux", "/usr/local/bin/tmux", "/usr/bin/tmux"]) {
      try {
        const dev = execSync(`${tmux} display-message -p -t '${pane}' '#{pane_tty}'`, { encoding: "utf8" }).trim();
        if (dev.startsWith("/dev/tty")) return dev;
      } catch {}
    }
  }
  // 2. process-tree walk.
  try {
    let pid = String(process.pid);
    for (let i = 0; i < 6 && pid && pid !== "1"; i++) {
      const [tty, ppid] = execSync(`ps -o tty=,ppid= -p ${pid}`, { encoding: "utf8" }).trim().split(/\s+/);
      if (tty && tty.startsWith("tty")) return "/dev/" + tty;
      pid = ppid;
    }
  } catch {}
  return "";
}

const TOOL_LABELS = {
  Bash: "Running command", Edit: "Editing", Write: "Writing", MultiEdit: "Editing",
  NotebookEdit: "Editing", Read: "Reading", Grep: "Searching", Glob: "Searching",
  WebFetch: "Browsing web", WebSearch: "Searching web", Task: "Delegating",
  Agent: "Delegating", TodoWrite: "Planning",
};

const safeId = (s) => String(s || "").replace(/[^A-Za-z0-9_.-]/g, "").slice(0, 64) || "unknown";

let raw = "";
process.stdin.on("data", (d) => (raw += d));
process.stdin.on("end", () => {
  let p = {};
  try { p = JSON.parse(raw || "{}"); } catch {}

  // Off by default; CLAUDE_STATUSBAR_DEBUG=1 logs every hook invocation to hooks.log.
  if (process.env.CLAUDE_STATUSBAR_DEBUG === "1") {
    try {
      fs.mkdirSync(dir, { recursive: true });
      fs.appendFileSync(path.join(dir, "hooks.log"),
        `${new Date().toISOString()} [${event}] tool=${p.tool_name || "-"} mode=${p.permission_mode || "-"} msg=${JSON.stringify(p.message || "").slice(0, 160)} keys=${Object.keys(p).join(",")}\n`);
    } catch {}
  }

  // This session's own file is the unit of state AND the liveness marker. Writing it on any
  // event also tracks sessions that predate the hook install (never fired SessionStart).
  const sid = safeId(p.session_id);
  const statePath = path.join(stateDir, sid + ".json");

  let prev = {};
  try { prev = JSON.parse(fs.readFileSync(statePath, "utf8")); } catch {}

  const project = p.cwd ? path.basename(p.cwd) : prev.project || "";
  // The app reads <cwd>/.git/HEAD for the branch and disambiguates same-named projects by
  // parent folder; carried over from prev for events whose payload omits cwd.
  const cwd = p.cwd || prev.cwd || "";
  const projectPath = p.cwd ? p.cwd.replace(os.homedir(), "~") : prev.project_path || "";
  const ts = Math.floor(Date.now() / 1000);
  let state = "idle", label = "", startedAt = prev.startedAt || 0;

  switch (event) {
    case "prompt":
      state = "thinking"; label = "Thinking…"; startedAt = ts; break;
    case "pre": {
      const t = p.tool_name || "";
      state = "tool"; label = TOOL_LABELS[t] || "Using tool";
      if (!startedAt) startedAt = ts;
      break;
    }
    case "post":
      state = "thinking"; label = "Thinking…";
      if (!startedAt) startedAt = ts;
      break;
    case "notify": {
      // Only a permission prompt drives the icon here (CLI path; desktop uses permreq). Ignore
      // every other Notification (esp. the idle_prompt "Claude is waiting for your input") so the
      // icon rests instead of parking on a confusing "Waiting for you".
      const m = (p.message || "").toLowerCase();
      const isPerm = p.notification_type === "permission_prompt" ||
        m.includes("permission") || m.includes("approve") || m.includes("allow");
      if (!isPerm) return;
      state = "permission"; label = "Awaiting permission"; startedAt = 0;
      break;
    }
    case "permreq":
      // Desktop-app permission signal; not redundant with notify (that's CLI-only).
      state = "permission"; label = "Awaiting permission"; startedAt = 0; break;
    case "stop":
      // NOTE: running-subagent files (<sid>.agents.d/, written by agents.js) deliberately survive
      // the turn: subagents run in the BACKGROUND and outlive the parent's turn — Stop fires
      // seconds after the spawn while they're still working. Their files are removed by their
      // own SubagentStop; lifecycle.js clears the dir at session boundaries.
      state = "done"; label = "Done"; startedAt = 0; break;
    default:
      return;
  }

  // CLAUDE_CODE_ENTRYPOINT tags the surface running this session ("cli", "claude-desktop", …);
  // carried over from prev for the odd event where the env var isn't set.
  const entrypoint = process.env.CLAUDE_CODE_ENTRYPOINT || prev.entrypoint || "";
  // TERM_PROGRAM identifies the terminal app for a CLI session (Apple_Terminal, iTerm.app,
  // vscode, WezTerm, …); the app uses it to bring that terminal to the front on a row click.
  const termProgram = process.env.TERM_PROGRAM || prev.term_program || "";
  // tty: the session's controlling terminal. Drives exact terminal-tab focus and permission
  // keystroke delivery (tmux send-keys / iTerm AppleScript). Recompute when empty so a session that
  // seeded before tmux was known still gets one; a good value is carried over to avoid re-running ps.
  const tty = prev.tty || ttyDev();
  // TMUX env (present when claude runs inside tmux) tells the app to route keystrokes through
  // `tmux send-keys` to the pane owning this tty, instead of the terminal app directly.
  const insideTmux = !!process.env.TMUX || !!prev.tmux;
  // process.ppid IS this session's `claude` process (verified: hooks are spawned directly by it,
  // stable for the session's life, on both CLI and desktop). The app uses kill(pid,0) for liveness.
  // started:true — any update.js event (prompt/tool/permission/stop) is real activity, so the session
  // graduates from "merely opened" to visible in the dropdown. Clicking a conversation never fires here.
  const out = { state, label, tool: p.tool_name || "", project, cwd, project_path: projectPath, sessionId: p.session_id || "", transcript: p.transcript_path || prev.transcript || "", entrypoint, term_program: termProgram, pid: process.ppid, started: true, tty, tmux: insideTmux, startedAt, ts };
  try {
    fs.mkdirSync(stateDir, { recursive: true });
    const tmp = statePath + "." + process.pid + ".tmp";
    fs.writeFileSync(tmp, JSON.stringify(out));
    fs.renameSync(tmp, statePath);
  } catch {}
});
