'use strict';

// render.js — Render one corpus source and write the asset to stdout.
//
// Stdout carries the bytes: the root is read-only, /tmp is a tmpfs `docker cp`
// cannot read, and a bind mount is not writable by the container's UID. The
// reply is accumulated as buffers, since a chunk boundary can fall inside a
// multi-byte sequence.
//
// Runs inside the container over the socket; node builtins only.
//
// Usage: node render.js <source.mmd> <format>

const fs = require('node:fs');
const net = require('node:net');

const SOCKET = (process.env.HOOK_SOCKET || '').trim();
const [source, format] = process.argv.slice(2);
if (!SOCKET || !source || !format) {
  console.error('usage: HOOK_SOCKET=... node render.js <source.mmd> <format>');
  process.exit(1);
}

const request = JSON.stringify({
  op: 'transform',
  format,
  content: fs.readFileSync(source, 'utf8'),
});

const socket = net.connect(SOCKET, () => socket.end(request));
const chunks = [];
socket.on('data', (chunk) => chunks.push(chunk));
socket.on('error', (cause) => {
  console.error(`could not ask the hook: ${cause.message}`);
  process.exit(1);
});
socket.on('end', () => {
  const reply = JSON.parse(Buffer.concat(chunks).toString('utf8'));
  if (reply.error) {
    console.error(`${source} (${format}): ${JSON.stringify(reply.error)}`);
    process.exit(1);
  }
  process.stdout.write(Buffer.from(reply.assets[0].data, 'base64'));
});
