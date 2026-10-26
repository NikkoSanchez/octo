// Runtime allowlists for the bridge. Each service exposes only these actions.
export const SERVICE_ACTIONS = {
  app: ["info", "snapshot", "openExternal", "revealInFinder", "copyText", "readText", "openTarget", "openTargets", "systemTheme", "usageRecords", "setMenu", "confirm", "popupMenu"],
  store: [
    "dismissError", "openChats", "newChat", "chooseProject", "addProject", "selectProject", "selectThread", "markThreadRead", "newThread",
    "toggleProjectPin", "toggleProjectCollapse", "toggleProjectsSection", "toggleRecentSection", "toggleThreadPin", "renameProject",
    "renameThread", "deleteThread", "removeProject", "changeHarness", "loadModels", "loadCommands", "selectModel", "selectAgent",
    "selectReasoning", "selectPermissions", "selectCommitMessageModel", "loadCommitMessageModels", "loadUsage", "setDraftReady",
    "pasteImage", "chooseImages", "importImages", "removeDraftImage", "removeDraftCode", "removeDraftAnnotation", "attach", "send",
    "removeQueued", "resumeQueue", "steerQueued", "stop", "answer", "respond", "chooseCodexExecutable", "setCodexExecutable",
    "refreshCodexVersion", "refreshClaudeAuth", "claudeSetupClosed", "setTheme", "setOpenTarget", "refreshDescriptors",
    "updatePanelTabsAction", "automaticCommitModels", "openTerminal",
  ],
  review: [
    "refresh", "snapshot", "snapshots", "fileSnapshot", "filePaths", "stage", "unstage", "discard", "applyHunk", "commit", "push", "pull",
    "fetch", "switchBranch", "stashes", "stash", "applyStash", "dropStash", "upstreamStatus", "remoteBranches", "commitSubjects",
    "openPullRequest", "createPullRequest", "pullRequestsAvailable", "stagedChanges", "generateCommitMessage", "watch",
    "openFile", "setFileDraft", "saveFile", "fileChanged", "closeFile", "reloadFile", "createFile", "deleteFile", "inspectFile", "branches", "cancelCommitMessage",
  ],
  terminal: [
    "ensureTab", "newTab", "closeTab", "select", "cycle", "rename", "split", "closePane", "focusPane", "focusDirection", "toggleZoom",
    "equalize", "setRatio", "resizePane", "write", "resize", "ack", "snapshot", "openInEditor", "openDirectoryInEditor",
    "openCLISetup", "closeSetup", "ghosttyConfig",
  ],
  browser: [
    "create", "close", "setBounds", "setVisible", "hideAll", "focus", "navigate", "back", "forward", "reload", "hardReload", "stop",
    "openExternally", "openDevTools", "annotate", "screenshot", "setZoom", "setDevice", "setAppearance", "openSeparateWindow",
    "returnToPanel", "confirmExternal", "clearCookies", "clearCache",
  ],
} as const;

export const EVENT_CHANNELS = ["state:patches", "ui:event", "review:event", "terminal:event", "browser:event"] as const;
