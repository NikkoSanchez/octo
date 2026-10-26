import { expect, test } from "@playwright/test";
import { execFileSync } from "node:child_process";
import { readFileSync, writeFileSync } from "node:fs";
import { createServer } from "node:http";
import { join } from "node:path";
import { chooseMenuItem } from "./fixtures";
import { launchProject } from "./projectFixture";
const modifier = process.platform === "darwin" ? "Meta" : "Control";

test("reviews and stages a change, captures code to the draft and edits a retained file", async () => {
  const { app, page, root, close } = await launchProject();
  const errors: string[] = []; page.on("pageerror", (e) => errors.push(e.message));
  try {
    await page.keyboard.press(`${modifier}+2`);
    await expect(page.getByRole("button", { name: "Stage example.ts", exact: true })).toBeVisible();
    const line = page.locator("diffs-container [data-line]").filter({ hasText: "hello 🐙" }).last();
    await expect(line).toBeVisible(); await line.hover();
    await page.getByRole("button", { name: "Attach selected code to draft", exact: true }).first().click();
    await expect(page.getByRole("button", { name: "Remove attachment", exact: true })).toBeVisible();
    await expect(page.getByTestId("transcript")).not.toContainText("const greeting");
    await page.getByRole("button", { name: "Stage Hunk 1", exact: true }).click();
    await expect.poll(() => execFileSync("git", ["diff", "--cached", "--name-only"], { cwd: root, encoding: "utf8" })).toContain("example.ts");
    await expect(page.getByRole("button", { name: "Unstage example.ts", exact: true })).toBeVisible();
    const commitMessage = page.getByRole("textbox", { name: "Commit message", exact: true });
    await commitMessage.fill("My original draft");
    await page.getByRole("button", { name: "Generate", exact: true }).click();
    await expect(commitMessage).toHaveValue("Update the fixture greeting");
    await commitMessage.press(`${modifier}+z`); await expect(commitMessage).toHaveValue("My original draft");
    await page.getByRole("button", { name: "Unstage example.ts", exact: true }).click();
    await page.keyboard.press(`${modifier}+p`);
    const finder = page.getByRole("dialog", { name: "Find file", exact: true });
    await finder.getByRole("textbox", { name: "Search", exact: true }).fill("example.ts"); await finder.getByRole("option").first().click();
    const editor = page.getByTestId("file-editor").getByRole("textbox");
    await expect(editor).toBeVisible(); await editor.click(); await editor.press(`${modifier}+a`); await page.keyboard.type("const edited = 42;"); await page.keyboard.press("Enter");
    await editor.press(`${modifier}+s`);
    await expect.poll(() => readFileSync(join(root, "example.ts"), "utf8")).toBe("const edited = 42;\n");
    await editor.press(`${modifier}+f`);
    const fileSearch = page.getByTestId("file-editor").getByPlaceholder("Search", { exact: true });
    await expect(fileSearch).toBeVisible(); await fileSearch.fill("edited"); await fileSearch.press("Escape");
    await page.keyboard.press(`${modifier}+2`);
    await page.keyboard.press(`${modifier}+3`);
    await expect(editor).toContainText("const edited = 42;");
    await editor.click(); await editor.press(`${modifier}+z`); await editor.press(`${modifier}+s`);
    await expect.poll(() => readFileSync(join(root, "example.ts"), "utf8")).not.toBe("const edited = 42;\n");
    await editor.press(`${modifier}+Shift+z`); await editor.press(`${modifier}+s`);
    await expect.poll(() => readFileSync(join(root, "example.ts"), "utf8")).toBe("const edited = 42;\n");
    writeFileSync(join(root, "example.ts"), "outside change\n");
    await editor.click(); await editor.press(`${modifier}+a`); await page.keyboard.type("draft to preserve"); await page.keyboard.press("Enter");
    await editor.press(`${modifier}+s`);
    await expect(page.getByRole("alert")).toContainText("changed on disk");
    expect(readFileSync(join(root, "example.ts"), "utf8")).toBe("outside change\n");
    await expect(editor).toContainText("draft to preserve");
    await page.screenshot({ path: test.info().outputPath("review-editor.png") });
    expect(errors).toEqual([]);
    // Refusing quit must preserve both the window and the conflicting edit. Answer the native
    // dialog explicitly in this isolated app, then use the real Reload UI to discard the fixture.
    await app.evaluate(({ app, dialog }) => {
      const state = globalThis as unknown as { quitMessages: string[]; originalMessageBox: typeof dialog.showMessageBox };
      state.quitMessages = []; state.originalMessageBox = dialog.showMessageBox;
      dialog.showMessageBox = (async (options: Electron.MessageBoxOptions) => { state.quitMessages.push(options.message); return { response: 0, checkboxChecked: false }; }) as typeof dialog.showMessageBox;
      app.quit();
    });
    await expect.poll(() => app.evaluate(() => (globalThis as unknown as { quitMessages: string[] }).quitMessages)).toContain("Some file edits could not be saved.");
    await expect(editor).toContainText("draft to preserve");
    await app.evaluate(({ dialog }) => { dialog.showMessageBox = (async () => ({ response: 1, checkboxChecked: false })) as typeof dialog.showMessageBox; });
    await page.getByRole("button", { name: "Reload", exact: true }).click();
    await expect(editor).toContainText("outside change");
    await app.evaluate(({ dialog }) => { dialog.showMessageBox = (globalThis as unknown as { originalMessageBox: typeof dialog.showMessageBox }).originalMessageBox; });
    await page.keyboard.press(`${modifier}+1`);
    const composer = page.getByRole("textbox", { name: "Message", exact: true }); await composer.fill("Review the attached code"); await composer.press("Enter");
    await expect(page.getByTestId("transcript")).toContainText("Fixture response complete.");
    const captures = await page.evaluate(async () => { const { state } = await window.octo.call("app", "snapshot"); return state.archive.projects.flatMap((p) => p.threads).flatMap((t) => t.messages).filter((m) => m.role === "user").flatMap((m) => m.attachments); });
    expect(captures).toHaveLength(1); expect(captures[0].path).toBe("example.ts");
  } catch (error) { await page.screenshot({ path: test.info().outputPath("failure.png") }); console.log(await page.locator("body").innerText()); console.log(errors); throw error; } finally { await close(); }
});

