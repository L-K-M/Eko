#!/usr/bin/env node

const fs = require("fs");
const path = require("path");
const zlib = require("zlib");

const outputDirectory = path.resolve(__dirname, "../App/Resources/Assets.xcassets/AppIcon.appiconset");
const outputs = [
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

function composite(destination, source, alpha) {
  const sourceAlpha = (source[3] / 255) * alpha;
  const destinationAlpha = destination[3] / 255;
  const outputAlpha = sourceAlpha + destinationAlpha * (1 - sourceAlpha);
  if (outputAlpha === 0) return [0, 0, 0, 0];
  return [
    Math.round((source[0] * sourceAlpha + destination[0] * destinationAlpha * (1 - sourceAlpha)) / outputAlpha),
    Math.round((source[1] * sourceAlpha + destination[1] * destinationAlpha * (1 - sourceAlpha)) / outputAlpha),
    Math.round((source[2] * sourceAlpha + destination[2] * destinationAlpha * (1 - sourceAlpha)) / outputAlpha),
    Math.round(outputAlpha * 255),
  ];
}

function render(size) {
  const bytes = Buffer.alloc(size * size * 4);
  const pixelWidth = 1 / size;
  for (let py = 0; py < size; py += 1) {
    for (let px = 0; px < size; px += 1) {
      const x = (px + 0.5) / size;
      const y = (py + 0.5) / size;
      let pixel = [0, 0, 0, 0];

      const backgroundDistance = roundedRectangleDistance(x, y, 0.5, 0.5, 0.5, 0.5, 0.21875);
      const backgroundCoverage = smoothCoverage(backgroundDistance, pixelWidth);
      if (backgroundCoverage > 0) {
        const gradient = clamp((x + y) / 2, 0, 1);
        const first = [40, 206, 189];
        const last = [23, 78, 130];
        pixel = composite(pixel, [
          Math.round(first[0] * (1 - gradient) + last[0] * gradient),
          Math.round(first[1] * (1 - gradient) + last[1] * gradient),
          Math.round(first[2] * (1 - gradient) + last[2] * gradient),
          255,
        ], backgroundCoverage);
      }

      const outerPhone = roundedRectangleDistance(x, y, 0.5, 0.494, 0.184, 0.309, 0.09);
      const innerPhone = roundedRectangleDistance(x, y, 0.5, 0.494, 0.127, 0.252, 0.045);
      const phoneCoverage = clamp(
        smoothCoverage(outerPhone, pixelWidth) - smoothCoverage(innerPhone, pixelWidth),
        0,
        1
      );
      pixel = composite(pixel, [255, 255, 255, 255], phoneCoverage);

      const homeDistance = Math.hypot(x - 0.5, y - 0.691) - 0.028;
      pixel = composite(pixel, [255, 255, 255, 255], smoothCoverage(homeDistance, pixelWidth));

      for (const direction of [-1, 1]) {
        const centerX = 0.5 + direction * 0.235;
        const dx = x - centerX;
        const dy = y - 0.5;
        const radius = Math.hypot(dx, dy);
        const angleMatch = direction < 0 ? dx < 0 : dx > 0;
        const verticalRange = Math.abs(dy) < 0.17;
        const arcDistance = Math.abs(radius - 0.205) - 0.026;
        if (angleMatch && verticalRange) {
          pixel = composite(pixel, [255, 255, 255, 255], smoothCoverage(arcDistance, pixelWidth));
        }
      }

      const index = (py * size + px) * 4;
      bytes[index] = pixel[0];
      bytes[index + 1] = pixel[1];
      bytes[index + 2] = pixel[2];
      bytes[index + 3] = pixel[3];
    }
  }
  return bytes;
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

fs.mkdirSync(outputDirectory, { recursive: true });
for (const [name, size] of outputs) {
  fs.writeFileSync(path.join(outputDirectory, name), encodePNG(size, render(size)));
}
