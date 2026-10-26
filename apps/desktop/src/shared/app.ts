export interface AppInfo {
  productName: string;
  version: string;
  channel: "release" | "dev";
  platform: string;
  dataDirectory: string;
}
