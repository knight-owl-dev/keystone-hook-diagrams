'use strict';

// server.js — A Keystone hook that renders mermaid fences.
//
// Two operations. `describe` introduces the hook and is asked nothing, so it is
// the one exchange no protocol version can change. `transform` returns content
// plus the assets that content references, choosing the asset by the format
// being built.
//
// Node owns the socket instead of socat because one Chromium then serves the
// whole build. mermaid renders in the page rather than through mermaid-cli,
// which launches a browser per invocation.
//
// https://keystone.knight-owl.dev/engine/writing-a-hook/

const net = require('node:net');
const fs = require('node:fs');
const path = require('node:path');
const puppeteer = require('puppeteer-core');
const { execFileSync } = require('node:child_process');

// Required, with no default: Keystone settles a language collision by sort order
// over socket filenames, so a name chosen here would take that lever from the
// caller. Checked before main(): a browser start is wasted on a container that
// cannot bind, and main()'s handler answers with a stack rather than a message.
const SOCKET = (process.env.HOOK_SOCKET || '').trim();
if (!SOCKET) {
  process.stderr.write(
    'HOOK_SOCKET is required: the path this hook binds, e.g. /hooks/diagrams.sock\n',
  );
  process.exit(1);
}

const PROTOCOLS = [1];
const TARGETS = ['mermaid'];

// The release tag, stamped in by the build. See identity().
const IMAGE_VERSION = (process.env.IMAGE_VERSION || '').trim();

// PDF takes a raster because the typesetter reads the file itself and cannot
// read SVG; DOCX and ODT take one to avoid depending on the writer's SVG
// handling. EPUB takes SVG, which scales to whatever page the reader is on.
const RASTER_FORMATS = new Set(['pdf', 'docx', 'odt']);
const VECTOR_FORMATS = new Set(['epub']);

// The same split, as `describe` states it: which formats share one answer, and
// nothing about what the answer is. Keystone's cache then recognizes the second
// and third of a group as questions it has already answered, so a book built in
// all three formats renders each diagram once.
//
// Built from the sets above rather than written out again — a format Keystone
// was told shares an answer, and that is answered differently here, would put
// one format's picture in another format's book.
const FORMAT_GROUPS = [[...RASTER_FORMATS], [...VECTOR_FORMATS]];

// Laid out at this width and captured at RASTER_SCALE, a diagram across a
// six-inch text block lands near 400 DPI.
const RASTER_WIDTH = 800;
const RASTER_SCALE = 3;

// The intrinsic width stamped on an SVG. Any value past a reader's text width
// does the job — see withIntrinsicSize.
const NOMINAL_WIDTH = 1600;

// The palette this book is drawn with, from the template's project.conf by way
// of the compose file. Keystone passes it through without knowing what it is:
// a renderer's settings are the renderer's, and nothing in the engine or the
// protocol has a name for this one.
//
// Unset resolves here rather than at each use, so nothing downstream can tell
// it from `default`. identity() included: two spellings would cache one render
// under two keys.
const PROJECT_THEME =
  (process.env.KEYSTONE_DIAGRAMS_THEME || '').trim() || 'default';

// The rest of the book's house style, applied the same way and equally the
// renderer's own business.
//
// The look resolves like the theme above. The font has no one default to
// resolve to, and goes unchecked besides: it is a CSS stack, so a name Chromium
// cannot find falls through to a generic family, which is what a stack is for.
const PROJECT_FONT = (process.env.KEYSTONE_DIAGRAMS_FONT || '').trim();
const PROJECT_LOOK =
  (process.env.KEYSTONE_DIAGRAMS_LOOK || '').trim() || 'classic';

// Mermaid ignores a theme or a look it does not know and draws its default
// instead, so a typo in either would restyle a whole book in silence.
const THEMES = new Set(['default', 'base', 'dark', 'forest', 'neutral']);
const LOOKS = new Set(['classic', 'handDrawn']);

