// Screenshot the zoxel web build in headless Chrome (WebGPU) over CDP.
//
//   node web/tools/cdp-screenshot.mjs <url> <out.png> [options]
//
// Options (all optional):
//   --size=1440x900       viewport in CSS pixels
//   --dpr=2               device pixel ratio
//   --wait=ms             wait after load before acting (default 8000)
//   --drag=x1,y1,x2,y2    left-drag (CSS px) to orbit, then wait
//   --click=x,y[;x,y...]  click (CSS px), e.g. GUI buttons, 4 s apart
//   --pick=a.dcs,b.dcs    with --click on "Open file…": intercept the browser
//                         file chooser it opens and choose these files
//   --no-webgpu           hide navigator.gpu to check the fallback message
//   --after=ms            wait after the actions (default 3000)
//   --chrome=path         Chrome binary (default: macOS Google Chrome, or $CHROME)
//
// Prints the page's console, then a JSON state line, then writes the PNG.
import { spawn } from "node:child_process";
import { writeFileSync, mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";

const [url, out, ...rest] = process.argv.slice(2);
if (!url || !out) {
  console.error("usage: node cdp-screenshot.mjs <url> <out.png> [--size=WxH] [--dpr=N] [--wait=ms] [--drag=x1,y1,x2,y2] [--click=x,y] [--pick=files] [--after=ms]");
  process.exit(2);
}
const opt = Object.fromEntries(rest.map((a) => { const [k, v] = a.replace(/^--/, "").split("="); return [k, v ?? "1"]; }));
const [width, height] = (opt.size ?? "1440x900").split("x").map(Number);
const dpr = Number(opt.dpr ?? 2);
const chrome = opt.chrome ?? process.env.CHROME ?? "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome";
const port = 9300 + Math.floor(Math.random() * 600);
const udd = mkdtempSync(join(process.env.TMPDIR || tmpdir(), "zoxel-cdp-"));
const proc = spawn(chrome, [
  "--headless=new", `--remote-debugging-port=${port}`, `--user-data-dir=${udd}`,
  "--enable-unsafe-webgpu", "--no-first-run", "--hide-scrollbars", "about:blank",
], { stdio: ["ignore", "ignore", "ignore"] });
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const done = (code) => { try { proc.kill("SIGKILL"); } catch {} try { rmSync(udd, { recursive: true, force: true }); } catch {} process.exit(code); };
setTimeout(() => { console.error("timeout"); done(1); }, 120000);

let ws;
for (let i = 0; i < 100 && !ws; i++) {
  try {
    const page = (await (await fetch(`http://127.0.0.1:${port}/json/list`)).json()).find((t) => t.type === "page");
    if (page) {
      ws = new WebSocket(page.webSocketDebuggerUrl);
      await new Promise((r) => ws.addEventListener("open", r));
      break;
    }
  } catch {}
  await sleep(100);
}
if (!ws) { console.error("Chrome did not start"); done(1); }
let id = 0;
const pending = new Map();
const handlers = [];
const send = (method, params = {}) => new Promise((res) => { const i = ++id; pending.set(i, res); ws.send(JSON.stringify({ id: i, method, params })); });
const t0 = Date.now();
ws.addEventListener("message", (ev) => {
  const m = JSON.parse(ev.data);
  if (m.id && pending.has(m.id)) { pending.get(m.id)(m.result ?? m.error); pending.delete(m.id); return; }
  const ts = ((Date.now() - t0) / 1000).toFixed(2);
  if (m.method === "Runtime.consoleAPICalled") console.log(`[${ts}] console.${m.params.type}:`, m.params.args.map((a) => a.value ?? a.description).join(" "));
  if (m.method === "Runtime.exceptionThrown") console.log(`[${ts}] EXCEPTION:`, m.params.exceptionDetails.exception?.description ?? m.params.exceptionDetails.text);
  if (m.method === "Log.entryAdded") console.log(`[${ts}] log.${m.params.entry.level}:`, m.params.entry.text);
  for (const h of handlers) h(m);
});
await send("Runtime.enable");
await send("Log.enable");
await send("Page.enable");
await send("DOM.enable");
await send("Emulation.setDeviceMetricsOverride", { width, height, deviceScaleFactor: dpr, mobile: false });
if (opt["no-webgpu"]) await send("Page.addScriptToEvaluateOnNewDocument", { source: "Object.defineProperty(Navigator.prototype, 'gpu', { get: () => undefined });" });
await send("Page.navigate", { url });
await sleep(Number(opt.wait ?? 8000));

const mouse = (type, x, y, extra = {}) => send("Input.dispatchMouseEvent", { type, x, y, button: "left", clickCount: 1, ...extra });
if (opt.drag) {
  const [x1, y1, x2, y2] = opt.drag.split(",").map(Number);
  await mouse("mouseMoved", x1, y1, { button: "none" });
  await sleep(50);
  await mouse("mousePressed", x1, y1, { buttons: 1 });
  for (let i = 1; i <= 20; i++) { await mouse("mouseMoved", x1 + ((x2 - x1) * i) / 20, y1 + ((y2 - y1) * i) / 20, { buttons: 1 }); await sleep(30); }
  await mouse("mouseReleased", x2, y2);
}
if (opt.click) {
  let chosen = null;
  if (opt.pick) {
    const files = opt.pick.split(",").map((f) => resolve(f));
    await send("Page.setInterceptFileChooserDialog", { enabled: true });
    chosen = new Promise((res) => handlers.push(async (m) => {
      if (m.method !== "Page.fileChooserOpened") return;
      console.log(`file chooser opened (mode ${m.params.mode}); choosing ${files.length} file(s)`);
      await send("DOM.setFileInputFiles", { files, backendNodeId: m.params.backendNodeId });
      res(true);
    }));
  }
  const clicks = opt.click.split(";").map((p) => p.split(",").map(Number));
  for (const [i, [x, y]] of clicks.entries()) {
    if (i > 0) await sleep(4000);
    await mouse("mouseMoved", x, y, { button: "none" });
    await sleep(50);
    await mouse("mousePressed", x, y, { buttons: 1 });
    await sleep(50);
    await mouse("mouseReleased", x, y);
    if (i === 0 && chosen) {
      const ok = await Promise.race([chosen, sleep(5000).then(() => false)]);
      if (!ok) console.log("FAIL: no file chooser opened");
    }
  }
}
await sleep(Number(opt.after ?? 3000));

const info = await send("Runtime.evaluate", {
  expression: `JSON.stringify({gpu: !!navigator.gpu, canvas: [document.getElementById("canvas").width, document.getElementById("canvas").height], dpr: devicePixelRatio, error: document.getElementById("zoxel-error")?.textContent || null, heapMB: (typeof Module !== "undefined" && Module.HEAPU8) ? Math.round(Module.HEAPU8.length / 1048576) : null})`,
  returnByValue: true,
});
console.log("state:", info.result?.value);
const shot = await send("Page.captureScreenshot", { format: "png" });
writeFileSync(out, Buffer.from(shot.data, "base64"));
console.log("wrote", out);
done(0);
