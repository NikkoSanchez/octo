#!/usr/bin/python3
"""Offline two-chat UI stress fixture. Each process streams for 45 seconds; Stop works.
No model, credentials, network, or repository writes. Use the same fixture for two chats.
"""
import json
import sys
import threading
import time
import uuid

if '--version' in sys.argv:
    print('codex-cli 0.158.0-alpha.2.1')
    sys.exit(0)
lock = threading.Lock()
cancel = threading.Event()
thread_id = str(uuid.uuid4())
turn_id = 0


def emit(value):
    with lock:
        print(json.dumps(value), flush=True)


def stream(owner, stopped):
    for index in range(2250):
        if stopped.wait(.02):
            return
        delta = ('\n\n### Progress %d\n\n' % index if index % 100 == 0 else 'Streaming text with `code` and **emphasis**. ')
        emit(dict(method='item/agentMessage/delta', params=dict(owner, itemId='reply', delta=delta)))
    emit(dict(method='turn/completed', params=dict(threadId=owner['threadId'], turn=dict(id=owner['turnId'], status='completed'))))


for line in sys.stdin:
    request = json.loads(line)
    method, p = request.get('method'), request.get('params', {})
    if method == 'initialize':
        emit(dict(id=request['id'], result={}))
    elif method == 'model/list':
        emit(dict(id=request['id'], result=dict(data=[], nextCursor=None)))
    elif method in ('thread/start', 'thread/resume'):
        assert p['approvalPolicy'] == 'on-request' and p['sandbox'] == 'workspace-write'
        thread_id = p.get('threadId', thread_id)
        emit(dict(id=request['id'], result=dict(thread=dict(id=thread_id))))
    elif method == 'turn/start':
        assert p['approvalPolicy'] == 'on-request' and p['sandboxPolicy']['type'] == 'workspaceWrite'
        cancel.set(); cancel = threading.Event(); turn_id += 1
        owner = dict(threadId=thread_id, turnId=str(turn_id))
        emit(dict(id=request['id'], result=dict(turn=dict(id=str(turn_id)))))
        emit(dict(method='turn/started', params=dict(threadId=thread_id, turn=dict(id=str(turn_id)))))
        threading.Thread(target=stream, args=(owner, cancel), daemon=True).start()
    elif method == 'turn/interrupt':
        cancel.set()
        emit(dict(id=request['id'], result={}))
        emit(dict(method='turn/completed', params=dict(threadId=thread_id, turn=dict(id=str(turn_id), status='interrupted'))))
    elif method not in ('initialized', None):
        emit(dict(id=request['id'], error=dict(code=-32601, message='Offline fixture: unsupported method')))
