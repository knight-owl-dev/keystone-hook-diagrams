'use strict';

// probe.js — Verify the keystone-hook-diagrams image over its own protocol.
//
// The checks here read what comes back from a render, because nothing cheaper
// proves this image works. It is a service, so there is no `--version` to ask,
// and `describe` answers from constants — it touches neither mermaid nor
// Chromium, and succeeds on an image with no browser and no fonts.
//
// What can break lives past it: mermaid's `mermaidAPI.getConfig()`, the `<style>`
// block it emits, the `viewBox` attribute withIntrinsicSize matches. The last has
// no error path — a mermaid bump that reorders SVG attributes returns the SVG
// unchanged and mis-sizes every figure in the book.
//
// Runs inside the container over the socket; node builtins only.
//
// Usage: node probe.js [render|no-diagnostics|font-warning]

const net = require('node:net');
const { execFileSync } = require('node:child_process');

// Told the path, never guessing it: docker exec inherits the container's
// environment, so this is the same value the hook bound. A fallback would turn a
// renamed socket into a bare ENOENT on connect.
const SOCKET = (process.env.HOOK_SOCKET || '').trim();
if (!SOCKET) {
  console.error('HOOK_SOCKET is required: the path the hook bound');
  process.exit(1);
}

const MODE = process.argv[2] || 'render';

// The renderer lays out at 800 and captures at 3x; the SVG carries a nominal
// intrinsic width. Both are server.js constants, restated here so a change to
// either has to be deliberate.
const RASTER_WIDTH = 2400;
const NOMINAL_WIDTH = 1600;

const RASTER_FORMATS = ['pdf', 'docx', 'odt'];
const VECTOR_FORMATS = ['epub'];

// The brackets are the test: a title is escaped on the way out, because an
// unescaped one closes the markdown image early. The word is distinctive so its
// absence from the render means the title was blanked, not merely unmatched.
const TITLE = 'Zebra [A] Marmalade';
const DIAGRAM = `---
title: ${TITLE}
---
flowchart LR
  A[Start] --> B[Finish]
`;

// The mistake an author actually makes: `theme` is a key inside `init`, not a
// directive of its own.
const UNKNOWN_DIRECTIVE = `%%{ theme: 'dark' }%%
flowchart LR
  A --> B
`;

// ── Reporting ────────────────────────────────────────────────────────

let failed = 0;

function report(ok, name, detail) {
  console.log(`  ${ok ? 'OK  ' : 'FAIL'}  ${name}  ${detail ?? ''}`.trimEnd());
  if (!ok) failed = 1;
}

function expect(condition, message) {
  if (!condition) throw new Error(message);
}

async function check(name, fn) {
  try {
    report(true, name, await fn());
  } catch (cause) {
    report(false, name, cause?.message);
  }
}

// ── The wire ─────────────────────────────────────────────────────────

// One request, one reply. Keystone writes and half-closes, so this does too —
// the server reads to end-of-stream, which never arrives if the socket stays
// writable.
function ask(request) {
  return new Promise((resolve, reject) => {
    const connection = net.createConnection(SOCKET);
    const chunks = [];

    connection.on('connect', () => connection.end(JSON.stringify(request)));
    connection.on('data', (chunk) => chunks.push(chunk));
    connection.on('error', reject);
    connection.on('end', () => {
      const raw = Buffer.concat(chunks).toString('utf8');
      try {
        resolve(JSON.parse(raw));
      } catch {
        reject(new Error(`reply was not JSON: ${raw.slice(0, 200)}`));
      }
    });
  });
}

function transform(format, content) {
  return ask({ op: 'transform', target: 'mermaid', format, content });
}

function decode(reply) {
  return Buffer.from(reply.assets[0].data, 'base64');
}

// ── Checks ───────────────────────────────────────────────────────────

