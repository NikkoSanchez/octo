import { chmodSync, existsSync, linkSync, mkdirSync, readdirSync, readFileSync, renameSync, symlinkSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { afterEach, describe, expect, it } from "vitest";
import { CheckoutFileService, EDITOR_BYTE_LIMIT } from "../src/node";
import { mode, rejects, removeRoot, temporaryRoot } from "./helpers";

const roots: string[] = [];
const fixture = () => { const r = temporaryRoot("octo-files-"); roots.push(r); return r; };
afterEach(() => { while (roots.length) removeRoot(roots.pop()!); });

describe("CheckoutFileService", () => {
  it("creates, saves and deletes, preserving exact source and executable mode", async () => {
    const root = fixture();
    mkdirSync(join(root, "folder"));
    const path = "folder/café ' $ file.swift", service = new CheckoutFileService();
    await service.create(path, root);
    const url = join(root, path);
    expect(readFileSync(url).length).toBe(0);
    const original = "// 🐙\r\n\tlet value = 1\r\n\r\nno final newline";
    writeFileSync(url, original);
    chmodSync(url, 0o755);
    const document = await service.inspect(path, root, true);
    expect(document.text).toBe(original);
    const replacement = original.replaceAll("1", "2");
    await service.save(document, replacement);
    expect(readFileSync(url, "utf8")).toBe(replacement);
    expect(mode(url)).toBe(0o755);
    expect(readdirSync(join(root, "folder")).some((n) => n.startsWith(".octo-save-"))).toBe(false);
    const deletion = await service.inspect(path, root, false);
    await service.delete(deletion);
    expect(existsSync(url)).toBe(false);
  });

  it("never overwrites existing entries on create", async () => {
    const root = fixture();
    const service = new CheckoutFileService(), url = join(root, "existing");
    writeFileSync(url, "keep");
    await rejects(() => service.create("existing", root));
    expect(readFileSync(url, "utf8")).toBe("keep");
    mkdirSync(join(root, "folder"));
    await rejects(() => service.create("folder", root));
  });

  it("refuses to overwrite or delete changed, replaced and removed files", async () => {
    const root = fixture();
    const service = new CheckoutFileService(), url = join(root, "source");
    writeFileSync(url, "original");
    const original = await service.inspect("source", root, true);
    writeFileSync(url, "external");
    await rejects(() => service.save(original, "my edits"));
    await rejects(() => service.delete(original));
    expect(readFileSync(url, "utf8")).toBe("external");
    const next = await service.inspect("source", root, false);
    // An atomic replacement with identical bytes is a different file.
    writeFileSync(join(root, "tmp"), "external"); renameSync(join(root, "tmp"), url);
    await rejects(() => service.delete(next));
    removeRoot(url);
    await rejects(() => service.save(original, "must not recreate"));
    expect(existsSync(url)).toBe(false);
  });

  it("rejects traversal, symlinks, Git metadata and hard links", async () => {
    const root = fixture(), outside = fixture();
    const service = new CheckoutFileService(), secret = join(outside, "secret");
    writeFileSync(secret, "outside");
    symlinkSync(outside, join(root, "link"));
    symlinkSync(secret, join(root, "leaf"));
    for (const path of ["../escape", secret, "link/secret", "leaf", ".git/config", ".GIT/config", "a/../b", "a//b", "bad\0name"]) {
      await rejects(() => service.inspect(path, root, true));
      await rejects(() => service.create(path, root));
    }
    linkSync(secret, join(root, "hardlink"));
    await rejects(() => service.inspect("hardlink", root, true));
    await rejects(() => service.inspect("hardlink", root, false));
    expect(readFileSync(secret, "utf8")).toBe("outside");
  });

  it("does not let a parent replaced with a symlink redirect a mutation", async () => {
    const root = fixture(), outside = fixture();
    const service = new CheckoutFileService(), folder = join(root, "folder");
    mkdirSync(folder);
    writeFileSync(join(folder, "file"), "inside");
    const document = await service.inspect("folder/file", root, true);
    writeFileSync(join(outside, "file"), "outside");
    renameSync(folder, join(root, "moved"));
    symlinkSync(outside, folder);
    await rejects(() => service.save(document, "new"));
    await rejects(() => service.delete(document));
    expect(readFileSync(join(outside, "file"), "utf8")).toBe("outside");
  });

  it("bounds the editor to text and refuses read-only files", async () => {
    const root = fixture();
    const service = new CheckoutFileService();
    for (const [path, data] of [["binary", Buffer.from([0, 1, 2])], ["invalid", Buffer.from([0xff])], ["large", Buffer.alloc(EDITOR_BYTE_LIMIT + 1, 97)]] as const) {
      writeFileSync(join(root, path), data);
      await rejects(() => service.inspect(path, root, true));
      const file = await service.inspect(path, root, false);
      await service.delete(file);
    }
    const url = join(root, "readonly");
    writeFileSync(url, "keep");
    chmodSync(url, 0o444);
    const file = await service.inspect("readonly", root, true);
    await rejects(() => service.save(file, "overwrite"));
    expect(readFileSync(url, "utf8")).toBe("keep");
    chmodSync(url, 0o644);
  });

  it("leaves the original and no temporary file when a draft is rejected", async () => {
    const root = fixture();
    const service = new CheckoutFileService();
    await service.create("file", root);
    const file = await service.inspect("file", root, true);
    await rejects(() => service.save(file, "🐙".repeat(500_001)));
    await rejects(() => service.save(file, "bad\0data"));
    expect(readFileSync(join(root, "file")).length).toBe(0);
    expect(readdirSync(root)).toEqual(["file"]);
  });
});