test("terminal state survives hiding, tab changes, split resize and a TUI", async () => {
  const { app, page, root, close } = await launchProject();
  const errors: string[] = []; page.on("pageerror", (e) => errors.push(e.message));
  try {
    await page.keyboard.press(`${modifier}+j`);
    const input = page.getByRole("textbox", { name: "Terminal input", exact: true });
    await expect(input).toHaveCount(1);
    await input.focus(); await page.keyboard.insertText("printf 'OCTO_%s\\n' 'SHELL_OK'\n");
    await expect.poll(() => page.evaluate(async () => Object.values((await window.octo.call("terminal", "snapshot")).replay).join(""))).toContain("OCTO_SHELL_OK");
    await page.keyboard.insertText("seq 1 400\n");
    const scrollback = page.getByRole("scrollbar", { name: "Terminal scrollback", exact: true });
    await expect(scrollback).toBeVisible(); await expect(scrollback).not.toHaveAttribute("data-scrolling");
    await page.locator("[data-pane] canvas").first().hover(); await page.mouse.wheel(0, -300);
    await expect(scrollback).toHaveAttribute("data-scrolling"); await expect(scrollback).not.toHaveAttribute("data-scrolling");
    const first = await input.evaluate((node) => node.closest("[data-pane]")!.getAttribute("data-pane"));
    await page.keyboard.press(`${modifier}+j`);
    await expect(page.getByRole("textbox", { name: "Message", exact: true })).toBeVisible();
    await page.keyboard.press(`${modifier}+j`);
    expect(await input.evaluate((node) => node.closest("[data-pane]")!.getAttribute("data-pane"))).toBe(first);
    await page.getByRole("button", { name: "New terminal tab", exact: true }).click();
    await expect(page.locator('[data-pane] textarea')).toHaveCount(2);
    await page.getByRole("button", { name: "Split terminal right", exact: true }).click();
    await expect(page.locator('[data-pane] textarea')).toHaveCount(3);
    const active = page.getByRole("textbox", { name: "Terminal input", exact: true });
    await expect(active).toHaveCount(2);
    await active.last().focus(); await page.keyboard.insertText("printf 'SPLIT_%s\\n' 'ALIVE'\n");
    await expect.poll(() => page.evaluate(async () => Object.values((await window.octo.call("terminal", "snapshot")).replay).join(""))).toContain("SPLIT_ALIVE");
    await page.getByRole("button", { name: "Zoom terminal pane", exact: true }).click();
    await expect(page.getByRole("textbox", { name: "Terminal input", exact: true })).toHaveCount(1);
    await page.getByRole("button", { name: "Zoom terminal pane", exact: true }).click();
    await expect(page.getByRole("textbox", { name: "Terminal input", exact: true })).toHaveCount(2);
    const divider = page.getByRole("separator", { name: "Resize terminal split", exact: true });
    await divider.focus(); await divider.press("ArrowRight"); await expect(divider).toHaveAttribute("aria-valuenow", "55");
    // Exercise a real terminal UI without plugins or provider calls; the user's config is tested by Open in separately.
    await active.last().focus(); await page.keyboard.insertText("vi -u NONE -i NONE example.ts\n");
    await expect.poll(() => page.evaluate(async () => Object.values((await window.octo.call("terminal", "snapshot")).replay).join(""))).toContain("\u001b[?1049h");
    await page.keyboard.press("Escape"); await page.keyboard.insertText(":qa!\n");
    await page.keyboard.insertText("printf 'BACK_%s\\n' 'TO_SHELL'\n");
    await expect.poll(() => page.evaluate(async () => Object.values((await window.octo.call("terminal", "snapshot")).replay).join(""))).toContain("BACK_TO_SHELL");
    await app.evaluate(({ BrowserWindow }) => BrowserWindow.getAllWindows()[0].setSize(1000, 720));
    await expect(active).toHaveCount(2);
    await expect.poll(() => active.first().evaluate((node) => { const pane = node.closest("[data-pane]")!; return Math.abs(pane.getBoundingClientRect().width - (pane.parentElement!.clientWidth - 5) * 0.55); })).toBeLessThan(2);
    await page.screenshot({ path: test.info().outputPath("terminal-splits.png") });
    expect(errors).toEqual([]);
  } catch (error) { await page.screenshot({ path: test.info().outputPath("failure.png") }); console.log(await page.locator("body").innerText()); console.log(errors); throw error; } finally { await close(); }
});

