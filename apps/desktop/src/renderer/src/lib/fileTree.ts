export interface FileNode { path: string; name: string; directory: boolean; children: FileNode[] }
export function fileTree(paths: string[]): FileNode[] {
  const root: FileNode[] = [];
  for (const path of paths) {
    const parts = path.split("/"); let nodes = root, prefix = "";
    for (let i = 0; i < parts.length; i++) {
      const name = parts[i], directory = i < parts.length-1; prefix += (prefix ? "/" : "") + name;
      let node = nodes.find((n) => n.name === name && n.directory === directory);
      if (!node) { node = { path: prefix, name, directory, children: [] }; nodes.push(node); }
      nodes = node.children;
    }
  }
  const sort = (nodes: FileNode[]) => { nodes.sort((a,b) => Number(b.directory)-Number(a.directory) || a.name.localeCompare(b.name, undefined, { numeric: true })); nodes.forEach((n) => sort(n.children)); };
  sort(root); return root;
}
