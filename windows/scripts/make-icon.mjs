// Draws the app icon (build/icon.png, 256x256) with no external tools: a dark
// rounded square, a green disc (the tray's "something is ready" colour) and a
// white tick. electron-builder turns the PNG into the .ico.
import { deflateSync, crc32 } from "node:zlib";
import fs from "node:fs";

const SIZE = 256;
const px = new Uint8Array(SIZE * SIZE * 4);

// Distance from point p to the segment a-b.
function segment(px_, py, ax, ay, bx, by) {
  const dx = bx - ax;
  const dy = by - ay;
  const t = Math.max(0, Math.min(1, ((px_ - ax) * dx + (py - ay) * dy) / (dx * dx + dy * dy)));
  return Math.hypot(px_ - (ax + t * dx), py - (ay + t * dy));
}

for (let y = 0; y < SIZE; y++) {
  for (let x = 0; x < SIZE; x++) {
    const i = (y * SIZE + x) * 4;
    const cx = x + 0.5;
    const cy = y + 0.5;
    // Rounded square: inside when within `r` of the inner rectangle.
    const r = 48;
    const qx = Math.max(Math.abs(cx - SIZE / 2) - (SIZE / 2 - r), 0);
    const qy = Math.max(Math.abs(cy - SIZE / 2) - (SIZE / 2 - r), 0);
    if (Math.hypot(qx, qy) > r) continue; // transparent corner
    let rgb = [22, 27, 34];
    if (Math.hypot(cx - 128, cy - 128) <= 88) rgb = [46, 160, 67];
    const tick = Math.min(segment(cx, cy, 90, 132, 118, 160), segment(cx, cy, 118, 160, 172, 100));
    if (tick <= 11) rgb = [255, 255, 255];
    px.set([...rgb, 255], i);
  }
}

// PNG: 8-bit RGBA, no interlace.
const raw = Buffer.alloc(SIZE * (SIZE * 4 + 1));
for (let y = 0; y < SIZE; y++) {
  raw[y * (SIZE * 4 + 1)] = 0; // filter: none
  Buffer.from(px.buffer, y * SIZE * 4, SIZE * 4).copy(raw, y * (SIZE * 4 + 1) + 1);
}
const chunk = (type, data) => {
  const body = Buffer.concat([Buffer.from(type), data]);
  const out = Buffer.alloc(8 + data.length + 4);
  out.writeUInt32BE(data.length, 0);
  body.copy(out, 4);
  out.writeUInt32BE(crc32(body), 8 + data.length);
  return out;
};
const header = Buffer.alloc(13);
header.writeUInt32BE(SIZE, 0);
header.writeUInt32BE(SIZE, 4);
header.set([8, 6, 0, 0, 0], 8);
fs.mkdirSync("build", { recursive: true });
fs.writeFileSync("build/icon.png", Buffer.concat([Buffer.from([137, 80, 78, 71, 13, 10, 26, 10]), chunk("IHDR", header), chunk("IDAT", deflateSync(raw)), chunk("IEND", Buffer.alloc(0))]));
console.log("wrote build/icon.png");
