/** "/name" words at the start of the prompt or after whitespace, as the composer offers them. */
const COMMAND_MENTION = /(?:^|(?<=\s))\/([A-Za-z0-9][A-Za-z0-9._:\-]*)(?=\s|$)/g;

export function commandMentions(prompt: string): { index: number; length: number; name: string }[] {
  return [...prompt.matchAll(COMMAND_MENTION)].map((m) => ({ index: m.index!, length: m[0].length, name: m[1] }));
}

/** Read-only CLI status. Credentials stay inside the installed CLI and its Keychain/config. */
export interface ClaudeAuthStatus {
  loggedIn: boolean;
  method: string;
}

export function authStatusTitle(status: ClaudeAuthStatus): string {
  return status.loggedIn ? `Signed in · ${status.method}` : "Signed out";
}
