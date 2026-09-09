---
name: design
description: >
  Reconstruct complete app UI screens from source as browser previews and PNG
  images, explore design alternatives when requested, and refine from inspected
  screenshots. Use for source-to-image iOS UI reconstruction, interactive web
  approximations, visual design comparisons, and screenshot-driven iteration.
---

# Source → browser → image

Invoke with `/skill:design` in this repository. This is developer tooling, not
an iOS app change. Default to preserving the source design, content hierarchy,
and behavior. Explore alternatives only when the user requests them; retain a
source-faithful baseline for comparison. Finish the requested screens and
interactions, not just a component or row unless that is the explicit scope.

## Prerequisites

- Use the existing OMP `read`, `glob`, `grep`, `write`, and JavaScript `eval`
  tools. `browser` is an Eval prelude, **not** a standalone tool; Eval and
  `browser.enabled` must be enabled. Use installed Chromium or an explicitly
  selected, verified CDP browser. No npm/React project, global installation,
  image-generation service, or native simulator is required.
- The configured `openai-codex/gpt-6-astra` route advertises text and image
  **input**. Astra authors HTML/CSS/JS; Chromium produces the PNGs. If the
  active route or its capability is unknown, run
  `omp models find gpt-6-astra --json` (substitute the actual active model)
  and inspect the matching provider/selector's `input` array. Resolve any
  applicable local overrides before assuming image support. Do not infer
  capability from a model name. If the active model lacks image input, transparently use
  an available image-capable reviewer with the actual captures, name that
  reviewer in the handoff, and apply its findings. Never pretend a text-only
  inspection is a visual review or silently replace an image-capable Astra.
- Resolve the absolute directory containing this loaded `SKILL.md`; its
  siblings are `canvas.mjs`, `renderer.mjs`, and `assets/`. Reuse these modules
  and the same owned preview tab across iterations.

## Extract only what the screen needs

1. Identify the requested screen(s), viewport(s), theme(s), and state. Follow
   scoped dependencies: the screen view, child views, navigation/sheets,
   relevant models and state transitions, theme tokens, asset catalogs, and
   any formatting/localization affecting visible content. Do not audit the
   whole repository or create a mandatory plan/brand-approval document.
2. Preserve actual spacing, colors, typography hierarchy, safe-area layout,
   scroll behavior, controls, empty/loading/error states and relevant
   interactions. Read source sections rather than guessing from filenames.
   Implement the specific prototype interactions requested (for example,
   toggling completion, opening a sheet, changing a filter) in screen JS with
   observable in-memory state. Do not substitute decorative dead controls.
3. Use supplied sample state; otherwise derive a representative fixture and
   label invented values. Code-only reconstruction is supported. Existing
   native screenshots can calibrate fidelity but are never required. Embed
   available images/fonts as data URLs; use inline SVG or CSS for necessary
   local graphics. Record substitutions; do not invent a native screenshot.

## Editable output contract

Use the user's selected output directory. If none is specified, use a dedicated
`/tmp/otodo-design-<screen>` directory; an explicitly chosen `research/`
directory is also suitable. Keep generated artifacts out of shipped app source.
Use `write` to create `inputs.json` there, containing JSON **data**, not a JS
module. Record alongside the artboards:

- `title`, `approximation: "Browser approximation, not native iOS rendering"`;
- `sourceInputs`: actual source/asset paths, symbols or line ranges used, and
  revision/hash or extracted values sufficient to identify the source snapshot;
- `sampleState`: the supplied/derived fixture and which values were invented;
- `assumptions`: missing assets, font/icon substitutions, native behavior limits;
- `interactions`: requested actions, starting state, selectors, and observable
  expected results, so they can be replayed after a reload;
- `artboards`: complete screens in the following builder shape.

```text
{ id, title, width, height, theme: "light" | "dark", html, css: "", js: "" }
```

`html` is authored screen markup; `css` and `js` are optional strings, not a
screen DSL. Dimensions are integer CSS pixels, 1–4096; supply 1–12 artboards.
IDs must be unique and match `[A-Za-z0-9][A-Za-z0-9_-]{0,63}`. Titles are nonempty strings
up to 512 characters. HTML is limited to 2,000,000 characters and each CSS/JS
string to 512,000. Use stable IDs and useful captions for states/alternatives.
Inspect `assets/ios.css` before using its helpers; it is optional shared styling,
not a replacement for reading the app's own design.

