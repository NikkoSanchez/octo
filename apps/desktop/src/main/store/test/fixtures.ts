import { mkdirSync, realpathSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { randomUUID } from "node:crypto";
import { HarnessRegistry, type AgentEvent, type AgentHarness, type AgentInteractionResponse } from "@octo/agents";
import { makeImage, type AgentSettings, type ImageAttachment } from "@octo/core";
import { WorkspaceStore } from "@octo/core/node";
import { AppStore, type PlatformServices, type UIEvent } from "../appStore";
import { PreferencesFile } from "../preferences";

export function temporaryRoot(): string {
  const root = join(realpathSync(tmpdir()), "octo-store-" + randomUUID());
  mkdirSync(root, { recursive: true });
  return root;
}
export const removeRoot = (root: string) => rmSync(root, { recursive: true, force: true });

/** CI runners have no provider CLIs; fixtures that send through a fake harness don't depend on the host. */
export function fixtureExecutables() {
  return { descriptors: HarnessRegistry.descriptors().map((d) => ({ ...d, executable: "/usr/bin/true" })), codex: "/usr/bin/true" };
}

export const PNG_1x1 = Buffer.from("iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNkYAAAAAYAAjCB0C8AAAAASUVORK5CYII=", "base64");

export class FakePlatform implements PlatformServices {
  clipboard: Buffer | undefined;
  directories: string[] = [];
  async chooseDirectory() { return this.directories.shift(); }
  async chooseFile() { return undefined; }
  async chooseImages() { return []; }
  decodeImage(data: Buffer, name: string): ImageAttachment {
    if (!data.subarray(0, 8).equals(PNG_1x1.subarray(0, 8))) throw new Error("Could not attach this image. Use a supported image up to 30 MB, 32 megapixels, and 5 MB after PNG conversion.");
    return makeImage(data.toString("base64"), name);
  }
  async readImageFile(): Promise<ImageAttachment> { throw new Error("unsupported"); }
  async clipboardImage() { return this.clipboard; }
  systemDark() { return false; }
}

export class QueueHarness implements AgentHarness {
  onEvent?: (event: AgentEvent) => void;
  sent: string[] = [];
  sentSettings: AgentSettings[] = [];
  sentImages: ImageAttachment[][] = [];
  steered: string[] = [];
  steering?: { resolve: () => void; reject: (error: Error) => void };
  async send(prompt: string, _session: string | undefined, _directory: string, settings: AgentSettings = {}, images: ImageAttachment[] = []) {
    this.sent.push(prompt); this.sentImages.push(images); this.sentSettings.push(settings);
    this.onEvent?.({ type: "session", id: "fixture-session" });
  }
  steer(prompt: string): Promise<void> {
    this.steered.push(prompt);
    return new Promise((resolve, reject) => { this.steering = { resolve, reject }; });
  }
  respond(_id: string, _response: AgentInteractionResponse) {}
  async interrupt() { this.onEvent?.({ type: "interrupted" }); }
  shutdown() { this.steering?.reject(new Error("cancelled")); this.steering = undefined; }
}

export async function makeStore(root: string, options: { harness?: AgentHarness; real?: boolean } = {}) {
  const storage = new WorkspaceStore(join(root, "data", "workspace.json"));
  const platform = new FakePlatform();
  const events: UIEvent[] = [];
  const store = new AppStore({
    storage, preferences: new PreferencesFile(join(root)), platform, ui: (e) => events.push(e),
    ...(options.harness ? { harnessFactory: () => options.harness! } : {}),
    titleGenerator: async () => undefined,
    resolveExecutables: options.real ? undefined : fixtureExecutables,
    timing: { save: 10_000, stream: 33 },
  });
  await store.load();
  return { store, storage, platform, events };
}

/** Lets queued microtasks, immediates and short timers run. */
export async function settle(): Promise<void> {
  for (let i = 0; i < 5; i++) await new Promise((resolve) => setImmediate(resolve));
}
