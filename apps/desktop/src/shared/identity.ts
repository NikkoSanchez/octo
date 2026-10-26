/**
 * App identity. `src/main/dataFolder.ts` resolves the data folder before `ready`, never from the
 * display name.
 */
export type Channel = "release" | "dev";

export interface Identity {
  productName: string;
  bundleID: string;
  dataFolder: string;
}

export function identity(channel: Channel): Identity {
  return channel === "release"
    ? { productName: "Octo", bundleID: "dev.octo.app", dataFolder: "Octo" }
    : { productName: "Octo Dev", bundleID: "dev.octo.app.dev", dataFolder: "Octo Dev" };
}