Each artboard runs in its own fixed-size `iframe` with `sandbox="allow-scripts"`
and no same-origin privilege. Its root has `data-theme`; shared `ios.css`
precedes screen CSS. CSP disables network subresources and fetches. Use
embedded assets, inline code and in-memory state, not imports, storage or
parent-page DOM access. This is prototype isolation, not a hardened sandbox
for untrusted code: scripts can still navigate their own frame. Captions
identify these as browser approximations.

## Build, render, inspect

First author complete `inputs.json` with the `write` tool. Then run this recipe
in JavaScript Eval from the repository root, setting the output directory as
needed. If OMP was started elsewhere, set `designSkillDir` to the absolute
directory containing the loaded skill instead. Choose an installed browser
executable with `which chromium` (or the available
Chrome equivalent) rather than installing one. Explicit headless selection
avoids accidentally adopting a user's visible browser through relay defaults.
Choose a new tab name if `design-preview` already belongs to unrelated work;
reuse a handle only when this workflow created it.

```js
const designSkillDir = `${process.cwd()}/.agents/skills/design`;
const designOutputDir = "/tmp/otodo-design-screen";
const designBrowserName = "design-preview";
const { buildCanvas } = await import(`${designSkillDir}/canvas.mjs`);
const { openPreview, capturePreview } = await import(`${designSkillDir}/renderer.mjs`);
```

Build in the next Eval cell:

```js
let designInputs = JSON.parse(await read(`${designOutputDir}/inputs.json`));
const designHtmlPath = `${designOutputDir}/preview.html`;
await tool.write({
  i: "Writing complete screen preview",
  path: designHtmlPath,
  content: await buildCanvas({ title: designInputs.title, artboards: designInputs.artboards }),
});
```

Open once in another cell:

```js
const designApp = { path: "/usr/bin/chromium", args: ["--headless", "--disable-gpu"] };
const designTab = await openPreview(browser, {
  file: designHtmlPath, name: designBrowserName, app: designApp,
});
```

Capture in its own cell and save results immediately. Keep navigation,
measurement and capture steps separate so a runtime timeout cannot discard
the entire review record.

```js
let designCapture = await capturePreview(designTab, { outputDir: designOutputDir });
await tool.write({
  i: "Recording preview capture paths",
  path: `${designOutputDir}/captures.json`,
  content: JSON.stringify(designCapture, null, 2),
});
display(designCapture);
```

The three exports are:

- `await buildCanvas({title, artboards})` → self-contained HTML string.
- `await openPreview(browser, {file, name?, app?})` → owned preview tab;
  default name `design-preview`. `file` is the absolute generated HTML path.
- `await capturePreview(tab, {outputDir})` →
  `{overviewPath, artboards: [{id, path, width, height}], diagnostics}`.
  It brings each iframe into view, waits for fonts/images and two paint frames,
  and captures **without reloading or changing the screen's own scroll position**.
  The outer workbench may scroll. Individual images live in `artboards/` to
  avoid colliding with `overview.png`. Diagnostics report overflow, resource and
  runtime problems; they do not replace looking at pixels.

Use `read` on the returned `overviewPath` and **each** returned artboard `path`
to see actual PNG pixels. Do not stop at paths, DOM text, or a successful
capture call. Compare the complete composition against source and any supplied
reference: content coverage, clipping, spacing, alignment, contrast, typography,
icons, safe areas, navigation and scrolling. Fix observed defects, recapture,
and inspect again. Distinguish intentional scroll regions from unintended
page overflow; explain any unresolved diagnostics.

## Browser connection fallback

If a default connection fails, do not repeatedly retry or navigate the user's
visible tab. Pass explicit `app` to `openPreview`, as above. If direct executable
launch is unavailable, start a dedicated headless browser with `hub`:

```text
op: start
name: design-chromium
application: /usr/bin/chromium
args: [--headless, --disable-gpu, --remote-debugging-address=127.0.0.1,
       --remote-debugging-port=9222, --user-data-dir=/tmp/otodo-design-cdp, about:blank]
ready: {port: 9222, timeout: 30}
```