async function main() {
  const described = await ask({ op: 'describe' });

  await check('describe', () => {
    expect(
      Array.isArray(described.protocols) && described.protocols.includes(1),
      `protocols ${JSON.stringify(described.protocols)}`,
    );
    expect(
      JSON.stringify(described.targets) === '["mermaid"]',
      `targets ${JSON.stringify(described.targets)}`,
    );
    return `protocols ${described.protocols.join(',')}  targets ${described.targets.join(',')}`;
  });

  // Rebuilt from the environment rather than read back from the reply. The
  // check is that the string tracks the image and its settings; a reply compared
  // to itself would pass on any string at all.
  const setting = (name) =>
    (process.env[`KEYSTONE_DIAGRAMS_${name}`] || '').trim();
  const version = (process.env.IMAGE_VERSION || '').trim();
  const expected =
    !version || version === 'local'
      ? null
      : `${version}/theme=${setting('THEME')}/font=${setting('FONT')}/look=${setting('LOOK')}`;

  await check('describe carries the cache identity', async () => {
    if (!expected) {
      expect(
        !described.identity,
        `an unversioned image sent '${described.identity}'`,
      );
      return 'omitted, this image carries no version';
    }
    expect(
      described.identity === expected,
      `got '${described.identity}', expected '${expected}'`,
    );
    // Nothing time-based or random. A string that moves between runs is a cache
    // that never hits, and nothing downstream would report it.
    const again = await ask({ op: 'describe' });
    expect(
      again.identity === described.identity,
      `a second describe said '${again.identity}'`,
    );
    return described.identity;
  });

  if (MODE === 'no-diagnostics') {
    await check('an installed font raises nothing', () => {
      expect(
        !described.diagnostics,
        `got ${JSON.stringify(described.diagnostics)}`,
      );
      return 'no diagnostics';
    });
    return;
  }

  if (MODE === 'font-warning') {
    await check('a missing font warns', () => {
      const diagnostics = described.diagnostics || [];
      expect(
        diagnostics.length === 1,
        `${diagnostics.length} diagnostics, expected 1`,
      );
      expect(
        diagnostics[0].severity === 'warning',
        `severity ${diagnostics[0].severity}`,
      );
      expect(
        /KEYSTONE_DIAGRAMS_FONT/.test(diagnostics[0].message),
        `message did not name the setting: ${diagnostics[0].message}`,
      );
      return diagnostics[0].message.split('\n')[0];
    });
    return;
  }

  // The partition is compared as sets: the engine keys a group on its
  // alphabetically first format, so order carries no meaning and asserting it
  // would fail on a change that means nothing.
  await check('describe declares the format partition', () => {
    const normalize = (groups) =>
      groups.map((g) => [...g].sort().join(',')).sort();
    expect(Array.isArray(described.formats), 'no formats partition');
    expect(
      JSON.stringify(normalize(described.formats)) ===
        JSON.stringify(normalize([RASTER_FORMATS, VECTOR_FORMATS])),
      `got ${JSON.stringify(described.formats)}`,
    );
    return JSON.stringify(described.formats);
  });

  // Every documented format, not one representative per group. The hook is
  // stateless and knows nothing of Keystone's cache, so testing it by that
  // grouping would assume the very thing the next check proves.
  const replies = {};
  for (const format of [...RASTER_FORMATS, ...VECTOR_FORMATS]) {
    await check(`transform ${format}`, async () => {
      const reply = await transform(format, DIAGRAM);
      expect(!reply.error, reply.error);
      expect(
        reply.assets && reply.assets.length === 1,
        'expected exactly one asset',
      );
      replies[format] = reply;
      return `${reply.assets[0].media_type}`;
    });
  }

  await check('the raster group shares one asset', () => {
    const [first, ...rest] = RASTER_FORMATS;
    expect(replies[first], `${first} did not render`);
    for (const format of rest) {
      expect(replies[format], `${format} did not render`);
      expect(
        replies[format].assets[0].data === replies[first].assets[0].data,
        `${format} differs from ${first} — the partition describe declares is a lie, ` +
          'and Keystone would serve a wrong asset for the formats it never asks about',
      );
    }
    return RASTER_FORMATS.join(' = ');
  });

  await check('the raster is a PNG at render resolution', () => {
    const png = decode(replies.pdf);
    expect(
      png.subarray(0, 8).equals(Buffer.from('89504e470d0a1a0a', 'hex')),
      'not a PNG',
    );
    const width = png.readUInt32BE(16);
    const height = png.readUInt32BE(20);
    expect(
      Math.abs(width - RASTER_WIDTH) <= 4,
      `width ${width}, expected ~${RASTER_WIDTH}`,
    );
    return `${width}x${height}`;
  });

  const svg = replies.epub ? decode(replies.epub).toString('utf8') : '';

  await check('the vector carries an intrinsic width', () => {
    expect(svg, 'epub did not render');
    expect(
      svg.includes(`width="${NOMINAL_WIDTH}"`),
      'no nominal width — withIntrinsicSize matched no viewBox, and every figure ' +
        "would size from mermaid's natural width instead",
    );
    return `width="${NOMINAL_WIDTH}"`;
  });

  await check('the vector carries both palettes', () => {
    expect(svg, 'epub did not render');
    expect(
      svg.includes('@media (prefers-color-scheme: dark)'),
      'no dark media query',
    );
    const painted = [
      ...svg.matchAll(/#ks-diagram\{background-color:([^}]+)\}/g),
    ].map((m) => m[1]);
    expect(
      painted.length === 2,
      `${painted.length} backgrounds, expected one per palette`,
    );
    expect(
      !painted.some((color) => /transparent|none/i.test(color)),
      `a palette paints nothing: ${painted.join(', ')}`,
    );
    return painted.join(' / ');
  });

  await check('the title is alt text, escaped', () => {
    expect(replies.epub, 'epub did not render');
    expect(
      replies.epub.body === '![Zebra \\[A\\] Marmalade](diagram.svg)',
      `body was ${replies.epub.body}`,
    );
    return replies.epub.body;
  });

  await check('the title is not drawn in the diagram', () => {
    expect(svg, 'epub did not render');
    expect(
      !svg.includes('Zebra'),
      'the title reached the render — the book would carry it twice',
    );
    return 'blanked before rendering';
  });

  await check('an unknown directive is refused', async () => {
    const reply = await transform('epub', UNKNOWN_DIRECTIVE);
    expect(reply.error, 'the block rendered instead of being refused');
    expect(!reply.body && !reply.assets, 'a refusal carried a body');
    expect(/unknown directive/.test(reply.error), `error was: ${reply.error}`);
    return reply.error.split('\n')[0];
  });

  // Two at once against one shared browser. Without serialization the second render
  // replaces the page while the first is still reading it, and the first comes
  // back either detached or as the other block's picture — so this compares
  // against the same block rendered alone, where a swap is the silent case.
  await check('concurrent transforms do not collide', async () => {
    const other = 'flowchart TD\n  X[Wide Node Here] --> Y[Y]\n  Y --> Z[Z]\n';
    const [mine, theirs] = await Promise.all([
      transform('pdf', DIAGRAM),
      transform('pdf', other),
    ]);
    expect(
      !mine.error && !theirs.error,
      `${mine.error || ''} ${theirs.error || ''}`.trim(),
    );
    expect(
      mine.assets[0].data === replies.pdf.assets[0].data,
      'a block rendered alongside another returned different bytes than it did alone',
    );
    expect(
      mine.assets[0].data !== theirs.assets[0].data,
      'two blocks returned one asset',
    );
    return 'two in flight, both intact';
  });

  await check('an unknown op is refused', async () => {
    const reply = await ask({ op: 'nonsense' });
    expect(reply.error, 'no error for an operation protocol 1 does not have');
    return reply.error;
  });

  // Reported, not asserted: `npm ci` already guarantees node_modules matches
  // the lock, and Chromium is unpinned by design.
  for (const pkg of ['mermaid', 'puppeteer-core']) {
    report(true, pkg, require(`/app/node_modules/${pkg}/package.json`).version);
  }
  report(true, 'node', process.version);
  try {
    const browser =
      process.env.PUPPETEER_EXECUTABLE_PATH || '/usr/bin/chromium-browser';
    report(
      true,
      'chromium',
      execFileSync(browser, ['--version'], { encoding: 'utf8' }).trim(),
    );
  } catch (cause) {
    report(false, 'chromium', cause?.message);
  }
}

main()
  .then(() => {
    console.log(failed ? 'FAIL' : 'OK');
    process.exit(failed);
  })
  .catch((cause) => {
    console.error(`probe failed: ${cause?.stack}`);
    process.exit(1);
  });