// There is deliberately no lettering size here. A figure is scaled by the
// container it is placed in, so a size set at render time does not survive to
// the page: mermaid lays a diagram out around its text, and the wider diagram a
// larger size produces is then scaled down further. Measured, a 2.8x change in
// the requested size reached the page as 1.9x, and by a factor that differed per
// diagram. What decides the size on the page is the width the wrapper gives it.
function houseStyle() {
  const style = { theme: PROJECT_THEME, look: PROJECT_LOOK };
  if (PROJECT_FONT) style.themeVariables = { fontFamily: PROJECT_FONT };
  return style;
}

// What Keystone hashes into its cache key, and never reads — so the shape is
// ours. It has to be identical across runs, and different whenever a block
// would render differently.
//
// The version carries everything else that decides a picture — mermaid,
// Chromium, the raster geometry, the installed fonts — since the image fixes
// those, and an image cannot publish twice under one version
// (scripts/compute-build-matrix.sh).
//
// A `local` build promises neither: it restamps one version over an edited
// server.js. Sending none costs the cache and keeps the renders correct.
function identity() {
  if (!IMAGE_VERSION || IMAGE_VERSION === 'local') return null;
  // An unset font is spelled empty, so unset stays distinct from set.
  return `${IMAGE_VERSION}/theme=${PROJECT_THEME}/font=${PROJECT_FONT}/look=${PROJECT_LOOK}`;
}

// What is wrong with how this hook was configured, for `describe` to carry.
//
// It belongs there rather than in a transform: the settings come from the
// project that wired the hook in, so they are neither a block's fault nor
// something to discover on the first fence. `describe` is also asked whether or
// not the manuscript holds a diagram, so a book that misconfigured this and
// wrote none still hears about it.
//
// A value mermaid does not know is an error, because it would otherwise be
// ignored and the whole book restyled in silence. A font it cannot resolve is a
// warning: a stack is meant to fall through, and the fallback is legible.
function houseStyleDiagnostics() {
  const diagnostics = [];

  const wrong = (setting, value, kind, allowed) =>
    `this book sets ${setting} to '${value}', which is not a mermaid ${kind}\n` +
    `  Set ${setting} in project.conf to one of ${[...allowed].sort().join(', ')}, ` +
    'or leave it empty.';

  if (!THEMES.has(PROJECT_THEME)) {
    diagnostics.push({
      severity: 'error',
      message: wrong('KEYSTONE_DIAGRAMS_THEME', PROJECT_THEME, 'theme', THEMES),
    });
  }
  if (!LOOKS.has(PROJECT_LOOK)) {
    diagnostics.push({
      severity: 'error',
      message: wrong('KEYSTONE_DIAGRAMS_LOOK', PROJECT_LOOK, 'look', LOOKS),
    });
  }

  const missing = unavailableFonts(PROJECT_FONT);
  if (missing.length) {
    diagnostics.push({
      severity: 'warning',
      message:
        `this renderer has no ${missing.map((f) => `'${f}'`).join(' or ')}, ` +
        `named in KEYSTONE_DIAGRAMS_FONT\n` +
        `  Diagrams will letter in whatever else that stack resolves to. ` +
        `Installed: ${installedFamilies().join(', ')}.`,
    });
  }

  return diagnostics;
}

// The weight and width names fontconfig appends to a family.
const WEIGHT_SUFFIX =
  /\s+(Thin|ExtraLight|Light|Medium|SemiBold|Bold|ExtraBold|Black|Condensed|Italic|Oblique)+$/i;

// The font families this image carries, as fontconfig reports them.
//
// Read once and cached: it shells out, and the answer cannot change while the
// container runs.
let families = null;
function installedFamilies() {
  if (families) return families;

  try {
    const listed = execFileSync('fc-list', [':', 'family'], {
      encoding: 'utf8',
    });
    const seen = new Set();
    for (const line of listed.split('\n')) {
      for (const name of line.split(',')) {
        // fontconfig names every weight and width as its own family, so the
        // eight faces of one typeface would otherwise read as eight choices.
        const family = name.trim().replace(WEIGHT_SUFFIX, '').trim();
        if (family) seen.add(family);
      }
    }
    families = [...seen].sort();
  } catch {
    // Without fontconfig there is nothing to check against, and refusing to
    // start over a diagnostic would be worse than not making it.
    families = [];
  }
  return families;
}