Choose an unused port and a dedicated profile directory for this task. Verify
`http://127.0.0.1:9222/json/version` with `read` after readiness; then use
`app: {cdp_url: "http://127.0.0.1:9222"}`. Do not attach an arbitrary existing
endpoint or start a service through `bash`. Close any owned failed tab handle
before reusing its name with a different browser kind. CDP attachment creates a
preview page; do not navigate unrelated pages. Report a missing browser/runtime
prerequisite honestly if neither route is available.

## Interactions and refinement

Use `await designTab.observe()` for the workbench. Artboards have
`iframe[data-artboard="<id>"]` plus `data-title`, `data-width`, and
`data-height`. To exercise a screen use `designTab.run(async ({page}, ...) =>
{ ... }, {args: [...]})`, select that iframe with `page.$`, and obtain its
Puppeteer frame with `await iframe.contentFrame()`. Use frame selectors to
click/type and assert the recorded observable result. Cross-origin sandboxing
means parent-page `contentDocument` is not an interaction API. `tab.run`
functions cannot capture Eval variables: pass plain data through `args`.
DOM queries work with `frame.evaluate`; to inspect page-owned JavaScript
globals use `frame.mainRealm().evaluate` explicitly. OMP's default evaluation
realm is isolated from those globals. Opaque-origin errors can be reported as
`Script error.`; that is a real diagnostic, not a clean run.
Verify each requested action and capture its resulting state; an event handler
in the source is not proof of a working interaction. Do not reload between an
action and its capture. Keep separate output subdirectories for evidence of
multiple states so later captures do not overwrite them.

For pointer verification inside scrolled iframes, combine the frame origin
with the control's local rectangle. Example for the All filter (substitute
the recorded control selector for other screens):

```js
await designTab.run(async ({page}, id, selector) => {
  const iframe = await page.$(`iframe[data-artboard="${id}"]`);
  const frame = await iframe.contentFrame();
  const point = await frame.evaluate(selector => {
    const element = document.querySelector(selector);
    element.scrollIntoView({block: "nearest", inline: "nearest"});
    const rect = element.getBoundingClientRect();
    return {x: rect.x + rect.width / 2, y: rect.y + rect.height / 2};
  }, selector);
  const origin = await iframe.boundingBox();
  await page.mouse.click(origin.x + point.x, origin.y + point.y);
  await iframe.dispose();
}, {args: [designInputs.artboards[0].id, '[data-filter="all"]']});
```

Then assert the visible result. Do not silently replace an ineffective pointer
action with DOM `element.click()` and claim pointer verification.

For a visual/source revision, edit `inputs.json` (or update it to reflect any
exploratory HTML edit), regenerate the editable HTML, then reload **the same**
tab. This resets screen state, unlike `capturePreview`; replay recorded actions
if reviewing a non-initial state. Reuse Eval bindings instead of redeclaring
imports or opening additional tabs:

```js
designInputs = JSON.parse(await read(`${designOutputDir}/inputs.json`));
await tool.write({
  i: "Updating complete screen preview",
  path: designHtmlPath,
  content: await buildCanvas({ title: designInputs.title, artboards: designInputs.artboards }),
});
```

Refresh through the direct navigation helper in its own cell:

```js
await designTab.goto(await designTab.url(), {wait_until: "domcontentloaded"});
```

Then capture and record in another cell:

```js
designCapture = await capturePreview(designTab, { outputDir: designOutputDir });
await tool.write({
  i: "Updating preview capture paths",
  path: `${designOutputDir}/captures.json`,
  content: JSON.stringify(designCapture, null, 2),
});
display(designCapture);
```

Read the new PNGs again. At completion, close only the tab/browser owned by this
workflow with `await browser.close({name: designBrowserName, kill: true})`.
If a dedicated `hub` process was started, stop only its recorded name; attached
CDP pages/processes are not killed by releasing the browser handle. Do not use
`all: true` or stop a pre-existing/shared browser.

Deliver paths to `inputs.json`, editable `preview.html`, `captures.json`, the
overview and individual screen/state PNGs, with actions exercised and any
unresolved limitations. These are **web approximations**, not native SwiftUI
renders: system fonts/SF Symbols, text metrics, safe areas, materials/blur,
keyboards, gestures, accessibility, animation, and platform navigation can
differ. State where source fidelity was retained versus consciously changed;
never claim simulator, native accessibility, or production behavior validation
from this browser workflow alone.
