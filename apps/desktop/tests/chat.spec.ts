import { expect, test } from "@playwright/test";
import { writeFileSync } from "node:fs";
import { join } from "node:path";
import { launchApp } from "./fixtures";
const modifier = process.platform === "darwin" ? "Meta" : "Control";
function launchFixture() {
  return launchApp({}, (directory) => writeFileSync(join(directory, "preferences.json"), JSON.stringify({ codexExecutablePath: join(import.meta.dirname, "fixtures/codex-ui.py"), theme: "mocha" }), { mode: 0o600 }));
}
test("chat navigation retains drafts, supports IME and list editing, and searches a transcript", async () => {
  const { app, page, close } = await launchFixture();
  const errors: string[] = []; page.on("pageerror", (e) => errors.push(e.message));
  try {
    const editor = page.getByRole("textbox", { name: "Message", exact: true });
    await expect(editor).toBeVisible();
    await editor.fill("- one"); await editor.press("Shift+Enter");
    await expect(editor).toHaveValue("- one\n- ");
    await editor.press("Tab"); await expect(editor).toHaveValue("- one\n  - ");
    await editor.fill("unsubmitted draft"); await page.keyboard.press(`${modifier}+n`);
    await expect(editor).toHaveValue("unsubmitted draft");
    await editor.dispatchEvent("compositionstart");
    await editor.press("Enter");
    await expect(page.getByTestId("transcript")).not.toContainText("unsubmitted draft");
    await editor.dispatchEvent("compositionend");
    await editor.fill("hello fixture"); await editor.press("Enter");
    await expect(page.getByTestId("transcript")).toContainText("Fixture response complete.");
    await page.keyboard.press(`${modifier}+n`);
    await expect(editor).toHaveValue(""); await editor.fill("remember this draft");
    // ⌘K searches in the sidebar while it shows; Return opens the highlighted result.
    await page.keyboard.press(`${modifier}+k`);
    await page.getByRole("textbox", { name: "Search all chats", exact: true }).fill("hello fixture");
    await page.keyboard.press("Enter");
    await expect(page.getByTestId("transcript")).toContainText("hello fixture");
    await page.keyboard.press(`${modifier}+n`);
    await expect(editor).toHaveValue("remember this draft");
    await editor.fill("/");
    await expect(page.getByRole("option", { name: /fixture-review/ })).toBeVisible();
    await editor.press("Enter"); await expect(editor).toHaveValue("/fixture-review ");
    await expect(page.getByTestId("transcript")).not.toContainText("Fixture response complete.");
    await page.keyboard.press(`${modifier}+k`); await page.getByRole("textbox", { name: "Search all chats", exact: true }).fill("hello fixture"); await page.keyboard.press("Enter");
    await page.keyboard.press(`${modifier}+f`); await page.getByRole("textbox", { name: "Find in this thread", exact: true }).fill("response");
    await expect(page.locator("mark")).toContainText("response");
    await page.getByRole("button", { name: "Close search", exact: true }).click();
    await page.screenshot({ path: test.info().outputPath("chat.png") });
    await app.evaluate(({ BrowserWindow }) => BrowserWindow.getAllWindows()[0].setSize(480, 700));
    await expect(editor).toBeVisible();
    await expect(page.getByTestId("sidebar")).not.toBeInViewport();
    await page.keyboard.press(`${modifier}+b`); await expect(page.getByTestId("sidebar")).toBeInViewport();
    await page.getByRole("button", { name: "Close sidebar", exact: true }).click();
    await page.screenshot({ path: test.info().outputPath("compact.png") });
    expect(errors).toEqual([]);
  } finally { await close(); }
});
test("follow-ups queue, stop pauses delivery, and an explicit action resumes", async () => {
  const { page, close } = await launchFixture();
  try {
    const editor = page.getByRole("textbox", { name: "Message", exact: true });
    await editor.fill("hold"); await editor.press("Enter");
    await expect(page.getByTestId("transcript")).toContainText("Waiting for your next action.");
    await editor.fill("follow-up"); await editor.press("Enter");
    await expect(page.getByText("Queued · 1")).toBeVisible();
    await expect(page.getByRole("button", { name: "Steer now", exact: true })).toBeVisible();
    await page.getByRole("button", { name: "Stop", exact: true }).click();
    await expect(page.getByText("Queue paused. Messages are kept here until you send them.")).toBeVisible();
    await page.getByRole("button", { name: "Send queued", exact: true }).click();
    await expect(page.getByTestId("transcript")).toContainText("Fixture response complete.");
    await expect(page.getByText("Queued · 1")).toHaveCount(0);
  } finally { await close(); }
});
test("provider decisions require an explicit reply and are retired on stop", async () => {
  const { page, close } = await launchFixture();
  try {
    const editor = page.getByRole("textbox", { name: "Message", exact: true });
    await editor.fill("question"); await editor.press("Enter");
    await expect(page.getByRole("button", { name: "Submit response", exact: true })).toBeDisabled();
    await expect(page.getByTestId("transcript")).not.toContainText("Fixture decision received.");
    await page.getByRole("radio", { name: "North", exact: true }).check();
    await page.getByRole("button", { name: "Submit response", exact: true }).click();
    await expect(page.getByTestId("transcript")).toContainText("Fixture decision received.");
    await editor.fill("approval"); await editor.press("Enter");
    await expect(page.getByRole("button", { name: "Allow Once", exact: true })).toBeVisible();
    await page.getByRole("button", { name: "Stop", exact: true }).click();
    await expect(page.getByRole("button", { name: "Allow Once", exact: true })).toHaveCount(0);
    await editor.fill("approval"); await editor.press("Enter");
    await page.getByRole("button", { name: "Allow Once", exact: true }).click();
    await expect(page.getByTestId("transcript").getByText("Fixture decision received.", { exact: true })).toHaveCount(2);
  } finally { await close(); }
});

