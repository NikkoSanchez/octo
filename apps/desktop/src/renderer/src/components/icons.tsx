/** The conventional Git branch glyph (trunk, two commits, a fork curve). SF Symbols and Lucide's differ. */
export function GitBranchIcon({ size = 15 }: { size?: number }) {
  return (
    <svg width={size} height={size} viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth={2} strokeLinecap="round" strokeLinejoin="round" aria-hidden="true" style={{ flex: "none" }}>
      <path d="M6 3v12" />
      <circle cx="6" cy="18" r="3" />
      <circle cx="18" cy="6" r="3" />
      <path d="M18 9a9 9 0 0 1-9 9" />
    </svg>
  );
}

/** Outline folder artwork with an angled front flap when the project is expanded. */
export function ProjectFolderIcon({ open, size = 18 }: { open: boolean; size?: number }) {
  const path = open
    ? "M3 19V6Q3 4 5 4H9L12 7H19Q21 7 21 9V11M3 19L7 11H23L19 20H5Q3 20 3 19Z"
    : "M3 19V6Q3 4 5 4H9L12 7H19Q21 7 21 9V18Q21 20 19 20H5Q3 20 3 19Z";
  return (
    <svg width={size} height={size} viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth={1.4} strokeLinecap="round" strokeLinejoin="round" aria-hidden="true" style={{ flex: "none" }}>
      <path d={path} />
    </svg>
  );
}

/** SF Symbols' plus.forwardslash.minus, the Changes glyph. */
export function ChangesIcon({ size = 12 }: { size?: number }) {
  return (
    <svg width={size} height={size} viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth={2} strokeLinecap="round" aria-hidden="true" style={{ flex: "none" }}>
      <path d="M3 7h7M6.5 3.5v7M15 20h6M19 4 5 20" />
    </svg>
  );
}