test("native browser pages retain state, isolate private storage and attach annotations", async () => {
  const server = createServer((_req, res) => { res.setHeader("Content-Type", "text/html"); res.end('<!doctype html><title>Fixture page</title><body><button id="pick" style="margin:40px;padding:20px">Pick this element</button><script>window.fixtureValue=123</script></body>'); });
  await new Promise<void>((resolve) => server.listen(0, "127.0.0.1", resolve));
  const port = (server.address() as { port: number }).port;
  const { app, page, close } = await launchProject();
  try {
    await page.keyboard.press(`${modifier}+5`);
    const address = page.getByRole("textbox", { name: "Address", exact: true });
    await expect(address).toBeVisible(); await address.fill(`http://127.0.0.1:${port}`); await address.press("Enter");
    await expect.poll(() => app.context().pages().some((p) => p.url().startsWith(`http://127.0.0.1:${port}`))).toBe(true);
    const browser = app.context().pages().find((p) => p.url().startsWith(`http://127.0.0.1:${port}`))!;
    await expect(browser.getByRole("button", { name: "Pick this element" })).toBeVisible();
    expect(await browser.evaluate(() => typeof (window as unknown as { require?: unknown }).require)).toBe("undefined");
    await browser.evaluate(() => { localStorage.setItem("fixture", "normal"); (window as unknown as { retained: string }).retained = "kept"; });
    await page.getByRole("button", { name: "Annotate elements and regions", exact: true }).click();
    // Picker owns pointer events in an isolated world, so click viewport coordinates.
    const bounds = await browser.getByRole("button", { name: "Pick this element" }).boundingBox();
    await browser.mouse.click(bounds!.x + bounds!.width / 2, bounds!.y + bounds!.height / 2);
    await expect(page.getByRole("button", { name: "Remove annotation", exact: true })).toBeVisible();
    await expect(page.getByTestId("transcript")).not.toContainText("Pick this element");
    await browser.getByRole("button", { name: "Pick this element" }).focus(); await browser.keyboard.press(`${modifier}+1`);
    await expect(page.getByRole("textbox", { name: "Message", exact: true })).toBeFocused();
    await page.keyboard.press(`${modifier}+2`); await page.keyboard.press(`${modifier}+5`);
    expect(await browser.evaluate(() => (window as unknown as { retained: string }).retained)).toBe("kept");
    // Private tab creation through the same typed operation used by the native menu.
    await page.evaluate(async () => { const { state } = await window.octo.call("app", "snapshot"); const project = state.archive.projects.find((p) => p.id === state.archive.selectedProjectID)!; await window.octo.call("store", "updatePanelTabsAction", project.id, { type: "openBrowser", id: crypto.randomUUID().toUpperCase(), isPrivate: true }); });
    await expect(page.getByRole("tab", { name: "Private", exact: true })).toHaveAttribute("aria-selected", "true");
    await address.fill(`http://127.0.0.1:${port}`); await address.press("Enter");
    await expect.poll(() => app.context().pages().filter((p) => p.url().startsWith(`http://127.0.0.1:${port}`)).length).toBe(2);
    const privatePage = app.context().pages().filter((p) => p.url().startsWith(`http://127.0.0.1:${port}`)).find((p) => p !== browser)!;
    expect(await privatePage.evaluate(() => localStorage.getItem("fixture"))).toBeNull();
    await page.screenshot({ path: test.info().outputPath("browser.png") });
  } catch (error) { await page.screenshot({ path: test.info().outputPath("failure.png") }); console.log(await page.locator("body").innerText()); throw error; } finally { await close(); server.closeAllConnections(); await new Promise<void>((resolve) => server.close(() => resolve())); }
});


