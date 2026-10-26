/** How long a scrollbar stays drawn after the last scroll. */
const IDLE_MS = 1000;
const FADE_MS = 300;
/** Input this recent makes a scroll the user's: wheels and momentum keep arriving after the finger lifts. */
const USER_SCROLL_WINDOW = 250;
const SCROLL_KEYS = new Set(["PageUp", "PageDown", "Home", "End", "ArrowUp", "ArrowDown", "ArrowLeft", "ArrowRight", " "]);

const hideTimers = new WeakMap<Element, number>();
const fades = new WeakMap<Element, Animation>();

/**
 * Draws `element`'s scrollbar, then fades it after a pause. `data-scrolling` sets `--scrollbar-thumb`,
 * which thumbs inherit (global.css); the fade animates that property back to transparent.
 */
export function revealScrollbar(element: Element): void {
  fades.get(element)?.cancel();
  fades.delete(element);
  element.setAttribute("data-scrolling", "");
  window.clearTimeout(hideTimers.get(element));
  hideTimers.set(element, window.setTimeout(() => fadeScrollbar(element), IDLE_MS));
}

function fadeScrollbar(element: Element): void {
  hideTimers.delete(element);
  if (window.matchMedia("(prefers-reduced-motion: reduce)").matches) { element.removeAttribute("data-scrolling"); return; }
  const fade = element.animate({ "--scrollbar-thumb": "transparent" }, { duration: FADE_MS, easing: "ease-out", fill: "forwards" });
  fades.set(element, fade);
  fade.onfinish = () => { element.removeAttribute("data-scrolling"); fade.cancel(); fades.delete(element); };
}

/**
 * Shows a scroller's scrollbars only while the user scrolls it, like macOS overlay scrollbars.
 * Programmatic scrolling (a transcript following streamed output, scrollIntoView) leaves them hidden.
 */
export function installScrollbarFade(): void {
  let lastInput = 0, pointerHeld = false;
  const input = () => { lastInput = performance.now(); };
  const release = () => { pointerHeld = false; };
  window.addEventListener("wheel", input, { capture: true, passive: true });
  window.addEventListener("touchmove", input, { capture: true, passive: true });
  // Keys typed into a field move its caret, not a scroller.
  window.addEventListener("keydown", (event) => {
    const target = event.target;
    if (target instanceof HTMLElement && (target.isContentEditable || target.matches("input, textarea, select"))) return;
    if (SCROLL_KEYS.has(event.key)) input();
  }, { capture: true });
  // A held pointer covers dragging a scrollbar or extending a selection past the edge.
  window.addEventListener("pointerdown", () => { pointerHeld = true; }, { capture: true });
  window.addEventListener("pointerup", release, { capture: true });
  window.addEventListener("pointercancel", release, { capture: true });
  window.addEventListener("blur", release);
  document.addEventListener("scroll", (event) => {
    if (!(event.target instanceof Element)) return;
    if (pointerHeld || performance.now() - lastInput <= USER_SCROLL_WINDOW) revealScrollbar(event.target);
  }, { capture: true, passive: true });
}
