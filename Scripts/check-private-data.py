#!/usr/bin/env python3
"""Check repository blobs without printing secrets. Not a general-purpose secret scanner."""
import argparse
import json
import pathlib
import re
import subprocess
import sys

PATTERNS = {
    "private key": rb"-----BEGIN (?:RSA |EC |OPENSSH |DSA )?PRIVATE KEY-----",
    "GitHub token": rb"(?:gh[pousr]_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,})",
    "provider API key": rb"sk-(?:proj-|ant-)?[A-Za-z0-9_-]{20,}",
    "AWS access key": rb"(?:AKIA|ASIA)[A-Z0-9]{16}",
    "Slack token": rb"xox[baprs]-[A-Za-z0-9-]{15,}",
    "URL credentials": rb"https?://[^/\s:@]+:[^/\s@]+@",
    "personal home path": rb"/Users/[A-Za-z0-9_.-]+/",
}

def findings(name, data):
    path = pathlib.PurePosixPath(name)
    issues = []
    if (path.name == '.env' or path.name.startswith('.env.')) and path.name not in ('.env.example', '.env.sample'):
        issues.append('environment file')
    if path.suffix.lower() in ('.pem', '.key', '.p12', '.pfx', '.mobileprovision', '.log'):
        issues.append('credential, signing, or log file')
    if any(part in ('.build', 'build', 'xcuserdata') for part in path.parts):
        issues.append('local build or user data')
    for label, pattern in PATTERNS.items():
        if re.search(pattern, data):
            issues.append(label)
    try:
        obj = json.loads(data)
        if isinstance(obj, dict) and 'schemaVersion' in obj and isinstance(obj.get('projects'), list):
            issues.append('Octo conversation archive (regardless of filename)')
    except (ValueError, UnicodeError):
        pass
    return issues

def git(*args):
    return subprocess.check_output(['git', *args])

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--pre-push', action='store_true', help='Inspect every commit reachable from pushed refs, from Git hook stdin')
    parser.add_argument('--commit', help='Inspect one exact commit tree')
    parser.add_argument('--worktree', action='store_true', help='Inspect tracked and non-ignored files before staging')
    args = parser.parse_args()
    root = pathlib.Path(git('rev-parse', '--show-toplevel').decode().strip())
    rejected, count = [], 0
    if args.pre_push or args.commit:
        commits = set()
        if args.pre_push:
            for line in sys.stdin:
                fields = line.split()
                if len(fields) != 4 or not re.fullmatch(r'[0-9a-f]{40,64}', fields[1]):
                    raise SystemExit('Invalid pre-push input')
                if set(fields[1]) == {'0'}:
                    continue
                commits.update(git('rev-list', fields[1], '--').decode().splitlines())
        else:
            commits.add(git('rev-parse', '--verify', '--end-of-options', args.commit + '^{commit}').decode().strip())
        entries = set()
        for commit in sorted(commits):
            for record in git('ls-tree', '-r', '-z', commit).split(b'\0'):
                if not record:
                    continue
                metadata, name = record.split(b'\t', 1)
                mode, kind, oid = metadata.split()
                if kind != b'blob' or mode == b'120000':
                    rejected.append((name.decode(), ['submodule or symlink requires manual review']))
                    continue
                entries.add((name.decode(), oid.decode()))
        entries = sorted(entries)
    elif args.worktree:
        names = sorted(set(git('ls-files', '--cached', '--others', '--exclude-standard', '-z').split(b'\0')) - {b''})
        entries = [(name.decode(), None) for name in names]
    else:
        entries = []
        for record in git('ls-files', '--stage', '-z').split(b'\0'):
            if not record:
                continue
            metadata, name = record.split(b'\t', 1)
            mode, oid, stage = metadata.split()
            if mode in (b'160000', b'120000'):
                rejected.append((name.decode(), ['submodule or symlink requires manual review']))
                continue
            entries.append((name.decode(), oid.decode()))
    for name, oid in entries:
        count += 1
        if oid:
            data = git('cat-file', 'blob', oid)
        else:
            path = root / name
            if not path.exists() and not path.is_symlink():
                continue
            if path.is_symlink():
                rejected.append((name, ['symlink requires manual review']))
                continue
            data = path.read_bytes()
        issues = findings(name, data)
        if issues:
            rejected.append((name, issues))
    for name, issues in rejected:
        print(f'BLOCKED {name!r}: {", ".join(issues)}', file=sys.stderr)
    print(f'Privacy check: {count} files, {len(rejected)} blocked. Values are never printed.')
    if not count:
        print('No staged files to inspect. Use --worktree before staging.')
    return bool(rejected)

if __name__ == '__main__':
    sys.exit(main())
