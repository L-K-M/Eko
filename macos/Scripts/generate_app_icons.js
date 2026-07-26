#!/usr/bin/env node
//
// Deterministically derives every committed app-icon asset from the single
// source image media-sources/icon.png:
//
//   macOS  — App/Resources/Assets.xcassets/AppIcon.appiconset/icon_*.png
//            (Apple's Big Sur icon grid: content in an 824/1024 rounded
//            rectangle, transparent margins)
//   Android — android/app/src/main/res/mipmap-*dpi/ic_launcher_fg.png
//            (full-bleed 108 dp adaptive-icon foreground layers)
//
// Pure Node — PNG decode/encode and resampling are implemented here so the
// build needs no image tooling beyond `node` itself.

const fs = require("fs");
const path = require("path");
const zlib = require("zlib");

const sourcePath = path.resolve(__dirname, "../../media-sources/icon.png");
const macOutputDirectory = path.resolve(__dirname, "../App/Resources/Assets.xcassets/AppIcon.appiconset");
const androidResDirectory = path.resolve(__dirname, "../../android/app/src/main/res");

const macOutputs = [
  ["icon_16x16.png", 16],
  ["icon_16x16@2x.png", 32],
  ["icon_32x32.png", 32],
  ["icon_32x32@2x.png", 64],
  ["icon_128x128.png", 128],
  ["icon_128x128@2x.png", 256],
  ["icon_256x256.png", 256],
  ["icon_256x256@2x.png", 512],
  ["icon_512x512.png", 512],
  ["icon_512x512@2x.png", 1024],
];

// Adaptive-icon layers are 108 dp; the launcher mask reveals the middle
// ~72 dp, so the phone stays inside the safe zone and the sound waves
// intentionally bleed off the edge.
const androidOutputs = [
  ["mipmap-mdpi", 108],
  ["mipmap-hdpi", 162],
  ["mipmap-xhdpi", 216],
  ["mipmap-xxhdpi", 324],
  ["mipmap-xxxhdpi", 432],
];

// Apple's macOS icon grid: on a 1024 pt canvas the icon body is an 824 pt
// rounded rectangle (100 pt margins) with a 185.4 pt corner radius.
const MAC_MARGIN = 100 / 1024;
const MAC_CORNER_RADIUS = 185.4 / 1024;

// --- PNG decode ------------------------------------------------------------

function paethPredictor(a, b, c) {
  const p = a + b - c;
  const pa = Math.abs(p - a);
  const pb = Math.abs(p - b);
  const pc = Math.abs(p - c);
  if (pa <= pb && pa <= pc) return a;
  if (pb <= pc) return b;
  return c;
}