test("the Files editor scrolls a long file vertically and wraps long lines on request", async () => {
  const { page, root, close } = await launchProject();
  try {
    const long = Array.from({ length: 300 }, (_, i) => `line ${i + 1} ${"wide ".repeat(i === 0 ? 80 : 1)}`).join("\n") + "\n";
    writeFileSync(join(root, "long.txt"), long);
    await page.keyboard.press(`${modifier}+2`); await page.keyboard.press(`${modifier}+Shift+r`);
    await expect(page.getByTestId("change-file-list")).toContainText("long.txt");
    await page.keyboard.press(`${modifier}+p`);
    const finder = page.getByRole("dialog", { name: "Find file", exact: true });
    await finder.getByRole("textbox", { name: "Search", exact: true }).fill("long.txt"); await finder.getByRole("option", { name: /long\.txt/ }).first().click();
    const editor = page.getByTestId("file-editor");
    await expect(editor.getByRole("textbox")).toBeVisible();
    const scrollTop = () => editor.evaluate((node) => Math.max(0, ...[...node.querySelectorAll<HTMLElement>("*")].map((e) => e.scrollTop)));
    const box = (await editor.boundingBox())!;
    await page.mouse.move(box.x + box.width / 2, box.y + box.height / 2);
    await page.mouse.wheel(0, 2000);
    await expect.poll(scrollTop).toBeGreaterThan(0);
    await expect(editor.locator("pre[data-overflow]")).toHaveAttribute("data-overflow", "scroll");
    const wrap = page.getByRole("button", { name: "Wrap lines", exact: true });
    await wrap.click();
    await expect(wrap).toHaveAttribute("aria-pressed", "true");
    await expect(editor.locator("pre[data-overflow]")).toHaveAttribute("data-overflow", "wrap");
  } finally { await close(); }
});

test("selecting a changed file scrolls the diff, not the window layout", async () => {
  const { page, root, close } = await launchProject();
  try {
    writeFileSync(join(root, "second.ts"), Array.from({ length: 80 }, (_, i) => `export const v${i} = ${i};`).join("\n") + "\n");
    await page.keyboard.press(`${modifier}+2`); await page.keyboard.press(`${modifier}+Shift+r`);
    const list = page.getByTestId("change-file-list");
    await expect(list).toContainText("second.ts");
    const before = (await list.boundingBox())!;
    await list.getByText("second.ts").click();
    await expect.poll(() => page.evaluate(() => [...document.querySelectorAll("*")].some((e) => e.scrollTop > 0))).toBe(true);
    expect((await list.boundingBox())!.y).toBe(before.y);
  } finally { await close(); }
});

