import { app, dialog } from "electron";
import { join } from "node:path";
import { identity, type Channel } from "../shared/identity";
import { resolveDataDirectory, UnownedDataFolderError } from "./dataFolder";

/** Set before `ready`: name and data folder must not follow a later display-name change. */
export function applyIdentity(): { channel: Channel; dataDirectory: string } {
  const channel: Channel = app.isPackaged ? __OCTO_CHANNEL__ : "dev";
  const id = identity(channel);
  app.setName(id.productName);
  const dataDirectory = process.env.OCTO_USER_DATA ?? dataFolder(id.productName, id.dataFolder);
  app.setPath("userData", dataDirectory);
  // Electron's own caches stay inside the pinned folder too.
  app.setPath("sessionData", join(dataDirectory, "Session"));
  return { channel, dataDirectory };
}

/** Another app's folder at our path stops the launch; nothing is written into it. */
function dataFolder(productName: string, folder: string): string {
  try {
    return resolveDataDirectory(app.getPath("appData"), folder);
  } catch (error) {
    if (!(error instanceof UnownedDataFolderError)) throw error;
    dialog.showErrorBox(`${productName} can't use its data folder`, `${error.folder} already exists and wasn't created by ${productName}, so ${productName} won't write into it. Move that folder elsewhere, then open ${productName} again.`);
    process.exit(1);
  }
}