function decodePNG(buffer) {
  const signature = Buffer.from([137, 80, 78, 71, 13, 10, 26, 10]);
  if (!buffer.subarray(0, 8).equals(signature)) {
    throw new Error(`${sourcePath} is not a PNG`);
  }
  let width = 0;
  let height = 0;
  let bitDepth = 0;
  let colorType = 0;
  let interlace = 0;
  const idat = [];
  let offset = 8;
  while (offset < buffer.length) {
    const length = buffer.readUInt32BE(offset);
    const type = buffer.toString("ascii", offset + 4, offset + 8);
    const data = buffer.subarray(offset + 8, offset + 8 + length);
    if (type === "IHDR") {
      width = data.readUInt32BE(0);
      height = data.readUInt32BE(4);
      bitDepth = data[8];
      colorType = data[9];
      interlace = data[12];
    } else if (type === "IDAT") {
      idat.push(data);
    } else if (type === "IEND") {
      break;
    }
    offset += 12 + length;
  }
  if (bitDepth !== 8) throw new Error(`unsupported PNG bit depth ${bitDepth} (need 8)`);
  if (interlace !== 0) throw new Error("interlaced PNGs are not supported");
  const channelsByColorType = { 0: 1, 2: 3, 4: 2, 6: 4 };
  const channels = channelsByColorType[colorType];
  if (!channels) throw new Error(`unsupported PNG color type ${colorType}`);

  const raw = zlib.inflateSync(Buffer.concat(idat));
  const stride = width * channels;
  const pixels = Buffer.alloc(width * height * 4);
  let previousRow = Buffer.alloc(stride);
  for (let row = 0; row < height; row += 1) {
    const filter = raw[row * (stride + 1)];
    const line = Buffer.from(raw.subarray(row * (stride + 1) + 1, (row + 1) * (stride + 1)));
    for (let i = 0; i < stride; i += 1) {
      const left = i >= channels ? line[i - channels] : 0;
      const up = previousRow[i];
      const upLeft = i >= channels ? previousRow[i - channels] : 0;
      switch (filter) {
        case 0: break;
        case 1: line[i] = (line[i] + left) & 0xff; break;
        case 2: line[i] = (line[i] + up) & 0xff; break;
        case 3: line[i] = (line[i] + ((left + up) >> 1)) & 0xff; break;
        case 4: line[i] = (line[i] + paethPredictor(left, up, upLeft)) & 0xff; break;
        default: throw new Error(`unsupported PNG filter ${filter}`);
      }
    }
    for (let x = 0; x < width; x += 1) {
      const target = (row * width + x) * 4;
      switch (colorType) {
        case 0:
          pixels[target] = pixels[target + 1] = pixels[target + 2] = line[x];
          pixels[target + 3] = 255;
          break;
        case 2:
          pixels[target] = line[x * 3];
          pixels[target + 1] = line[x * 3 + 1];
          pixels[target + 2] = line[x * 3 + 2];
          pixels[target + 3] = 255;
          break;
        case 4:
          pixels[target] = pixels[target + 1] = pixels[target + 2] = line[x * 2];
          pixels[target + 3] = line[x * 2 + 1];
          break;
        case 6:
          line.copy(pixels, target, x * 4, x * 4 + 4);
          break;
      }
    }
    previousRow = line;
  }
  return { width, height, pixels };
}

// --- PNG encode ------------------------------------------------------------

function crc32(buffer) {
  let crc = 0xffffffff;
  for (const byte of buffer) {
    crc ^= byte;
    for (let bit = 0; bit < 8; bit += 1) {
      crc = (crc >>> 1) ^ (0xedb88320 & -(crc & 1));
    }
  }
  return (crc ^ 0xffffffff) >>> 0;
}

function chunk(type, data) {
  const name = Buffer.from(type, "ascii");
  const length = Buffer.alloc(4);
  length.writeUInt32BE(data.length);
  const checksum = Buffer.alloc(4);
  checksum.writeUInt32BE(crc32(Buffer.concat([name, data])));
  return Buffer.concat([length, name, data, checksum]);
}

function encodePNG(size, pixels) {
  const signature = Buffer.from([137, 80, 78, 71, 13, 10, 26, 10]);
  const header = Buffer.alloc(13);
  header.writeUInt32BE(size, 0);
  header.writeUInt32BE(size, 4);
  header[8] = 8;
  header[9] = 6;
  const rows = Buffer.alloc((size * 4 + 1) * size);
  for (let row = 0; row < size; row += 1) {
    const target = row * (size * 4 + 1);
    rows[target] = 0;
    pixels.copy(rows, target + 1, row * size * 4, (row + 1) * size * 4);
  }
  return Buffer.concat([
    signature,
    chunk("IHDR", header),
    chunk("IDAT", zlib.deflateSync(rows, { level: 9 })),
    chunk("IEND", Buffer.alloc(0)),
  ]);
}

// --- Resampling and masking ------------------------------------------------

function clamp(value, minimum, maximum) {
  return Math.max(minimum, Math.min(maximum, value));
}

function smoothCoverage(distance, pixelWidth) {
  return clamp(0.5 - distance / pixelWidth, 0, 1);
}

function roundedRectangleDistance(x, y, centerX, centerY, halfWidth, halfHeight, radius) {
  const qx = Math.abs(x - centerX) - halfWidth + radius;
  const qy = Math.abs(y - centerY) - halfHeight + radius;
  return Math.hypot(Math.max(qx, 0), Math.max(qy, 0)) + Math.min(Math.max(qx, qy), 0) - radius;
}