test("Open in Neovim reuses the user-configured session and returns to its shell", async () => {
  const { page, root, close } = await launchProject();
  try {
    const projectID = await page.evaluate(async () => (await window.octo.call("app", "snapshot")).state.archive.selectedProjectID!);
    const open = () => page.evaluate(({ projectID, root }) => window.octo.call("app", "openTarget", "neovim", { projectID, checkout: root, path: "example.ts", line: 1 }), { projectID, root });
    await open();
    await expect.poll(() => page.evaluate(async () => (await window.octo.call("terminal", "snapshot")).workspace.tabs.filter((t) => t.editor).length)).toBe(1);
    const initial = await page.evaluate(async () => (await window.octo.call("terminal", "snapshot")).workspace.tabs.find((t) => t.editor)!.id);
    await expect.poll(() => page.evaluate(async () => Object.values((await window.octo.call("terminal", "snapshot")).replay).join("")), { timeout: 15000 }).toContain("hello");
    await open();
    expect(await page.evaluate(async () => (await window.octo.call("terminal", "snapshot")).workspace.tabs.filter((t) => t.editor).map((t) => t.id))).toEqual([initial]);
    const input = page.getByRole("textbox", { name: "Terminal input", exact: true }); await input.focus();
    await page.keyboard.press("Escape"); await page.keyboard.type(":qa!"); await page.keyboard.press("Enter");
    await expect.poll(() => page.evaluate(async () => (await window.octo.call("terminal", "snapshot")).workspace.tabs.filter((t) => t.editor).length), { timeout: 15000 }).toBe(0);
    await page.keyboard.insertText("printf 'NVIM_%s\\n' 'SHELL_OK'\n");
    await expect.poll(() => page.evaluate(async () => Object.values((await window.octo.call("terminal", "snapshot")).replay).join(""))).toContain("NVIM_SHELL_OK");
  } finally { await close(); }
});


test("project actions, theme gallery and usage remain available after hiding the window", async () => {
  const { app, page, root, close } = await launchProject();
  const errors: string[] = []; page.on("pageerror", (error) => errors.push(error.message));
  try {
    execFileSync("git", ["branch", "fixture-branch"], { cwd: root });
    await page.getByRole("button", { name: "Project actions", exact: true }).click();
    await page.getByRole("button", { name: "Branch main. Switch branch", exact: true }).click();
    await page.getByRole("option", { name: "fixture-branch", exact: true }).click();
    await expect.poll(() => execFileSync("git", ["branch", "--show-current"], { cwd: root, encoding: "utf8" }).trim()).toBe("fixture-branch");
    // The picker closes once the checkout refresh finishes; until then Escape would close it instead of Project actions.
    await expect(page.getByRole("dialog", { name: "Switch branch", exact: true })).toHaveCount(0);
    await page.keyboard.press("Escape"); await page.keyboard.press(`${modifier}+2`);
    await chooseMenuItem(app, "Stash Changes…");
    await page.getByRole("button", { name: "More Git actions", exact: true }).click();
    await page.getByRole("textbox", { name: "Stash name", exact: true }).fill("Fixture stash");
    await page.getByRole("button", { name: "Stash Changes", exact: true }).click();
    await expect.poll(() => readFileSync(join(root, "example.ts"), "utf8")).not.toContain("hello 🐙");
    await chooseMenuItem(app, "Stashes (1)…");
    await page.getByRole("button", { name: "More Git actions", exact: true }).click();
    await expect(page.getByRole("button", { name: "Apply", exact: true })).toBeVisible();
    await page.screenshot({ path: test.info().outputPath("project-actions.png") });
    await page.getByRole("button", { name: "Apply", exact: true }).click();
    await expect.poll(() => readFileSync(join(root, "example.ts"), "utf8")).toContain("hello 🐙");
    await page.getByRole("button", { name: "Done", exact: true }).click();
    await page.getByRole("button", { name: "Settings", exact: true }).click();
    await page.getByRole("button", { name: "Appearance", exact: true }).click();
    await page.getByRole("button", { name: "Catppuccin Latte", exact: true }).click();
    await expect(page.getByRole("button", { name: "Catppuccin Latte", exact: true })).toHaveAttribute("aria-pressed", "true");
    await page.screenshot({ path: test.info().outputPath("theme-gallery.png") });
    await page.keyboard.press("Escape");
    await page.getByRole("button", { name: "Account usage limits", exact: true }).click();
    await page.getByRole("button", { name: "Usage Dashboard", exact: true }).click();
    await expect(page.getByRole("dialog", { name: "Usage", exact: true })).toContainText("All providers");
    await page.getByRole("button", { name: "Past 24h", exact: true }).click();
    await expect(page.getByRole("button", { name: "Refresh usage", exact: true })).toBeEnabled();
    await page.screenshot({ path: test.info().outputPath("usage.png") });
    await page.keyboard.press("Escape");
    await page.keyboard.press(`${modifier}+j`);
    await expect(page.getByRole("textbox", { name: "Terminal input", exact: true })).toBeVisible();
    const pane = await page.getByRole("textbox", { name: "Terminal input", exact: true }).evaluate((n) => n.closest("[data-pane]")!.getAttribute("data-pane"));
    await app.evaluate(({ BrowserWindow }) => BrowserWindow.getAllWindows()[0].close());
    expect(await app.evaluate(({ BrowserWindow }) => BrowserWindow.getAllWindows()[0].isVisible())).toBe(false);
    await app.evaluate(({ app }) => app.emit("activate"));
    await expect(page.getByRole("textbox", { name: "Terminal input", exact: true })).toBeVisible();
    expect(await page.getByRole("textbox", { name: "Terminal input", exact: true }).evaluate((n) => n.closest("[data-pane]")!.getAttribute("data-pane"))).toBe(pane);
    expect(errors).toEqual([]);
  } finally { await close(); }
});


