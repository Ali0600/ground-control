#!/usr/bin/env node
/**
 * Record the project's demo GIF: drive the live dashboard with Playwright, capture one
 * frame set per scene, and write them to disk for ffmpeg to assemble.
 *
 * Playwright is NOT a dependency of this repo (it would pull a browser download into a
 * zero-dependency project). Run it from a checkout that already has it:
 *
 *     cd ~/nutrition-website && node ~/launchd-dashboard/scripts/record-demo.mjs
 *
 * The dashboard must be running on :8787. The page is loaded with `?demo=1`, which arms
 * masking BEFORE the first fetch — so no captured frame can contain a real IP, device
 * name or home path. `scripts/assemble-demo.sh` turns the frames into a GIF + MP4, and
 * re-scans the captured text for anything private before either is published.
 *
 * Scene text is written to frames/scenes.json for that privacy gate to read.
 */
import { createRequire } from "node:module";
import { mkdir, rm, writeFile } from "node:fs/promises";
import path from "node:path";

// ESM resolves imports from the SCRIPT's directory, and this repo has no node_modules
// by design — so resolve playwright from the working directory instead. That is exactly
// the "run me from a checkout that has playwright" contract in the header above.
const require = createRequire(path.join(process.cwd(), "noop.js"));
let chromium;
try {
  ({ chromium } = require("playwright"));
} catch {
  console.error(`playwright not resolvable from ${process.cwd()}\n` +
    "Run this from a checkout that has it, e.g.:\n" +
    "  cd ~/nutrition-website && node ~/launchd-dashboard/scripts/record-demo.mjs");
  process.exit(1);
}

const BASE = "http://127.0.0.1:8787";
const OUT = process.env.DEMO_OUT || "/tmp/launchddash-demo";
const FRAMES = path.join(OUT, "frames");
// The app whose Start we film. Must be STOPPED before recording and is stopped again
// in the finally block, so the recording leaves the machine as it found it.
const DEMO_APP = "waymark";

let frame = 0;
const scenes = [];

async function shoot(page, n = 8) {
  // Several identical frames per scene = a readable dwell at a fixed frame rate.
  for (let i = 0; i < n; i++) {
    await page.screenshot({ path: path.join(FRAMES, `f${String(frame++).padStart(4, "0")}.png`) });
  }
}

async function caption(page, text) {
  await page.evaluate((t) => { window.__cap(t); }, text);
  await page.waitForTimeout(250);
}

/** One scene: set the caption, let the UI settle, capture, and record the visible text
 *  so the privacy gate can assert over exactly what was filmed. */
async function scene(page, text, { before, dwell = 8, settle = 700 } = {}) {
  if (before) await before();
  await caption(page, text);
  await page.waitForTimeout(settle);
  await shoot(page, dwell);
  scenes.push({ caption: text, text: await page.evaluate(() => document.body.innerText) });
  console.log(`  ✓ ${text}`);
}

