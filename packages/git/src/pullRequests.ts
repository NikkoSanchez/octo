import { findExecutable, ProcessFailure, runProcess, type ProcessResult } from "@octo/core/node";
import { GitService } from "./service";

import type { PullRequest } from "./model";

/**
 * GitHub pull requests through the user's installed and authenticated GitHub CLI (`gh`). No token is
 * stored; gh's own account, repository resolution and errors apply.
 */
export const PullRequests = {
  /** Prompts would wait on a terminal that isn't attached, so gh fails with its message instead. */
  environment: { GH_PROMPT_DISABLED: "1", GH_NO_UPDATE_NOTIFIER: "1", GH_SPINNER_DISABLED: "1", NO_COLOR: "1" },

  get isAvailable(): boolean { return findExecutable("gh") !== undefined; },

  async gh(args: string[], root: string): Promise<ProcessResult> {
    const executable = findExecutable("gh");
    if (!executable) throw new ProcessFailure("missing", "The GitHub CLI (gh)");
    return runProcess(executable, args, { directory: root, environment: PullRequests.environment, timeout: 120 });
  },

  /** The open pull request whose head is `branch`. `--head` keeps a numeric name from reading as a PR number. */
  async open(branch: string, root: string): Promise<PullRequest | undefined> {
    const result = await PullRequests.gh(["pr", "list", `--head=${branch}`, "--state=open", "--limit=1", "--json=number,url,title,isDraft,baseRefName"], root);
    if (result.status !== 0) throw new ProcessFailure("exited", GitService.message(result));
    const list = JSON.parse(result.output.toString("utf8")) as PullRequest[];
    return Array.isArray(list) ? list[0] : undefined;
  },

  /** Creates the pull request from an already pushed `head`. `--flag=value` keeps a "-" title from reading as an option. */
  async create(title: string, body: string, base: string, head: string, draft: boolean, root: string): Promise<PullRequest> {
    const args = ["pr", "create", `--title=${title}`, `--body=${body}`, `--base=${base}`, `--head=${head}`, ...(draft ? ["--draft"] : [])];
    const result = await PullRequests.gh(args, root);
    if (result.status !== 0) throw new ProcessFailure("exited", GitService.message(result));
    const output = result.output.toString("utf8");
    const url = output.split(/\r?\n/).filter((l) => l.startsWith("https://")).at(-1);
    const number = url ? PullRequests.number(url) : undefined;
    if (!url || number === undefined) throw new ProcessFailure("exited", "GitHub CLI did not report the new pull request's address.\n\n" + output);
    return { number, url, title, isDraft: draft, baseRefName: base };
  },

  number(url: string): number | undefined {
    const match = /\/pull\/(\d+)/.exec(url);
    return match ? Number(match[1]) : undefined;
  },
};
