import type { AgentCommand } from "@octo/agents/model";
export function slashToken(text: string, caret: number) {
  caret = Math.max(0, Math.min(caret, text.length));
  let start = caret, end = caret;
  while (start > 0 && !/\s/.test(text[start - 1])) start--;
  while (end < text.length && !/\s/.test(text[end])) end++;
  const word = text.slice(start, end);
  return caret > start && word.startsWith("/") && !word.slice(1).includes("/") ? { start, end, query: word.slice(1) } : undefined;
}
export function insertCommand(text: string, token: NonNullable<ReturnType<typeof slashToken>>, command: AgentCommand) {
  const name = `/${command.name}`;
  const trailing = token.end < text.length && /\s/.test(text[token.end]) ? "" : " ";
  return { text: text.slice(0, token.start) + name + trailing + text.slice(token.end), caret: token.start + name.length + 1 };
}