const main = async () => {
  await rm(OUT, { recursive: true, force: true });
  await mkdir(FRAMES, { recursive: true });

  const browser = await chromium.launch();
  const ctx = await browser.newContext({
    viewport: { width: 1280, height: 800 },
    deviceScaleFactor: 2,          // retina frames; downscaled at assembly = crisp text
    colorScheme: "dark",
    reducedMotion: "reduce",       // no half-finished transitions in a still frame
  });
  const page = await ctx.newPage();

  try {
    // Make sure the app we film starting is actually stopped first.
    await page.request.post(`${BASE}/api/apps/${DEMO_APP}/stop`).catch(() => {});
    await page.goto(`${BASE}/?demo=1`, { waitUntil: "networkidle" });

    // Fail closed: if masking didn't arm, everything downstream would film real data.
    // Check the OBSERVABLE state — `let demoMode` is a script-scope binding, not a
    // window property, so `window.demoMode` is undefined even when masking is on.
    const armed = await page.evaluate(() =>
      document.getElementById("demoToggle").checked && document.body.classList.contains("demo"));
    if (!armed) throw new Error("demo mode did not arm from ?demo=1 — refusing to record");

    // Caption overlay, injected ONLY for the recording (never part of the app).
    await page.addStyleTag({ content: `
      #__cap { position: fixed; left: 24px; bottom: 24px; z-index: 99999;
        background: #171a21; border: 1px solid #333845; border-left: 3px solid #f0b86e;
        color: #e7e9ee; font: 500 17px/1.45 -apple-system, BlinkMacSystemFont, sans-serif;
        padding: 12px 18px; border-radius: 10px; max-width: 620px;
        box-shadow: 0 8px 28px rgba(0,0,0,.55); }
      #__cap.hide { display: none; }
      * { caret-color: transparent !important; }
    `});
    await page.evaluate(() => {
      const el = document.createElement("div");
      el.id = "__cap";
      document.body.appendChild(el);
      window.__cap = (t) => { el.textContent = t; el.classList.toggle("hide", !t); };
    });

    const scrollTo = (sel) => page.evaluate((s) => {
      document.querySelector(s).scrollIntoView({ block: "center", behavior: "instant" });
    }, sel);

    console.log("recording…");

    await scene(page, "Every launchd agent and dev server on your Mac, in one place");

    await scene(page, "Start a dev server without hunting for a terminal", {
      before: async () => {
        await scrollTo("#applist");
        // Click Start on the demo app's row (title="Start", inside its row).
        await page.click(`[data-log-key="app:${DEMO_APP}"] button[title="Start"]`);
        // Wait for reality, not a timeout: the row must actually flip to running.
        await page.waitForFunction((slug) => {
          const row = document.querySelector(`[data-log-key="app:${slug}"]`);
          return row && row.innerText.includes("running");
        }, DEMO_APP, { timeout: 30000 });
      },
      settle: 1200,
      dwell: 10,
    });

    await scene(page, "It runs as a real launchd agent — status, exit code, logs", {
      before: () => scrollTo("#list"),
    });

    await scene(page, "Which project owns :3000? Every listening port, attributed", {
      before: () => scrollTo("#portlist"),
      dwell: 10,
    });

    await scene(page, "'exposed' = bound beyond loopback, reachable from your network");

    await scene(page, "It watches the network and alerts on what changes", {
      before: () => scrollTo("#watchlist"),
      dwell: 10,
    });

    await scene(page, "New listeners · LAN exposure · devices connecting · failed jobs");

    await scene(page, "Network History: every event, and every alert it sent", {
      before: async () => {
        await page.click("#histBtn");
        await page.waitForSelector("#histsheet.open");
        await page.waitForTimeout(600);
      },
      dwell: 10,
    });

    // Which event to expand. The card shows a FULL COMMAND LINE, so leaving it as
    // "whatever happened most recently" can put unrelated third-party software on
    // camera. DEMO_EVENT_MATCH picks a row you actually want to show off.
    const match = process.env.DEMO_EVENT_MATCH || "";
    await scene(page, "Click any event for the full picture — exit codes, run history", {
      before: async () => {
        const rows = page.locator("#histevents .evrow");
        const row = match ? rows.filter({ hasText: match }).first() : rows.first();
        if (await row.count() === 0) throw new Error(`no event matching "${match}"`);
        await row.click();
        await page.waitForSelector("#histevents .evcard");
        // An expanded card is tall; unscrolled it hangs off the bottom of the frame
        // and the run ledger — the whole point of the scene — never appears.
        await page.evaluate(() => document.querySelector("#histevents .evcard")
          .scrollIntoView({ block: "center", behavior: "instant" }));
      },
      dwell: 12,
    });

    await scene(page, "Every device that ever connected to your machine", {
      before: async () => {
        await page.locator("#histevents .evrow").first().click();  // collapse
        await page.evaluate(() => document.getElementById("histdevices")
          .scrollIntoView({ block: "center", behavior: "instant" }));
      },
      dwell: 10,
    });

    await scene(page, "Demo mode masks IPs, device names and paths for sharing", {
      before: async () => {
        await page.click("#sheetback");
        await page.waitForTimeout(400);
        await page.evaluate(() => window.scrollTo(0, 0));
      },
      dwell: 12,
    });

    await writeFile(path.join(OUT, "scenes.json"), JSON.stringify(scenes, null, 1));
    console.log(`\n${frame} frames → ${FRAMES}`);
  } finally {
    // Leave the machine as we found it, whatever happened above.
    await page.request.post(`${BASE}/api/apps/${DEMO_APP}/stop`).catch(() => {});
    await browser.close();
    console.log(`stopped ${DEMO_APP} again`);
  }
};

main().catch((e) => { console.error(e); process.exit(1); });
