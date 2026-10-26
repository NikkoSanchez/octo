import { BrowserWindow, clipboard, dialog, nativeImage, nativeTheme } from "electron";
import { promises as fs } from "node:fs";
import { basename } from "node:path";
import { makeImage, type ImageAttachment } from "@octo/core";
import type { PlatformServices } from "./store/appStore";

const SOURCE_LIMIT = 30 * 1024 * 1024;
const PNG_LIMIT = 5 * 1024 * 1024;
const PIXEL_LIMIT = 32_000_000;
const FAILURE = "Could not attach this image. Use a supported image up to 30 MB, 32 megapixels, and 5 MB after PNG conversion.";

/**
 * Decodes in the main process and keeps PNG bytes, never a reference to a file that can change or
 * disappear before sending. Animated images use their first frame.
 */
export function decodeImage(data: Buffer, name: string): ImageAttachment {
  if (data.length > SOURCE_LIMIT) throw new Error(FAILURE);
  const image = nativeImage.createFromBuffer(data);
  const size = image.getSize();
  if (image.isEmpty() || size.width <= 0 || size.height <= 0 || size.width * size.height > PIXEL_LIMIT) throw new Error(FAILURE);
  const png = image.toPNG();
  if (png.length === 0 || png.length > PNG_LIMIT) throw new Error(FAILURE);
  return makeImage(png.toString("base64"), name);
}

function window(): BrowserWindow | undefined {
  return BrowserWindow.getFocusedWindow() ?? BrowserWindow.getAllWindows()[0];
}

export const electronPlatform: PlatformServices = {
  async chooseDirectory({ title, prompt }) {
    const owner = window();
    const options: Electron.OpenDialogOptions = { title, message: title, buttonLabel: prompt, properties: ["openDirectory", "createDirectory"] };
    const result = owner ? await dialog.showOpenDialog(owner, options) : await dialog.showOpenDialog(options);
    return result.canceled ? undefined : result.filePaths[0];
  },
  async chooseFile({ title, prompt, defaultPath }) {
    const owner = window();
    const options: Electron.OpenDialogOptions = { title, message: title, buttonLabel: prompt, defaultPath, properties: ["openFile", "showHiddenFiles"] };
    const result = owner ? await dialog.showOpenDialog(owner, options) : await dialog.showOpenDialog(options);
    return result.canceled ? undefined : result.filePaths[0];
  },
  async chooseImages() {
    const owner = window();
    const options: Electron.OpenDialogOptions = {
      title: "Add images", message: "Choose up to four images. Review them in your draft before sending.", buttonLabel: "Attach",
      properties: ["openFile", "multiSelections"], filters: [{ name: "Images", extensions: ["png", "jpg", "jpeg", "gif", "webp", "heic", "tif", "tiff", "bmp"] }],
    };
    const result = owner ? await dialog.showOpenDialog(owner, options) : await dialog.showOpenDialog(options);
    return result.canceled ? [] : result.filePaths;
  },
  decodeImage,
  async readImageFile(path) {
    const info = await fs.stat(path);
    if (!info.isFile() || info.size > SOURCE_LIMIT) throw new Error(FAILURE);
    return decodeImage(await fs.readFile(path), basename(path));
  },
  async clipboardImage() {
    for (const item of await clipboard.read()) {
      const type = item.types.find((t) => t.startsWith("image/"));
      if (!type) continue;
      const blob = await item.getType(type);
      // An image that can't be read still counts, so it never falls through to a text paste.
      return blob instanceof Blob ? Buffer.from(await blob.arrayBuffer()) : Buffer.from("invalid");
    }
    return undefined;
  },
  systemDark() {
    return nativeTheme.shouldUseDarkColors;
  },
};
