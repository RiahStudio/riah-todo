#!/usr/bin/env node
/**
 * Pin the fonts + Mac/Windows start surface so a later edit cannot silently
 * ship Georgia fallbacks, a Windows-only data folder, or the Usage-style
 * SetProcessDPIAware blur on Win11.
 *
 * Run:  node test/fonts-and-mac.mjs
 */

import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const ROOT = path.join(path.dirname(fileURLToPath(import.meta.url)), "..");
let failures = 0;

function check(name, pass, detail) {
  if (pass) console.log(`  ok   ${name}`);
  else {
    failures += 1;
    console.log(`  FAIL ${name}${detail ? " — " + detail : ""}`);
  }
}

const fontsCss = fs.readFileSync(path.join(ROOT, "assets", "fonts", "fonts.css"), "utf8");
const refs = [...fontsCss.matchAll(/url\('([^']+)'\)/g)].map((m) => m[1]);
const expected = [
  "instrument-serif-latin-400-normal.woff2",
  "instrument-serif-latin-400-italic.woff2",
  "space-grotesk-latin-400-normal.woff2",
  "space-grotesk-latin-500-normal.woff2",
  "space-grotesk-latin-600-normal.woff2",
  "space-grotesk-latin-700-normal.woff2",
  "space-mono-latin-400-normal.woff2",
  "space-mono-latin-700-normal.woff2",
];

console.log("\nBundled fonts");
check(
  "fonts.css names all eight faces",
  expected.every((f) => refs.includes(f)) && refs.length === 8,
  `got ${refs.join(", ")}`,
);

for (const rel of refs) {
  const p = path.join(ROOT, "assets", "fonts", rel);
  const buf = fs.existsSync(p) ? fs.readFileSync(p) : Buffer.alloc(0);
  check(`${rel} exists`, buf.length > 100, `bytes=${buf.length}`);
  check(
    `${rel} is wOFF2`,
    buf.subarray(0, 4).toString("ascii") === "wOF2",
    `magic=${buf.subarray(0, 4).toString("hex")}`,
  );
}

const ttfs = [
  "InstrumentSerif-Regular.ttf",
  "InstrumentSerif-Italic.ttf",
  "SpaceGrotesk-Regular.ttf",
  "SpaceGrotesk-Medium.ttf",
  "SpaceGrotesk-SemiBold.ttf",
  "SpaceGrotesk-Bold.ttf",
  "SpaceMono-Regular.ttf",
  "SpaceMono-Bold.ttf",
];
for (const name of ttfs) {
  const p = path.join(ROOT, "assets", "fonts", name);
  const buf = fs.existsSync(p) ? fs.readFileSync(p) : Buffer.alloc(0);
  check(`${name} exists for the Windows note`, buf.length > 100, `bytes=${buf.length}`);
}

const html = fs.readFileSync(path.join(ROOT, "index.html"), "utf8");
check("board loads local fonts.css, not a CDN", /href="assets\/fonts\/fonts\.css"/.test(html) && !/fonts\.googleapis/.test(html));
check("board asks for Instrument Serif", /Instrument Serif/.test(html));
check("board asks for Space Grotesk", /Space Grotesk/.test(html));
check("board asks for Space Mono", /Space Mono/.test(html));
check("Apple brand fallback (Iowan Old Style)", /Iowan Old Style/.test(html));
check("Apple UI fallback (-apple-system)", /-apple-system/.test(html));
check("Apple mono fallback (SFMono-Regular)", /SFMono-Regular/.test(html));
check("Safari smoothing", /-webkit-font-smoothing:\s*antialiased/.test(html));

const serve = fs.readFileSync(path.join(ROOT, "server.mjs"), "utf8");
check("board serves .woff2 as font/woff2 (Safari)", /"\.woff2":\s*"font\/woff2"/.test(serve));

const sh = fs.readFileSync(path.join(ROOT, "start.sh"));
check("start.sh has no Windows CR (macOS shebang survives)", !sh.includes(0x0d));
check("start.sh has a unix shebang", sh.subarray(0, 19).toString() === "#!/usr/bin/env bash");

const store = fs.readFileSync(path.join(ROOT, "lib", "store.mjs"), "utf8");
check(
  "Mac list lives in Application Support",
  store.includes("darwin") && store.includes("Application Support") && store.includes("Riah To-Do"),
);
check("Windows list still uses APPDATA", /APPDATA/.test(store));

const startBg = fs.readFileSync(path.join(ROOT, "start-background.mjs"), "utf8");
check("Mac start can open with `open`", /darwin/.test(startBg) && /exec\(`open/.test(startBg));
check("Mac/Linux start opens the board (no tray)", /process\.platform !== ["']win32["']/.test(startBg));

const tray = fs.readFileSync(path.join(ROOT, "tray", "riah-todo-tray.ps1"), "utf8");
check(
  "tray asks for Per-Monitor V2 DPI (Win11 sharpness)",
  tray.includes("SetProcessDpiAwarenessContext") && tray.includes("[IntPtr](-4)"),
);

const pkg = JSON.parse(fs.readFileSync(path.join(ROOT, "package.json"), "utf8"));
const osField = pkg.os;
check(
  "npm install is not Windows-only",
  !osField || (Array.isArray(osField) && osField.includes("darwin")),
  `os=${JSON.stringify(osField)}`,
);

console.log(failures === 0 ? "\nAll font/platform pins passed.\n" : `\n${failures} font/platform pin(s) FAILED.\n`);
process.exit(failures === 0 ? 0 : 1);
