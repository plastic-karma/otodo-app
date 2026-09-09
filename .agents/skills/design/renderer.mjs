import { mkdir, stat } from 'node:fs/promises';
import { join, resolve } from 'node:path';
import { pathToFileURL } from 'node:url';

/** Open an owned OMP browser tab. Pass the Eval prelude's browser explicitly. */
export async function openPreview(browser, { file, name = 'design-preview', app } = {}) {
  if (typeof file !== 'string' || !/\.html?$/i.test(file)) {
    throw new TypeError('file must name a generated local HTML preview');
  }
  const path = resolve(file);
  if (!(await stat(path)).isFile()) throw new TypeError('Preview path is not a file');
  const tab = await browser.open({ name, url: 'about:blank', ...(app ? { app } : {}) });
  try {
    await tab.run(async ({ page }, url) => {
      await page.setViewport({ width: 1200, height: 1000, deviceScaleFactor: 1 });
      await page.emulateMediaFeatures([{ name: 'prefers-reduced-motion', value: 'reduce' }]);
      await page.goto(url, { waitUntil: 'load' });
      await page.waitForSelector('iframe[data-artboard]', { timeout: 10000 });
    }, { args: [pathToFileURL(path).href] });
    return tab;
  } catch (error) {
    await browser.close({ name });
    throw error;
  }
}

/** Capture current state without navigating/reloading or resetting interactions. */
export async function capturePreview(tab, { outputDir } = {}) {
  if (typeof outputDir !== 'string' || !outputDir.trim()) {
    throw new TypeError('outputDir must name the screenshot destination directory');
  }
  const directory = resolve(outputDir);
  const artboardDirectory = join(directory, 'artboards');
  await mkdir(artboardDirectory, { recursive: true });
  return tab.run(async ({ page }, paths) => {
    const started = performance.now();
    await page.bringToFront();
    const frames = await page.evaluate(() => Array.from(
      document.querySelectorAll('iframe[data-artboard]'),
      element => ({
        id: element.dataset.artboard,
        width: Number(element.dataset.width),
        height: Number(element.dataset.height),
      }),
    ));
    if (!frames.length) throw new Error('No artboards found; generate the page with buildCanvas first');
    const handles = [];
    const artboards = [];
    const diagnostics = {
      page: await page.mainFrame().mainRealm().evaluate(() => {
        if (!Array.isArray(window.__ompDesignDiagnostics)) {
          throw new Error('Canvas diagnostics missing; rebuild the preview with buildCanvas');
        }
        return window.__ompDesignDiagnostics;
      }),
      artboards: [],
    };
    const ids = new Set();
    try {
      for (const board of frames) {
        if (!/^[A-Za-z0-9][A-Za-z0-9_-]{0,63}$/.test(board.id ?? '') || ids.has(board.id)) {
          throw new Error(`Invalid or duplicate artboard id: ${board.id}`);
        }
        if (!Number.isInteger(board.width) || !Number.isInteger(board.height)
            || board.width < 1 || board.height < 1 || board.width > 4096 || board.height > 4096) {
          throw new Error(`Invalid artboard dimensions: ${board.id}`);
        }
        ids.add(board.id);
        const handle = await page.$(`iframe[data-artboard="${board.id}"]`);
        if (!handle) throw new Error(`Artboard disappeared during capture: ${board.id}`);
        handles.push(handle);
        // Opaque-origin frames may not paint or run rAF while offscreen.
        await handle.evaluate(element => element.scrollIntoView({
          block: 'center', inline: 'center', behavior: 'instant',
        }));
        const frame = await handle.contentFrame();
        if (!frame) throw new Error(`Artboard has no browsing context: ${board.id}`);
        // OMP's default evaluation realm does not expose page-owned JS globals.
        const state = await frame.mainRealm().evaluate(async () => {
          if (!Array.isArray(window.__ompDesignDiagnostics)) {
            throw new Error('Artboard diagnostics missing; rebuild the preview with buildCanvas');
          }
          await document.fonts.ready;
          await Promise.all(Array.from(document.images, image => image.decode().catch(() => {})));
          await new Promise(done => requestAnimationFrame(() => requestAnimationFrame(done)));
          const root = document.documentElement;
          return {
            viewport: { width: innerWidth, height: innerHeight },
            scroll: { width: root.scrollWidth, height: root.scrollHeight },
            horizontalOverflow: root.scrollWidth > innerWidth,
            verticalOverflow: root.scrollHeight > innerHeight,
            brokenImages: Array.from(document.images)
              .filter(image => (image.currentSrc || image.getAttribute('src')) && image.naturalWidth === 0)
              .map(image => (image.currentSrc || image.getAttribute('src')).slice(0, 200)),
            messages: window.__ompDesignDiagnostics,
          };
        });
        if (state.viewport.width !== board.width || state.viewport.height !== board.height) {
          throw new Error(`Artboard ${board.id} viewport differs from its declared dimensions`);
        }
        const path = `${paths.directory}/${board.id}.png`;
        await handle.screenshot({ path });
        artboards.push({ ...board, path });
        diagnostics.artboards.push({ id: board.id, ...state });
      }
      await page.screenshot({ path: paths.overview, fullPage: true });
      diagnostics.captureMs = Math.round(performance.now() - started);
      return { overviewPath: paths.overview, artboards, diagnostics };
    } finally {
      await Promise.all(handles.map(handle => handle.dispose()));
    }
  }, { args: [{ directory: artboardDirectory, overview: join(directory, 'overview.png') }] });
}