// Box-filtered sample of the axis-aligned source rectangle [x0,x1)×[y0,y1),
// in source pixel coordinates, with edge clamping. Returns premultiplied RGBA.
function sampleArea(source, x0, x1, y0, y1) {
  const { width, height, pixels } = source;
  let r = 0;
  let g = 0;
  let b = 0;
  let a = 0;
  let total = 0;
  const startY = Math.floor(clamp(y0, 0, height - 1));
  const endY = Math.min(Math.ceil(y1), height);
  const startX = Math.floor(clamp(x0, 0, width - 1));
  const endX = Math.min(Math.ceil(x1), width);
  for (let sy = startY; sy < endY; sy += 1) {
    const coverY = Math.min(sy + 1, y1) - Math.max(sy, y0);
    if (coverY <= 0) continue;
    for (let sx = startX; sx < endX; sx += 1) {
      const coverX = Math.min(sx + 1, x1) - Math.max(sx, x0);
      if (coverX <= 0) continue;
      const weight = coverX * coverY;
      const index = (sy * width + sx) * 4;
      const alpha = pixels[index + 3] / 255;
      r += pixels[index] * alpha * weight;
      g += pixels[index + 1] * alpha * weight;
      b += pixels[index + 2] * alpha * weight;
      a += alpha * weight;
      total += weight;
    }
  }
  if (total === 0) return [0, 0, 0, 0];
  return [r / total, g / total, b / total, a / total];
}

// Renders `source` scaled into the unit-square region [margin, 1-margin],
// masked by a rounded rectangle spanning exactly that region. margin 0 and
// radius 0 yields a plain full-bleed resample.
function renderScaled(source, size, margin, cornerRadius) {
  const out = Buffer.alloc(size * size * 4);
  const content = 1 - 2 * margin;
  const sourceScale = source.width / (size * content);
  const pixelWidth = 1 / size;
  const half = content / 2;
  for (let py = 0; py < size; py += 1) {
    for (let px = 0; px < size; px += 1) {
      let coverage = 1;
      if (margin > 0 || cornerRadius > 0) {
        const u = (px + 0.5) / size;
        const v = (py + 0.5) / size;
        const distance = roundedRectangleDistance(u, v, 0.5, 0.5, half, half, cornerRadius);
        coverage = smoothCoverage(distance, pixelWidth);
      }
      const index = (py * size + px) * 4;
      if (coverage === 0) continue;
      const sx0 = ((px / size) - margin) / content * source.width;
      const sx1 = sx0 + sourceScale;
      const sy0 = ((py / size) - margin) / content * source.height;
      const sy1 = sy0 + sourceScale;
      const [r, g, b, a] = sampleArea(source, sx0, sx1, sy0, sy1);
      const alpha = a * coverage;
      if (alpha === 0) continue;
      out[index] = Math.round(clamp(r / a, 0, 255));
      out[index + 1] = Math.round(clamp(g / a, 0, 255));
      out[index + 2] = Math.round(clamp(b / a, 0, 255));
      out[index + 3] = Math.round(alpha * 255);
    }
  }
  return out;
}

// --- Main ------------------------------------------------------------------

const source = decodePNG(fs.readFileSync(sourcePath));
if (source.width !== source.height) {
  throw new Error(`${sourcePath} must be square (got ${source.width}x${source.height})`);
}

fs.mkdirSync(macOutputDirectory, { recursive: true });
for (const [name, size] of macOutputs) {
  const pixels = renderScaled(source, size, MAC_MARGIN, MAC_CORNER_RADIUS);
  fs.writeFileSync(path.join(macOutputDirectory, name), encodePNG(size, pixels));
}

for (const [directory, size] of androidOutputs) {
  const target = path.join(androidResDirectory, directory);
  fs.mkdirSync(target, { recursive: true });
  const pixels = renderScaled(source, size, 0, 0);
  fs.writeFileSync(path.join(target, "ic_launcher_fg.png"), encodePNG(size, pixels));
}
