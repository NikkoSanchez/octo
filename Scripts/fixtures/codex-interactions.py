#!/usr/bin/python3
"""Offline app-server fixture. No model, MCP, credentials, or computer control."""
import json
import os
import sys
import time

if '--version' in sys.argv:
    print('codex-cli 0.158.0-alpha.2.1')
    sys.exit(0)

def emit(obj):
    value = json.dumps(obj) + '\n'
    sys.stdout.write(value[:9]); sys.stdout.flush()
    sys.stdout.write(value[9:]); sys.stdout.flush()

def notify(method, params):
    emit({'method': method, 'params': params})

turn = 0
request_id = 0
scenario = ''
pending = False
for line in sys.stdin:
    obj = json.loads(line)
    method = obj.get('method')
    p = obj.get('params', {})
    if method == 'initialize':
        if 'capabilities' in p:
            assert p['capabilities']['experimentalApi'] is True
            assert p['capabilities']['mcpServerOpenaiFormElicitation'] is True
        emit({'id': obj['id'], 'result': {'userAgent': 'fixture', 'codexHome': '/fixture', 'platformOs': 'macos', 'platformFamily': 'unix'}})
    elif method == 'model/list':
        emit({'id': obj['id'], 'result': {'data': [], 'nextCursor': None}})
    elif method in ('thread/start', 'thread/resume'):
        assert os.path.realpath(os.getcwd()) == os.path.realpath(p['cwd'])
        assert 'HOME' in os.environ
        assert sys.argv[1:] == ['app-server']
        assert p['approvalPolicy'] == 'on-request'
        assert p['approvalsReviewer'] == 'user'
        assert p['sandbox'] == 'workspace-write'
        emit({'id': obj['id'], 'result': {'thread': {'id': 'fixture-thread'}}})
    elif method == 'turn/start':
        turn += 1
        request_id = 100 + turn
        scenario = p['input'][0]['text']
        assert os.path.realpath(os.getcwd()) == os.path.realpath(p['cwd'])
        assert 'HOME' in os.environ
        assert sys.argv[1:] == ['app-server']
        assert p['approvalPolicy'] == 'on-request'
        assert p['approvalsReviewer'] == 'user'
        assert p['sandboxPolicy']['type'] == 'workspaceWrite'
        context = {'threadId': 'fixture-thread', 'turnId': str(turn)}
        emit({'id': obj['id'], 'result': {'turn': {'id': str(turn)}}})
        notify('turn/started', {'threadId': 'fixture-thread', 'turn': {'id': str(turn)}})
        item = {'id': 'tool-1', 'type': 'mcpToolCall', 'server': 'computer-use-fixture', 'tool': 'request_app_access', 'status': 'inProgress', 'arguments': {'secret': 'MUST-NOT-RENDER'}}
        notify('item/started', dict(context, item=item))
        notify('item/started', dict(context, item=item))
        notify('item/mcpToolCall/progress', dict(context, itemId='tool-1', message='Waiting for app authorization'))
        notify('item/mcpToolCall/progress', dict(context, itemId='tool-1', message='Waiting for app authorization'))
        request = dict(context, serverName='computer-use-fixture', mode='form', message='Allow the fixture to use Safari? This is a simulated request.', _meta={'app_name': 'Safari', 'persist': ['session', 'always']}, requestedSchema={'type': 'object', 'properties': {'approval': {'type': 'string', 'oneOf': [{'const': 'once', 'title': 'Allow once'}, {'const': 'session', 'title': 'Allow for this session'}, {'const': 'always', 'title': 'Always allow Safari'}]}}, 'required': ['approval']})
        if scenario.startswith('metadata-'):
            request['_meta'] = {'codex_approval_kind': 'mcp_tool_call', 'connector_id': 'computer-use', 'tool_name': 'get_app_state', 'tool_params': {'app': 'com.apple.Safari'}, 'tool_params_display': [{'name': 'app', 'value': 'Safari'}], 'persist': ['session', 'always']}
            request['requestedSchema'] = {'type': 'object', 'properties': {}}
        request_method = 'mcpServer/elicitation/request'
        if scenario == 'unsupported':
            request['requestedSchema']['properties']['approval']['pattern'] = '.*'
        if scenario == 'questions':
            request_method = 'item/tool/requestUserInput'
            request = dict(context, itemId='question-tool', isBlocking=True, questions=[{'id': 'choice', 'header': 'Direction', 'question': 'Choose a direction.', 'isOther': True, 'options': [{'label': 'North', 'description': 'Go north.'}, {'label': 'South', 'description': 'Go south.'}]}])
        if scenario == 'wrong-thread': request['threadId'] = 'another-thread'
        if scenario == 'wrong-turn': request['turnId'] = 'stale-turn'
        emit({'id': request_id, 'method': request_method, 'params': request})
        if scenario == 'resolved':
            notify('serverRequest/resolved', {'threadId': 'fixture-thread', 'requestId': request_id})
            notify('item/agentMessage/delta', dict(context, itemId='resolved-marker', delta='Resolved'))
        elif scenario == 'disconnect':
            sys.exit(0)
        else:
            emit({'id': request_id, 'method': request_method, 'params': request})  # duplicate frame
        pending = True
    elif method == 'turn/interrupt':
        emit({'id': obj['id'], 'result': {}})
        notify('turn/completed', {'threadId': 'fixture-thread', 'turn': {'id': str(turn), 'status': 'interrupted'}})
        pending = False
    elif method is None and obj.get('id') == request_id:
        assert pending, 'duplicate or stale response'
        pending = False
        if scenario == 'resolved': raise AssertionError('response after provider resolution')
        result = obj.get('result', obj.get('error'))
        notify('item/agentMessage/delta', dict(context, itemId='answer', delta=json.dumps(result, sort_keys=True)))
        item['status'] = 'failed' if scenario == 'tool-failure' else 'completed'
        if scenario == 'tool-failure': item['error'] = {'message': 'Fixture transport unavailable'}
        item['result'] = {'content': [{'type': 'text', 'text': 'Fixture decision received.'}, {'type': 'image', 'data': 'DO-NOT-RENDER'}], 'structuredContent': {'status': 'ok', 'access_token': 'DO-NOT-RENDER'}}
        notify('item/completed', dict(context, item=item))
        notify('item/completed', dict(context, item=item))
        notify('item/mcpToolCall/progress', dict(context, itemId='tool-1', message='stale progress'))
        notify('turn/completed', {'threadId': 'fixture-thread', 'turn': {'id': str(turn), 'status': 'completed'}})
    elif method not in ('initialized', None):
        emit({'id': obj['id'], 'error': {'code': -32601, 'message': 'Fixture does not implement ' + method}})