test("reading earlier output stays put as more output arrives", async () => {
  const { page, close } = await launchFixture();
  try {
    const editor = page.getByRole("textbox", { name: "Message", exact: true });
    const transcript = page.getByTestId("transcript");
    await editor.fill("long"); await editor.press("Enter");
    await expect(transcript).toContainText("Reading line 299");
    await expect.poll(() => transcript.evaluate((node) => node.scrollHeight - node.clientHeight - node.scrollTop)).toBeLessThan(72);
    // Following streamed output never draws the scrollbar; the user's own scrolling does, until it fades.
    await expect(transcript).not.toHaveAttribute("data-scrolling");
    // Only the user's own scrolling changes follow intent; streamed layout never does.
    await transcript.hover(); await page.mouse.wheel(0, -100_000);
    await expect.poll(() => transcript.evaluate((node) => node.scrollTop)).toBe(0);
    await expect(transcript).toHaveAttribute("data-scrolling");
    await expect(transcript).not.toHaveAttribute("data-scrolling");
    await expect(page.getByRole("button", { name: "Working · Scroll to end", exact: true })).toBeVisible();
    await editor.fill("more output"); await editor.press("Enter");
    await page.getByRole("button", { name: "Steer now", exact: true }).click();
    await expect(transcript).toContainText("Additional output while you are reading.");
    expect(await transcript.evaluate((node) => node.scrollTop)).toBeLessThan(20);
    await page.getByRole("button", { name: "Working · Scroll to end", exact: true }).click();
    await expect.poll(() => transcript.evaluate((node) => node.scrollHeight - node.clientHeight - node.scrollTop)).toBeLessThan(72);
    await page.getByRole("button", { name: "Stop", exact: true }).click();
  } finally { await close(); }
});

test("work between replies collapses into one disclosure and the finished turn says how long it took", async () => {
  const { page, close } = await launchFixture();
  try {
    const editor = page.getByRole("textbox", { name: "Message", exact: true });
    await editor.fill("work"); await editor.press("Enter");
    const transcript = page.getByTestId("transcript");
    await expect(transcript.getByRole("strong")).toHaveText("correct");
    const disclosure = transcript.getByRole("button", { name: "Thought and 2 steps", exact: true });
    await expect(disclosure).toHaveAttribute("aria-expanded", "false");
    await expect(transcript).not.toContainText("git diff --stat");
    await disclosure.click();
    await expect(transcript).toContainText("git diff --stat");
    await expect(transcript).toContainText(/Worked for \d+s/);
  } finally { await close(); }
});
