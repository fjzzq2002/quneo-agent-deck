// QuNeo Deck Bridge — lets the deck focus the exact integrated terminal
// hosting a Claude session.
//
// Each VS Code/Cursor window runs its own extension host, so each window
// listens on its own unix socket: ~/.quneo-deck/ide/<pid>.sock. The deck
// sends {"ancestors": [pids...]} (the Claude process's ancestry — one of
// which is the terminal's shell). If a terminal here matches, we focus it
// and reply with the workspace name so the deck can raise this window.
const vscode = require("vscode");
const net = require("net");
const fs = require("fs");
const os = require("os");
const path = require("path");

let server;
let sockPath;

function activate(context) {
  const dir = path.join(os.homedir(), ".quneo-deck", "ide");
  fs.mkdirSync(dir, { recursive: true });
  sockPath = path.join(dir, `${process.pid}.sock`);
  try { fs.unlinkSync(sockPath); } catch {}

  server = net.createServer((conn) => {
    let buf = "";
    conn.on("data", (d) => {
      buf += d.toString();
      const nl = buf.indexOf("\n");
      if (nl >= 0) handle(buf.slice(0, nl), conn);
    });
    conn.on("error", () => {});
  });
  server.on("error", () => {});
  server.listen(sockPath);

  context.subscriptions.push({
    dispose: () => {
      try { server.close(); } catch {}
      try { fs.unlinkSync(sockPath); } catch {}
    },
  });
}

async function handle(line, conn) {
  let req = {};
  try { req = JSON.parse(line); } catch {}
  const ancestors = new Set(req.ancestors || []);
  for (const t of vscode.window.terminals) {
    let pid;
    try { pid = await t.processId; } catch { continue; }
    if (pid && ancestors.has(pid)) {
      t.show(false); // false = take focus
      const ws =
        (vscode.workspace.workspaceFolders &&
          vscode.workspace.workspaceFolders[0] &&
          vscode.workspace.workspaceFolders[0].name) ||
        vscode.workspace.name ||
        "";
      conn.end(JSON.stringify({ ok: true, workspace: ws, terminal: t.name }) + "\n");
      return;
    }
  }
  conn.end(JSON.stringify({ ok: false }) + "\n");
}

function deactivate() {
  try { server.close(); } catch {}
  try { fs.unlinkSync(sockPath); } catch {}
}

module.exports = { activate, deactivate };
