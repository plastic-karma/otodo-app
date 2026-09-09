import { readFile } from 'node:fs/promises';

const MAX_BOARDS = 12;
const MAX_DIMENSION = 4096;
const MAX_HTML_LENGTH = 2_000_000;
const MAX_CODE_LENGTH = 512_000;

// Inline before screen code so errors are captured even when opened without OMP.
const diagnosticsScript = `<script>
(() => {
  const messages = [];
  Object.defineProperty(window, '__ompDesignDiagnostics', { value: messages });
  const record = (kind, message) => {
    if (messages.length < 100) messages.push({ kind, message: String(message).slice(0, 2000) });
  };
  window.addEventListener('error', event => {
    if (event.message) record('error', event.message);
    else if (event.target?.src || event.target?.href) {
      record('resource', event.target.src || event.target.href);
    }
  }, true);
  window.addEventListener('unhandledrejection', event => record('rejection', event.reason));
  const originalError = console.error;
  console.error = (...args) => {
    record('console.error', args.map(value => String(value)).join(' '));
    originalError.apply(console, args);
  };
})();
</script>`;

function string(value, name, min, max) {
  if (typeof value !== 'string' || value.length < min || value.length > max) {
    throw new TypeError(`${name} must be a string of ${min}–${max} characters`);
  }
  return value;
}

function escapeHTML(value) {
  return value.replace(/[&<>"']/g, character => ({
    '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;',
  })[character]);
}

function inlineJSON(value) {
  return JSON.stringify(value).replace(/[<\u2028\u2029]/g, character => ({
    '<': '\\u003c', '\u2028': '\\u2028', '\u2029': '\\u2029',
  })[character]);
}

function inlineCSS(value) {
  return value.replace(/<\/style/gi, '<\\/style');
}

function validateArtboards(artboards) {
  if (!Array.isArray(artboards) || artboards.length < 1 || artboards.length > MAX_BOARDS) {
    throw new TypeError(`artboards must contain 1–${MAX_BOARDS} screens`);
  }
  const ids = new Set();
  return artboards.map((board, index) => {
    const label = `artboards[${index}]`;
    if (!board || typeof board !== 'object' || Array.isArray(board)) {
      throw new TypeError(`${label} must be an object`);
    }
    const id = string(board.id, `${label}.id`, 1, 64);
    if (!/^[A-Za-z0-9][A-Za-z0-9_-]*$/.test(id)) {
      throw new TypeError(`${label}.id must start with a letter or number and use only letters, numbers, underscores or hyphens`);
    }
    if (ids.has(id)) throw new TypeError(`Duplicate artboard id: ${id}`);
    ids.add(id);
    for (const key of ['width', 'height']) {
      if (!Number.isInteger(board[key]) || board[key] < 1 || board[key] > MAX_DIMENSION) {
        throw new TypeError(`${label}.${key} must be an integer from 1 to ${MAX_DIMENSION} CSS pixels`);
      }
    }
    if (board.theme !== 'light' && board.theme !== 'dark') {
      throw new TypeError(`${label}.theme must be light or dark`);
    }
    return {
      id,
      title: string(board.title, `${label}.title`, 1, 512),
      width: board.width,
      height: board.height,
      theme: board.theme,
      html: string(board.html, `${label}.html`, 0, MAX_HTML_LENGTH),
      css: string(board.css === undefined ? '' : board.css, `${label}.css`, 0, MAX_CODE_LENGTH),
      js: string(board.js === undefined ? '' : board.js, `${label}.js`, 0, MAX_CODE_LENGTH),
    };
  });
}

function screenDocument(board, iosCSS) {
  const policy = "default-src 'none'; script-src 'unsafe-inline'; style-src 'unsafe-inline'; img-src data: blob:; font-src data: blob:; media-src data: blob:; connect-src 'none'; object-src 'none'; frame-src 'none'; worker-src 'none'; base-uri 'none'; form-action 'none'";
  return `<!doctype html>
<html lang="en" data-theme="${board.theme}">
<head>
<meta charset="utf-8">
<meta http-equiv="Content-Security-Policy" content="${escapeHTML(policy)}">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>${escapeHTML(board.title)}</title>
${diagnosticsScript}
<style>${inlineCSS(iosCSS)}</style>
<style>${inlineCSS(board.css)}</style>
<script>
// Prototype navigation belongs in screen JS. Do not follow external links.
document.addEventListener('click', event => {
  const link = event.target instanceof Element ? event.target.closest('a[href]') : null;
  if (link && !link.getAttribute('href').startsWith('#')) event.preventDefault();
}, true);
</script>
</head>
<body>
${board.html}
<script>
// Set textContent rather than interpolating executable code into HTML parsing.
{
  const screenScript = document.createElement('script');
  screenScript.textContent = ${inlineJSON(board.js)};
  document.body.append(screenScript);
}
</script>
</body>
</html>`;
}

/** Build a standalone browser approximation; html/css/js are authored screen code. */
export async function buildCanvas({ title, artboards } = {}) {
  string(title, 'title', 1, 512);
  const boards = validateArtboards(artboards);
  const [canvasCSS, iosCSS] = await Promise.all([
    readFile(new URL('./assets/canvas.css', import.meta.url), 'utf8'),
    readFile(new URL('./assets/ios.css', import.meta.url), 'utf8'),
  ]);
  const figures = boards.map(board => `<figure class="design-artboard" data-artboard-container="${board.id}">
<figcaption class="design-artboard-caption">
  <strong>${escapeHTML(board.title)}</strong>
  <span>${board.width} × ${board.height} CSS px · ${board.theme} · Browser approximation</span>
</figcaption>
<iframe title="${escapeHTML(board.title)} — browser approximation" data-artboard="${board.id}" data-title="${escapeHTML(board.title)}" data-width="${board.width}" data-height="${board.height}" width="${board.width}" height="${board.height}" style="width:${board.width}px;height:${board.height}px;border:0" sandbox="allow-scripts" referrerpolicy="no-referrer" srcdoc="${escapeHTML(screenDocument(board, iosCSS))}"></iframe>
</figure>`).join('\n');
  return `<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
${diagnosticsScript}
<title>${escapeHTML(title)} — Design canvas</title>
<style>${inlineCSS(canvasCSS)}</style>
</head>
<body>
<header class="design-header">
  <p class="design-eyebrow">Design canvas</p>
  <h1>${escapeHTML(title)}</h1>
  <p>Interactive browser approximations derived from source. Not native iOS renders.</p>
</header>
<main class="design-canvas" data-design-canvas aria-label="Design artboards">
${figures}
</main>
</body>
</html>`;
}
