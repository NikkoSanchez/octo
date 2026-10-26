export type BrowserAppearance = "system" | "light" | "dark";
export type BrowserDevice = "phone" | "tablet" | "laptop";

export const BROWSER_DEVICES: Record<BrowserDevice, { title: string; width: number; height: number }> = {
  phone: { title: "Phone", width: 390, height: 844 },
  tablet: { title: "Tablet", width: 820, height: 1180 },
  laptop: { title: "Laptop", width: 1280, height: 800 },
};

export const ZOOM_LEVELS = [0.5, 0.67, 0.75, 0.8, 0.9, 1, 1.1, 1.25, 1.5, 1.75, 2, 2.5, 3];

export interface BrowserState {
  id: string;
  projectID: string;
  address: string;
  title: string;
  url?: string;
  canGoBack: boolean;
  canGoForward: boolean;
  loading: boolean;
  annotating: boolean;
  zoom: number;
  appearance: BrowserAppearance;
  device?: BrowserDevice;
  landscape: boolean;
  detached: boolean;
  isPrivate: boolean;
  /** A restored tab shows its address and loads when first shown. */
  restoring: boolean;
  error?: string;
  /** A page asked to open a link in another app; the user confirms first. */
  pendingExternal?: { url: string; application: string };
}

/** Main → renderer browser events, tagged with their tab. */
export type BrowserEvent =
  | { type: "state"; state: BrowserState }
  | { type: "closed"; id: string }
  | { type: "focusAddress"; id: string };

export interface BrowserBounds { x: number; y: number; width: number; height: number }

/** Viewport presets emulate width and height for responsive CSS, not touch input or a mobile user agent. */
export function browserViewport(device: BrowserDevice | undefined, landscape: boolean): { width: number; height: number } | undefined {
  if (!device) return undefined;
  const { width, height } = BROWSER_DEVICES[device];
  return landscape ? { width: height, height: width } : { width, height };
}

/** The page lays out `frame / zoom` CSS pixels wide, so shrinking both by the same factor keeps the viewport exact. */
export function fitScale(viewport: { width: number; height: number }, available: { width: number; height: number }): number {
  if (viewport.width <= 0 || viewport.height <= 0) return 1;
  return Math.max(0.1, Math.min(1, available.width / viewport.width, available.height / viewport.height));
}

/** Accepts full http(s) URLs, bare hosts, `localhost:3000`-style dev servers, or a search. */
export function browserURL(input: string): string | undefined {
  const text = input.trim();
  if (!text) return undefined;
  try {
    const url = new URL(text);
    if ((url.protocol === "http:" || url.protocol === "https:") && url.host) return url.href;
  } catch { /* not absolute */ }
  if (!text.includes(" ")) {
    const local = /^(localhost|127\.0\.0\.1|\[::1\]|[\w-]+\.local|\d{1,3}(\.\d{1,3}){3})(:\d+)?([/?#].*)?$/.test(text);
    if (local || /^[\w.-]+:\d+([/?#].*)?$/.test(text)) { try { return new URL("http://" + text).href; } catch { /* fall through */ } }
    if (/^[\w-]+(\.[\w-]+)+([/?#:].*)?$/.test(text)) { try { const url = new URL("https://" + text); if (url.host) return url.href; } catch { /* fall through */ } }
  }
  const search = new URL("https://www.google.com/search");
  search.searchParams.set("q", text);
  return search.href;
}