test("matches Octo's canvas, right panel and closed-panel project card", async () => {
  const { app, page, close } = await launchProject();
  try {
    const sidebar = page.getByTestId("sidebar");
    await expect(page.getByRole("button", { name: "Show review panel", exact: true })).toHaveAttribute("title", "Show review panel (⌥⌘B)");
    await page.keyboard.press(`${modifier}+Alt+b`);
    await expect(page.getByRole("button", { name: "Hide review panel", exact: true })).toBeVisible();
    const panel = page.getByTestId("review-panel");
    await expect(panel).toBeInViewport();
    const top = await panel.boundingBox(), sidebarBox = await sidebar.boundingBox();
    expect(Math.abs(top!.y-sidebarBox!.y)).toBeLessThan(1);
    const list = page.getByTestId("change-file-list"), diffs = page.getByTestId("change-diffs");
    await expect(list).toBeVisible();
    const listBox = await list.boundingBox(), diffBox = await diffs.boundingBox();
    expect(listBox!.y + listBox!.height).toBeLessThanOrEqual(diffBox!.y);
    expect(Math.abs(listBox!.x-diffBox!.x)).toBeLessThan(1);
    await expect(page.getByText("Stage files or hunks to commit them", { exact: true })).toBeVisible();
    await page.screenshot({ path: test.info().outputPath("octo-review-layout.png") });
    await page.keyboard.press(`${modifier}+Alt+b`);
    await expect(panel).not.toBeInViewport();
    await app.evaluate(({ BrowserWindow }) => BrowserWindow.getAllWindows()[0].setSize(1900, 900));
    const card = page.getByTestId("project-card");
    await expect(card).toBeVisible(); await expect(card.getByRole("button", { name: "Open in Neovim", exact: true })).toBeVisible(); await expect(card.getByRole("button", { name: "Show changes", exact: true })).toBeVisible();
    await expect(page.getByRole("button", { name: "Project actions", exact: true })).toHaveCount(0);
    await page.screenshot({ path: test.info().outputPath("octo-floating-project-card.png") });
    await card.getByRole("button", { name: "Show changes", exact: true }).click();
    await expect(panel).toBeInViewport(); await expect(card).toHaveCount(0);
    await page.keyboard.press(`${modifier}+j`);
    await expect(panel).not.toBeInViewport();
    await expect(page.getByRole("button", { name: "Back to thread", exact: true })).toBeVisible();
    await page.keyboard.press(`${modifier}+j`); await expect(panel).toBeInViewport();
    await app.evaluate(({ BrowserWindow }) => BrowserWindow.getAllWindows()[0].setSize(480, 700));
    await expect(panel).toBeInViewport();
    await expect(page.getByRole("textbox", { name: "Message", exact: true })).toHaveCount(0);
    await page.keyboard.press(`${modifier}+1`);
    await expect(page.getByRole("textbox", { name: "Message", exact: true })).toBeFocused();
    await app.evaluate(({ BrowserWindow }) => BrowserWindow.getAllWindows()[0].setSize(1380, 880));
    await page.keyboard.press(`${modifier}+,`);
    await page.getByRole("button", { name: "Keyboard", exact: true }).click();
    await expect(page.getByRole("row").filter({ hasText: "Toggle left sidebar / review panel" }).getByRole("cell").last()).toHaveText("⌘B / ⌥⌘B");
    await expect(page.getByRole("dialog", { name: "Settings", exact: true })).not.toContainText("Alt");
  } finally { await close(); }
});
