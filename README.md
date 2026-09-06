# keystone-hook-diagrams

A Docker image that renders [mermaid](https://mermaid.js.org/) diagrams in a
Keystone book. Published to GHCR at
`ghcr.io/knight-owl-dev/keystone-hook-diagrams`.

It is a service rather than a command: it starts, binds a Unix socket, and
answers a small JSON protocol for as long as a book is being built. Keystone
hands it a fenced code block and takes back Markdown plus the image that
Markdown references, so the publishing engine knows nothing about mermaid —
which is what lets a template add diagrams without an engine change.

Any template can wire it, and a project can wire it into one that has not.
[`core-diagrams`](https://github.com/knight-owl-dev/keystone-template-core-diagrams)
ships with it already wired.

The protocol and what a hook owes are in Keystone's manual:
<https://keystone.knight-owl.dev/engine/writing-a-hook/>

## What it carries

| | from | purpose |
| --- | --- | --- |
| [mermaid](https://mermaid.js.org/) | npm | turns diagram text into SVG |
| [puppeteer-core](https://pptr.dev/) | npm | drives a browser; ships none itself |
| [Chromium](https://www.chromium.org/) | Alpine package | runs mermaid and paints the result |
| Noto, Open Sans | Alpine packages | the families a diagram can letter in |

npm versions are pinned in `package-lock.json`, which `make resolve` regenerates
along with `package.json`. Both base images are pinned by manifest-list digest
inline in their `FROM` lines, where Renovate can see them. The build resolves
the dependency tree on `node:22-alpine`, then copies the node binary and that
tree onto a plain `alpine`, so the published image carries no npm, npx, yarn or
corepack.

Chromium and the fonts carry no `apk` pin: Alpine keeps only the current build
in its repository, so an exact version would break the build rather than hold it
still. Where a CVE needs forcing, the Dockerfile names a `>=` floor, and says
why.

mermaid runs in a browser page. The server injects `mermaid.min.js` into a blank
one and calls it there, because mermaid measures text to lay a diagram out and so
needs font metrics and a DOM. The fonts are layout input, and the manual names
them as what `KEYSTONE_DIAGRAMS_FONT` can resolve — so adding or dropping one
changes a documented contract.

## The interface

`HOOK_SOCKET` is required and has no default: it names the path this hook binds,
mode `0666`, on a volume shared with the engine. Put it under `/hooks`, which
the image ships at `1777` so a non-root UID can own the socket on a volume
mounted there.

`describe` answers what this renderer is:

```json
{
  "protocols": [1],
  "targets": ["mermaid"],
  "identity": "v1.4.4/theme=neutral/font=Noto Serif, serif/look=classic",
  "formats": [["pdf", "docx", "odt"], ["epub"]]
}
```

The three raster formats share one answer, so a diagram renders once for all of
them. `identity` carries the image version and every setting under
[Configuration](#configuration).

An image built without a version sends no `identity`, and Keystone then caches
nothing. `make build` leaves `IMAGE_VERSION` at its default, so a local build's
reply carries none.

`transform` returns one image per block:

| format | asset | why |
| --- | --- | --- |
| `pdf` | PNG at 3× | the typesetter reads the file itself and cannot read SVG |
| `docx`, `odt` | PNG at 3× | avoids depending on the writer's SVG handling |
| `epub` | SVG | scales, and carries a palette that follows the reader's theme |

The EPUB SVG holds both palettes, mermaid's dark rules inside a
`prefers-color-scheme` block, and each palette paints its own background.

The diagram's `title:` frontmatter comes back as alt text; the title is blanked
before rendering so it is not drawn twice.

## Configuration

Settings for the whole book, passed by the template from its `project.conf`.
Keystone forwards them without knowing what they are.

| variable | accepts | unset |
| --- | --- | --- |
| `KEYSTONE_DIAGRAMS_THEME` | `default`, `base`, `dark`, `forest`, `neutral` | light, with a dark alternative |
| `KEYSTONE_DIAGRAMS_LOOK` | `classic`, `handDrawn` | `classic` |
| `KEYSTONE_DIAGRAMS_FONT` | a CSS font stack | mermaid's own |

A theme or look mermaid does not know is refused rather than ignored, because
mermaid would silently draw its default and restyle the book. A font that does
not resolve is a warning: a stack is meant to fall through, and the fallback is
legible. Both arrive as `describe` diagnostics rather than per-diagram errors —
the project set them, so no one block is at fault.

Naming a theme drops the dark alternative — both passes then return the author's
theme, so there is nothing to switch between. That is the lever for a book that
wants no dark diagrams anywhere.

## Running it

The template wires it as a second service on a shared volume, hardened and
health-gated:

```yaml
services:
  diagrams:
    image: ghcr.io/knight-owl-dev/keystone-hook-diagrams:<tag>@sha256:<digest>
    healthcheck:
      test: ["CMD", "test", "-S", "/hooks/diagrams.sock"]
      interval: 30s
      start_interval: 1s
      start_period: 30s
    network_mode: none
    read_only: true
    cap_drop: [ALL]
    security_opt: ["no-new-privileges:true"]
    tmpfs: [/tmp]
    environment:
      HOME: /tmp
      HOOK_SOCKET: /hooks/diagrams.sock
    volumes:
      - hooks:/hooks
```

There is no `user:` — the hook keeps the image's own UID, which is what makes
the `0666` socket meaningful. Keystone connects as whoever ran the build.

The digest above is a placeholder. The template pins the real one in
`pins/keystone-hook-diagrams.lock`, and Renovate moves it when this image
publishes.

## Working on it

```bash
make build        # build keystone-hook-diagrams:local
make test-image   # start it three ways and render against each
make test         # the above, plus the bats suites
make scan         # Trivy, at the policy publish enforces
make lint         # hadolint, shellcheck, shfmt, biome, actionlint, markdownlint, cspell
```

`make test-image` is what proves the image. `describe` answers from constants,
so only a render reaches mermaid and Chromium.
[`tests/test-image.sh`](tests/test-image.sh) owns the container lifecycle and
[`tests/probe.js`](tests/probe.js) the assertions.

`make resolve` regenerates `package.json` and `package-lock.json`;
`make resolve TOOLS=mermaid:11.12.0` pins one instead of taking latest.

## Releasing

`make release BUMP=patch` stamps [`version`](version) and opens a
`release/vX.Y.Z` PR. Merging it promotes tag `vX.Y.Z`, which builds, tests,
scans, pushes and signs the image. The tag, the `version` file and the published
image tag are always one number.

A release refuses when nothing that reaches the image has changed since the
last one.

## Why it is shaped this way

Each of these was a bug before it was a rule.

- **`/hooks` ships in the image at `1777`.** Docker seeds an empty named volume
  from whichever container mounts it first, and this one starts before the
  engine. Left to Docker the volume arrives `root:root 0755` and the bind fails.
- **The listener sets `allowHalfOpen`.** Keystone writes its request and
  half-closes. Without it Node tears down the whole socket when the readable side
  ends, and the reply is written to a socket that is already gone.
- **Chromium runs with `--no-sandbox`.** Its sandbox needs capabilities the
  template deliberately drops. The container is the sandbox.
- **One browser lives for the life of the container.** Every block waits on this
  hook against a 30 second budget. Warm, a render is about 60 ms; launching a
  browser per diagram would spend that budget on process startup. This is why it
  is a Node server rather than socat in front of a CLI.
- **The caller declares the healthcheck; the image ships none.** It tests for the
  socket, and only the caller knows that path. Started and listening are different
  moments, and Keystone looks once, before the build begins. Losing that race
  yields a green build and a book with every diagram rendered as a code block.
  `start_interval` is what makes it prompt: without it Docker looks every
  few seconds inside the start period, and healthy lands about four seconds after
  the socket appears. It needs Docker Engine 25.0 or newer.
- **Nothing renders at a fixed size, and there is no lettering-size setting.**
  The container a figure is placed in owns scaling; this image owns resolution.
  mermaid lays a diagram out around its text, so a larger requested size produces
  a wider diagram that is then scaled down further — measured, a 2.8× change
  reached the page as 1.9×, by a factor differing per diagram.
