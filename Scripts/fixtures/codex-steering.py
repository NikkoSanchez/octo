#!/usr/bin/python3
"""Offline queue/steering and Computer Use lifecycle fixture; never calls a model or MCP."""
import json
import os
import sys

if '--version' in sys.argv:
    print('codex-cli 0.160.0')
    sys.exit(0)
if 'exec' in sys.argv:
    sys.exit(1)  # Keep native-smoke title generation offline, using the fallback.

turn_number = 0
active = None
last_turn = None
prompt = ''

def emit(value):
    print(json.dumps(value), flush=True)

def reply(obj, result):
    emit({'id': obj['id'], 'result': result})

def notify(method, params):
    emit({'method': method, 'params': params})

def finish(status='completed'):
    global active
    notify('item/completed', {'threadId': 'fixture', 'turnId': active,
                             'item': {'id': 'answer-' + active, 'type': 'agentMessage', 'text': 'Fixture response complete.'}})
    notify('turn/completed', {'threadId': 'fixture', 'turn': {'id': active, 'status': status}})
    active = None

for line in sys.stdin:
    obj = json.loads(line)
    method, p = obj.get('method'), obj.get('params', {})
    with open('fixture-rpc.jsonl', 'a') as log:
        log.write(json.dumps(obj) + '\n')
    if method == 'initialize':
        reply(obj, {})
    elif method == 'model/list':
        reply(obj, {'data': [], 'nextCursor': None})
    elif method in ('thread/start', 'thread/resume'):
        assert p['sandbox'] == 'workspace-write' and p['approvalPolicy'] == 'on-request'
        reply(obj, {'thread': {'id': 'fixture'}})
    elif method == 'turn/start':
        assert active is None
        assert p['sandboxPolicy']['type'] == 'workspaceWrite' and p['approvalPolicy'] == 'on-request'
        turn_number += 1
        active = last_turn = 'turn-' + str(turn_number)
        prompt = next((x['text'] for x in p['input'] if x['type'] == 'text'), '')
        reply(obj, {'turn': {'id': active}})
        notify('turn/started', {'threadId': 'fixture', 'turn': {'id': active}})
        if prompt != 'no tool':
            notify('item/started', {'threadId': 'fixture', 'turnId': active,
                                   'item': {'id': 'computer-' + active, 'type': 'mcpToolCall', 'server': 'cua_repl', 'tool': 'js', 'status': 'inProgress'}})
        if prompt == 'wait':
            emit({'id': 'question-' + active, 'method': 'item/tool/requestUserInput', 'params': {
                'threadId': 'fixture', 'turnId': active, 'itemId': 'question-item', 'isBlocking': True,
                'questions': [{'id': 'direction', 'header': 'Direction', 'question': 'Which direction should the fixture take?',
                               'isOther': True, 'options': [{'label': 'Continue', 'description': 'Complete the fixture turn.'}]}]}})
        elif prompt != 'hold':
            finish()
    elif method == 'turn/steer':
        assert p['threadId'] == 'fixture' and p['expectedTurnId'] == active
        assert set(p) == {'threadId', 'expectedTurnId', 'input'}
        text = next((x['text'] for x in p['input'] if x['type'] == 'text'), '')
        if text == 'reject':
            emit({'id': obj['id'], 'error': {'code': -32600, 'message': 'Fixture rejects steering'}})
        elif text == 'finish before ack':
            accepted = active
            finish()
            reply(obj, {'turnId': accepted})
        else:
            reply(obj, {'turnId': active})
            if text == 'finish':
                finish()
    elif method == 'turn/interrupt':
        reply(obj, {})
        if active is not None:
            finish('interrupted')
    elif method == 'mcpServer/tool/call':
        assert p['threadId'] == 'fixture' and p['server'] == 'cua_repl' and p['tool'] == 'turn_ended'
        assert p['arguments']['session_id'] == 'fixture' and p['arguments']['turn_id'] == last_turn
        assert p['arguments']['hook_event_name'] in ('Stop', 'Interrupt')
        reply(obj, {'content': [], 'isError': prompt == 'cleanup error'})
    elif method is None and str(obj.get('id', '')).startswith('question-'):
        if active is not None:
            finish()
    elif method not in ('initialized', None):
        raise AssertionError('Unexpected request: ' + str(method))