// The named families in a CSS stack that this renderer cannot resolve.
//
// Generic families are skipped: they are the fallback the stack exists to reach,
// and fontconfig answers for them whatever is installed.
const GENERIC_FAMILIES = new Set([
  'serif',
  'sans-serif',
  'monospace',
  'cursive',
  'fantasy',
  'system-ui',
  'ui-serif',
  'ui-sans-serif',
  'ui-monospace',
  'ui-rounded',
  'math',
  'emoji',
  'fangsong',
]);

function unavailableFonts(stack) {
  if (!stack) return [];

  const installed = installedFamilies();
  if (!installed.length) return [];

  const lowered = new Set(installed.map((f) => f.toLowerCase()));
  return stack
    .split(',')
    .map((name) => name.trim().replace(/^["']|["']$/g, ''))
    .filter((name) => name && !GENERIC_FAMILIES.has(name.toLowerCase()))
    .filter((name) => !lowered.has(name.toLowerCase()));
}

// Mermaid's own configuration directives. Anything else in `%%{…}%%` is a
// misspelling the format ignores in silence, which is the one thing only this
// hook can catch.
const DIRECTIVES = new Set(['init', 'initialize']);

// The id mermaid keys a diagram's CSS to, and so what withBackground's rule
// must select.
const ELEMENT_ID = 'ks-diagram';

// ── Reading the block ────────────────────────────────────────────────

// A refusal the author should see, as opposed to a fault in this hook.
class Refused extends Error {}

// Mermaid's own frontmatter, which is where a diagram states its title. The
// title becomes the image's alt text: a caption is the format's to name, and
// Keystone parses nothing inside the block.
//
// It is escaped on the way out, because the reply is markdown: a title holding
// a bracket or a backtick would otherwise close the image early and reach the
// book as literal text, taking the figure's width and identifier with it.
function readTitle(content) {
  const block = /^---\r?\n([\s\S]*?)\r?\n---[ \t]*\r?\n/.exec(content);
  if (!block) return null;

  const title = /^title:[ \t]*(.+?)[ \t]*$/m.exec(block[1]);
  if (!title) return null;

  const bare = title[1].replace(/^(["'])([\s\S]*)\1$/, '$2');
  return bare.replace(/([\\`[\]])/g, '\\$1');
}

// Blank the title out of the frontmatter before rendering.
//
// Keystone owns the caption: the title comes back as the image's alt text and
// the figure handler sets it below the picture. Mermaid would otherwise also
// draw it inside the diagram, so the book carries it twice, in two typefaces.
//
// The line is emptied rather than removed. Mermaid's parse errors are
// positioned by line, and dropping one here would shift every number reported
// after it away from the block the author is looking at.
function withoutTitle(content) {
  const block = /^---\r?\n([\s\S]*?)\r?\n---[ \t]*\r?\n/.exec(content);
  if (!block) return content;

  const blanked = block[0].replace(/^title:[ \t]*.*$/m, '');
  return blanked + content.slice(block[0].length);
}

// How many lines mermaid strips before it starts counting. Its parse errors are
// positioned in what is left, so this is what maps one back to the block the
// author wrote.
function frontmatterLines(content) {
  const block = /^---\r?\n([\s\S]*?)\r?\n---[ \t]*\r?\n/.exec(content);
  return block ? block[0].split('\n').length - 1 : 0;
}

// Refuse a directive mermaid will not act on. Mermaid ignores an unknown one
// silently, so a typo produces a diagram that renders and is quietly wrong.
function checkDirectives(content) {
  const lines = content.split('\n');

  for (let index = 0; index < lines.length; index += 1) {
    const found = /%%\{\s*(?:"([^"]+)"|'([^']+)'|([A-Za-z_][\w-]*))\s*:/.exec(
      lines[index],
    );
    if (!found) continue;

    const name = found[1] || found[2] || found[3];
    if (DIRECTIVES.has(name)) continue;

    const known = [...DIRECTIVES].map((each) => `'${each}'`).join(' and ');
    throw new Refused(
      `unknown directive '${name}' on line ${index + 1}\n` +
        `  Only ${known} configure a diagram. Mermaid ignores anything else without saying so.`,
    );
  }
}

// Mermaid's parse errors are about its grammar, not about the author's diagram:
// a caret drawn under a line that has had its newlines removed, an "Expecting
// 'LINK', 'UNICODE_TEXT', 'EDGE_TEXT'" naming lexer states, and a "got" that is
// a state number rather than anything in the source. None of it means anything
// to someone looking at a fence.
//
// What is worth keeping is the position, and the author's own line is a better
// way to show it than any of mermaid's rendering. Two corrections get there:
// mermaid counts from the diagram left after its frontmatter is stripped, and
// it reports one line further down than the fault. Both were measured rather
// than documented, so a number that lands outside the block is dropped along
// with the quote instead of being reported wrong.
function refusalFrom(message, content) {
  const flat = String(message).replace(/\s+/g, ' ').trim();

  if (/No diagram type detected/i.test(flat)) {
    return (
      'no diagram type on the first line\n' +
      "  A mermaid block opens with its type — 'flowchart LR', 'sequenceDiagram', 'gantt'."
    );
  }

  const parse = /Parse error on line (\d+)/.exec(flat);
  if (parse) {
    const lines = content.split('\n');
    const offset = frontmatterLines(content);
    const index = offset + Number(parse[1]) - 2;

    if (index >= 0 && index < lines.length) {
      const source = lines[index].trim();
      const at = `line ${index + 1}`;
      return source
        ? `${at}: mermaid could not parse '${source}'`
        : `${at}: mermaid could not parse this line`;
    }
    return 'mermaid could not parse this diagram';
  }

  const bare = flat.replace(/^Error:\s*/i, '').replace(/[.\s]+$/, '');
  return bare || 'mermaid could not parse this diagram';
}

// ── Rendering ────────────────────────────────────────────────────────

let browser = null;
let renderPage = null;
let rasterPage = null;

// Renders run one at a time.
//
// The two pages above are shared, and a render is several round trips to one of
// them — set the content, size it, find the node, capture it. Two in flight
// interleave: the second replaces the page while the first is still reading it,
// and the first comes back as another block's picture or as "Node is detached
// from document". Keystone drives this serially, one connection per block, but
// nothing about a socket says one caller at a time and this image is publishable
// on its own.
//
// The chain is never left rejected, so one failed render does not strand the
// renders queued behind it.
let pending = Promise.resolve();

function serialize(work) {
  const done = pending.then(work, work);
  pending = done.then(
    () => {},
    () => {},
  );
  return done;
}

// One render, and the background its theme resolved to.
//
// The background comes back from mermaid rather than from a constant here,
// because an `init` directive in the block overrides the theme asked for — so
// what was rendered is the only reliable account of what was rendered.
async function renderSvg(content, style) {
  return renderPage.evaluate(
    async (source, style, elementId) => {
      window.mermaid.initialize({
        startOnLoad: false,
        securityLevel: 'strict',
        ...style,
      });
      const { svg } = await window.mermaid.render(elementId, source);

      const config = window.mermaid.mermaidAPI.getConfig();
      const background = config.themeVariables?.background || 'white';
      return { svg, background };
    },
    content,
    style,
    ELEMENT_ID,
  );
}

// Give the SVG an intrinsic size, large enough to fill the figure it is put in.
//
// Two things make this necessary. Keystone hands the reader an `<img>` whose
// source is the SVG, and an `<img>` is laid out from the file's intrinsic width
// and height — CSS written inside the file styles its contents, never the box
// the reader gives it. And the stylesheet caps a figure's image at the
// container rather than stretching it, which is right for a photograph, whose
// pixels run out.
//
// A diagram's pixels do not. Mermaid's natural width is a product of its font
// metrics — a four-label flowchart comes out a couple of hundred pixels wide —
// and honoring that would leave `width=80%` sizing a container around a
// picture that ignored it, with the caption shrink-wrapped to the picture. It
// would also disagree with the same book's PDF, where the raster does fill.
//
// So the width is nominal rather than natural: wide enough that the cap always
// binds, which makes the author's `width` the thing that decides, in every
// format. The height follows the viewBox, so nothing is stretched.
function withIntrinsicSize(svg) {
  const box = /viewBox="([\d.-]+) ([\d.-]+) ([\d.]+) ([\d.]+)"/.exec(svg);
  if (!box) return svg;

  const ratio = Number(box[4]) / Number(box[3]);
  const height = Math.round(NOMINAL_WIDTH * ratio);

  return svg
    .replace(/^(<svg\b[^>]*?)\swidth="[^"]*"/, '$1')
    .replace(/^(<svg\b[^>]*?)\sheight="[^"]*"/, '$1')
    .replace(/^(<svg\b[^>]*?)\sstyle="[^"]*"/, '$1')
    .replace(/^<svg\b/, `<svg width="${NOMINAL_WIDTH}" height="${height}"`);
}

// Paint the diagram's own background into the SVG, opaquely.
//
// Mermaid draws none, and the page behind an EPUB figure is the reader's to
// theme: unpainted, a light palette's strokes vanish under night mode.
function withBackground(diagram) {
  return diagram.svg.replace(
    /<\/style>/,
    `</style><style>#${ELEMENT_ID}{background-color:${diagram.background}}</style>`,
  );
}

// Rasterize an SVG.
//
// Mermaid sizes an SVG to the diagram's natural extent, which for a small
// flowchart is a couple of hundred pixels — laid out across a six-inch text
// block that is nowhere near print resolution. The source is vector, so the
// size it is drawn at is free: it is laid out at RASTER_WIDTH and captured at
// RASTER_SCALE, which puts any diagram near 400 DPI wherever the author places
// it. The height follows the viewBox, so nothing is stretched.
async function rasterize(diagram) {
  await rasterPage.setContent(
    `<!doctype html><html><body style="margin:0;background:${diagram.background}">${diagram.svg}</body></html>`,
    { waitUntil: 'load' },
  );

  const sized = await rasterPage.evaluate((width) => {
    const svgElement = document.querySelector('svg');
    if (!svgElement) return false;

    const box = svgElement.viewBox.baseVal;
    const ratio = box?.width ? box.height / box.width : 1;
    svgElement.setAttribute('width', String(width));
    svgElement.setAttribute('height', String(Math.round(width * ratio)));
    svgElement.style.maxWidth = 'none';
    return true;
  }, RASTER_WIDTH);
  if (!sized) throw new Error('the rendered SVG did not reach the raster page');

  const element = await rasterPage.$('svg');
  return element.screenshot({ type: 'png', omitBackground: false });
}

// ── The protocol ─────────────────────────────────────────────────────

async function transform(request) {
  const content = String(request.content ?? '');
  checkDirectives(content);

  // No title, no alt text: Pandoc builds a figure's caption out of it, so a
  // stand-in would caption every untitled diagram with the word "Diagram".
  const alt = readTitle(content) || '';
  const raster = RASTER_FORMATS.has(request.format);

  const drawable = withoutTitle(content);

  let diagram;
  try {
    diagram = await renderSvg(drawable, houseStyle());
  } catch (cause) {
    throw new Refused(refusalFrom(cause?.message, content));
  }

  let reply;
  if (raster) {
    const png = await rasterize(diagram);
    reply = {
      body: `![${alt}](diagram.png)`,
      assets: [
        {
          name: 'diagram.png',
          media_type: 'image/png',
          data: png.toString('base64'),
        },
      ],
    };
  } else {
    const svg = withIntrinsicSize(withBackground(diagram));
    reply = {
      body: `![${alt}](diagram.svg)`,
      assets: [
        {
          name: 'diagram.svg',
          media_type: 'image/svg+xml',
          data: Buffer.from(svg, 'utf8').toString('base64'),
        },
      ],
    };
  }

  process.stderr.write(
    `rendered a ${raster ? 'raster' : 'vector'} for '${request.format}'\n`,
  );
  return reply;
}

async function answer(request) {
  if (request.op === 'describe') {
    const reply = {
      protocols: PROTOCOLS,
      targets: TARGETS,
      formats: FORMAT_GROUPS,
    };
    const stamp = identity();
    if (stamp) reply.identity = stamp;
    const diagnostics = houseStyleDiagnostics();
    if (diagnostics.length) reply.diagnostics = diagnostics;
    return reply;
  }

  if (request.op === 'transform') {
    return serialize(() => transform(request));
  }

  // Nothing else exists in protocol 1. Saying so beats a silent empty reply,
  // which would reach the author as "returned no body".
  return { error: `this hook does not know the operation '${request.op}'` };
}

// ── Listening ────────────────────────────────────────────────────────

async function main() {
  browser = await puppeteer.launch({
    executablePath: process.env.PUPPETEER_EXECUTABLE_PATH,
    // The container is the sandbox: no network, a read-only root, every
    // capability dropped. Chromium's own sandbox needs capabilities this image
    // deliberately does not have.
    args: [
      '--no-sandbox',
      '--disable-dev-shm-usage',
      '--disable-gpu',
      `--user-data-dir=${path.join(process.env.HOME || '/tmp', 'chromium')}`,
    ],
  });

  renderPage = await browser.newPage();
  await renderPage.setContent('<!doctype html><html><body></body></html>');
  await renderPage.addScriptTag({
    path: require.resolve('mermaid/dist/mermaid.min.js'),
  });
  await renderPage.evaluate(() => {
    // The bundle is an IIFE assigning into a namespace object of its own rather
    // than defining a global. That name is mermaid's build detail rather than
    // its API, so a version bump can move it — and the failure would otherwise
    // be this container exiting before it listens, which reaches an author as
    // nothing more than a hook that did not answer.
    const namespace = window.__esbuild_esm_mermaid_nm;
    window.mermaid = namespace?.mermaid?.default || window.mermaid;
    if (!window.mermaid || typeof window.mermaid.render !== 'function') {
      throw new Error(
        'mermaid.min.js loaded but exported no renderer; the bundle global has moved',
      );
    }
  });

  rasterPage = await browser.newPage();
  await rasterPage.setViewport({
    width: 1200,
    height: 900,
    deviceScaleFactor: RASTER_SCALE,
  });

  // A socket left by a hard kill would otherwise refuse every connection.
  fs.rmSync(SOCKET, { force: true });

  // allowHalfOpen, because the exchange is one round trip: Keystone writes the
  // request and half-closes to mark its end. Without this Node closes the whole
  // socket when the readable side ends, and the reply is written to a socket
  // that is already gone.
  const server = net.createServer({ allowHalfOpen: true }, (connection) => {
    const chunks = [];
    connection.on('data', (chunk) => chunks.push(chunk));

    // Keystone writes the request and half-closes, so end is the whole request.
    connection.on('end', async () => {
      let reply;
      try {
        reply = await answer(
          JSON.parse(Buffer.concat(chunks).toString('utf8')),
        );
      } catch (cause) {
        reply =
          cause instanceof Refused
            ? { error: cause.message }
            : {
                error: `this hook failed to render the block: ${cause?.message}`,
              };
      }
      connection.end(JSON.stringify(reply));
    });

    connection.on('error', (cause) => {
      process.stderr.write(`connection failed: ${cause.message}\n`);
    });
  });

  server.listen(SOCKET, () => {
    // Keystone connects as whichever user ran the build, never as this one.
    fs.chmodSync(SOCKET, 0o666);
    process.stderr.write(`listening on ${SOCKET}\n`);
  });
}

main().catch((cause) => {
  process.stderr.write(`${cause?.stack}\n`);
  process.exit(1);
});
