#!/usr/bin/env python3
"""Offline app-server usage/compaction fixture. Never connects to a model."""
import json
import sys
import time

if '--version' in sys.argv:
    print('codex-cli 0.158.0-alpha.2.1')
    sys.exit(0)


def emit(value):
    frame = json.dumps(value) + '\n'
    # Exercise framing as well as protocol routing.
    sys.stdout.write(frame[:13]); sys.stdout.flush()
    sys.stdout.write(frame[13:]); sys.stdout.flush()


def notify(method, params):
    emit(dict(method=method, params=params))


def counts(total):
    return dict(totalTokens=total, inputTokens=total - 2000, cachedInputTokens=1000,
                cacheWriteInputTokens=100, outputTokens=2000, reasoningOutputTokens=500)


turn = 0
thread = 'usage-fixture'
for line in sys.stdin:
    request = json.loads(line)
    method, p = request.get('method'), request.get('params', {})
    if method == 'initialize':
        emit(dict(id=request['id'], result={}))
    elif method == 'model/list':
        emit(dict(id=request['id'], result=dict(data=[], nextCursor=None)))
    elif method in ('thread/start', 'thread/resume'):
        assert p['approvalPolicy'] == 'on-request' and p['sandbox'] == 'workspace-write'
        thread = p.get('threadId', thread)
        emit(dict(id=request['id'], result=dict(thread=dict(id=thread))))
    elif method == 'turn/start':
        assert p['approvalPolicy'] == 'on-request'
        assert p['sandboxPolicy']['type'] == 'workspaceWrite'
        turn += 1
        prompt = p['input'][0]['text']
        owner = dict(threadId=thread, turnId=str(turn))
        emit(dict(id=request['id'], result=dict(turn=dict(id=str(turn)))))
        notify('turn/started', dict(threadId=thread, turn=dict(id=str(turn))))
        usage = dict(last=counts(184000), total=counts(820000), modelContextWindow=200000)
        notify('thread/tokenUsage/updated', dict(owner, tokenUsage=usage))
        notify('thread/tokenUsage/updated', dict(owner, tokenUsage=usage))
        notify('thread/tokenUsage/updated', dict(owner, tokenUsage=dict(last=dict(totalTokens=-1), total=counts(10))))
        notify('thread/tokenUsage/updated', dict(owner, tokenUsage=usage, ignored=True))
        wrong = dict(owner, threadId='other')
        notify('thread/tokenUsage/updated', dict(wrong, tokenUsage=dict(last=counts(99000), total=counts(999000))))
        wrong = dict(owner, turnId='stale')
        notify('thread/tokenUsage/updated', dict(wrong, tokenUsage=dict(last=counts(99000), total=counts(999000))))
        item = dict(id='compact-' + str(turn), type='contextCompaction')
        notify('item/started', dict(owner, item=item))
        notify('item/started', dict(owner, item=item))
        notify('item/completed', dict(wrong, item=item))
        if prompt == 'disconnect':
            sys.exit(1)
        if prompt == 'hold':
            continue
        if prompt == 'compact':
            time.sleep(5)
        notify('item/completed', dict(owner, item=item))
        notify('item/completed', dict(owner, item=item))
        notify('item/started', dict(owner, item=item))  # stale duplicate start
        notify('item/agentMessage/delta', dict(owner, itemId='reply', delta='Context compacted. This is an offline fixture.'))
        notify('turn/completed', dict(threadId=thread, turn=dict(id=str(turn), status='completed')))
        # Final accounting may arrive after the turn completes. Replace, never add.
        usage = dict(last=counts(32000), total=counts(854000), modelContextWindow=None if prompt == 'unknown' else 200000)
        notify('thread/tokenUsage/updated', dict(owner, tokenUsage=usage))
    elif method == 'turn/interrupt':
        emit(dict(id=request['id'], result={}))
        notify('turn/completed', dict(threadId=thread, turn=dict(id=str(turn), status='interrupted')))
    elif method == 'account/rateLimits/read':
        emit(dict(id=request['id'], result=dict(rateLimits=dict(primary=dict(usedPercent=25, windowDurationMins=300)))))
    elif method != 'initialized':
        raise AssertionError(method)
