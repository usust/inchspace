import { copyFile, mkdir } from "node:fs/promises";
import { execFileSync } from "node:child_process";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import sharp from "sharp";

const root = resolve(dirname(fileURLToPath(import.meta.url)), "..");
const sourceSvg = resolve(root, "src/assets/inchspace-icon.svg");
const publicSvg = resolve(root, "public/inchspace-icon.svg");
const sourcePng = resolve(root, "src/assets/inchspace-icon.png");
const publicPng = resolve(root, "public/inchspace-icon.png");
const canvasSize = 1024;
const visibleIconSize = 848;
const iconOffset = Math.round((canvasSize - visibleIconSize) / 2);

await mkdir(dirname(publicSvg), { recursive: true });
await copyFile(sourceSvg, publicSvg);

const fullSizeIcon = await sharp(sourceSvg)
  .resize(canvasSize, canvasSize, { fit: "contain" })
  .png()
  .toBuffer();

const normalizedIcon = await sharp(fullSizeIcon)
  .resize(visibleIconSize, visibleIconSize, { fit: "contain" })
  .png()
  .toBuffer();

await sharp({
  create: {
    width: canvasSize,
    height: canvasSize,
    channels: 4,
    background: { r: 0, g: 0, b: 0, alpha: 0 },
  },
})
  .composite([{ input: normalizedIcon, left: iconOffset, top: iconOffset }])
  .png({ compressionLevel: 9, adaptiveFiltering: true })
  .toFile(sourcePng);

await copyFile(sourcePng, publicPng);

const npm = process.platform === "win32" ? "npm.cmd" : "npm";
execFileSync(npm, ["run", "tauri", "--", "icon", sourcePng], {
  cwd: root,
  stdio: "inherit",
});

console.log(
  `Generated InchSpace icons from src/assets/inchspace-icon.svg with ${visibleIconSize}px visible artwork`,
);
