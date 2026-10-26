import { useCallback, useEffect, useLayoutEffect, useRef, useState } from "react";

/** Within this distance of the end, scrolling resumes following new output. */
const FOLLOW_DISTANCE = 32;
/** Input this recent makes a scroll the user's: wheels and momentum keep arriving after the finger lifts. */
const USER_SCROLL_WINDOW = 250;

/**
 * Owns follow intent independently of the document's height. While following, growth (streamed
 * text, images loading, a resized column) keeps the end in view; reading earlier output stays put.
 */
export function useTranscriptScroll(threadID: string, suspended: boolean, searching: boolean) {
  const scroller = useRef<HTMLDivElement>(null), content = useRef<HTMLDivElement>(null);
  const [following, setFollowingState] = useState(true);
  const followingRef = useRef(true), suspendedRef = useRef(suspended);
  const userInput = useRef(0), frame = useRef(0);
  suspendedRef.current = suspended || searching;

  const setFollowing = useCallback((value: boolean) => {
    followingRef.current = value;
    setFollowingState(value);
  }, []);
  const scrollToEnd = useCallback(() => {
    const node = scroller.current;
    if (node) node.scrollTop = node.scrollHeight;
  }, []);
  // Coalesced to one scroll per frame; never while the user's own scroll is in flight.
  const requestScroll = useCallback(() => {
    if (!followingRef.current || suspendedRef.current || frame.current) return;
    frame.current = requestAnimationFrame(() => {
      frame.current = 0;
      if (followingRef.current && !suspendedRef.current && performance.now() - userInput.current > USER_SCROLL_WINDOW) scrollToEnd();
    });
  }, [scrollToEnd]);

  useLayoutEffect(() => {
    setFollowing(true);
    scrollToEnd();
  }, [threadID, setFollowing, scrollToEnd]);
  useEffect(() => { if (searching) setFollowing(false); }, [searching, setFollowing]);
  useEffect(() => { if (!suspended) requestScroll(); }, [suspended, requestScroll]);

  useEffect(() => {
    const node = scroller.current, inner = content.current;
    if (!node || !inner) return;
    const input = () => { userInput.current = performance.now(); };
    const keys = (event: KeyboardEvent) => { if (["PageUp", "PageDown", "Home", "End", "ArrowUp", "ArrowDown", " "].includes(event.key)) input(); };
    const scrolled = () => {
      if (suspendedRef.current || performance.now() - userInput.current > USER_SCROLL_WINDOW) return;
      const distance = node.scrollHeight - node.clientHeight - node.scrollTop;
      const next = distance <= FOLLOW_DISTANCE;
      if (next !== followingRef.current) setFollowing(next);
    };
    const resized = new ResizeObserver(requestScroll);
    resized.observe(inner);
    resized.observe(node);
    node.addEventListener("wheel", input, { passive: true });
    node.addEventListener("touchmove", input, { passive: true });
    node.addEventListener("pointerdown", input);
    node.addEventListener("keydown", keys);
    node.addEventListener("scroll", scrolled, { passive: true });
    return () => {
      resized.disconnect();
      cancelAnimationFrame(frame.current); frame.current = 0;
      node.removeEventListener("wheel", input);
      node.removeEventListener("touchmove", input);
      node.removeEventListener("pointerdown", input);
      node.removeEventListener("keydown", keys);
      node.removeEventListener("scroll", scrolled);
    };
  }, [threadID, requestScroll, setFollowing]);

  const resume = useCallback(() => { setFollowing(true); userInput.current = 0; scrollToEnd(); }, [setFollowing, scrollToEnd]);
  return { scroller, content, following, resume };
}
