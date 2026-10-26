import { describe, expect, it } from "vitest";
import { identity } from "./identity";

describe("identity", () => {
  it("gives release and development separate names, bundle IDs and data folders", () => {
    expect(identity("release")).toEqual({ productName: "Octo", bundleID: "dev.octo.app", dataFolder: "Octo" });
    expect(identity("dev")).toEqual({ productName: "Octo Dev", bundleID: "dev.octo.app.dev", dataFolder: "Octo Dev" });
  });
});
