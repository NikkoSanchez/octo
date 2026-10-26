#!/usr/bin/python3
"""Offline skill discovery and explicit skill framing; no model or tools."""
import json, os, sys
def emit(value):
    print(json.dumps(value), flush=True)
for line in sys.stdin:
    request = json.loads(line)
    method, params = request.get('method'), request.get('params', {})
    if 'id' not in request: continue
    if method == 'initialize': result = {}
    elif method == 'skills/list':
        assert len(params['cwds']) == 1 and os.path.realpath(params['cwds'][0]) == os.path.realpath(os.getcwd())
        assert params['forceReload'] is True
        result = dict(data=[dict(cwd=os.getcwd(), errors=[], skills=[
            dict(name='fixture-review', description='Review fixture', enabled=True, path='/tmp/fixture/SKILL.md'),
            dict(name='disabled', description='Disabled', enabled=False, path='/tmp/disabled/SKILL.md')])])
    elif method in ('thread/start', 'thread/resume'): result = dict(thread=dict(id='skills-thread'))
    elif method in ('turn/start', 'turn/steer'):
        text = params['input'][0]['text']
        assert text in ('$fixture-review explain', '$fixture-review hold')
        assert params['input'] == [dict(type='text', text=text), dict(type='skill', name='fixture-review', path='/tmp/fixture/SKILL.md')]
        if method == 'turn/start':
            assert params['sandboxPolicy']['type'] == 'workspaceWrite'
            assert params['approvalPolicy'] == 'on-request'
            result = dict(turn=dict(id='skills-turn'))
        else:
            assert params['expectedTurnId'] == 'skills-turn'
            assert 'sandboxPolicy' not in params and 'approvalPolicy' not in params
            result = dict(turnId='skills-turn')
    else:
        emit(dict(id=request['id'], error=dict(code=-32601, message='Unsupported fixture method')))
        continue
    emit(dict(id=request['id'], result=result))
    if method in ('turn/start', 'turn/steer') and params['input'][0]['text'] != '$fixture-review hold':
        emit(dict(method='turn/completed', params=dict(threadId='skills-thread', turn=dict(id='skills-turn', status='completed'))))
