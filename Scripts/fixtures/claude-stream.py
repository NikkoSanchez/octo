#!/usr/bin/python3
"""Offline Claude SDK protocol stand-in. Never calls a model or executes tools."""
import json, sys, time, base64, os

def emit(obj):
    raw = json.dumps(obj, ensure_ascii=False) + '\n'
    sys.stdout.write(raw[:9]); sys.stdout.flush(); time.sleep(.001)
    sys.stdout.write(raw[9:]); sys.stdout.flush()

def request(id, name, input):
    emit(dict(type='control_request', request_id=id, request=dict(subtype='can_use_tool', tool_name=name, input=input)))

assert '--input-format' in sys.argv and '--permission-prompt-tool' in sys.argv
permission_mode = sys.argv[sys.argv.index('--permission-mode') + 1]
assert permission_mode in ('manual', 'auto')
assert not any('bypass' in a or 'skip-permissions' in a for a in sys.argv)
config = {}
if os.path.isfile('.claude-fixture-permissions.json'):
    with open('.claude-fixture-permissions.json') as file: config = json.load(file)
reported_mode = config.get('reported_mode', 'default' if permission_mode == 'manual' else 'auto')
def trace(obj):
    if config:
        with open('.claude-fixture-trace.jsonl', 'a') as file: file.write(json.dumps(obj) + '\n')
trace(dict(argv=sys.argv[1:]))
models = [dict(value='default', displayName='Default', supportsEffort=True, supportedEffortLevels=['low','high']),
          dict(value='sonnet', displayName='Sonnet', supportsEffort=True, supportedEffortLevels=['low','high']),
          dict(value='haiku', displayName='Haiku')]
mode = None
for line in sys.stdin:
    obj = json.loads(line)
    trace(obj)
    if obj['type'] == 'control_request':
        emit(dict(type='control_response', response=dict(subtype='success', request_id=obj['request_id'], response=dict(models=models, commands=[dict(name='fixture-review', description='Review fixture files', argumentHint='[path]')], current_permission_mode=reported_mode))))
        continue
    if obj['type'] == 'user':
        content = obj['message']['content']
        mode = next((b['text'] for b in content if b['type'] == 'text'), 'image')
        if any(b['type'] == 'image' for b in content):
            assert base64.b64decode(content[-1]['source']['data']) == b'fixture-image'
        emit(dict(type='system', subtype='init', session_id='fixture-session', permissionMode=config.get('runtime_mode', reported_mode)))
        if mode == 'permissions':
            emit(dict(type='result', session_id='fixture-session', is_error=False))
            continue
        if mode == 'ratelimit':
            # Claude Code 2.1.302 rate_limit_event; the other session's event must be ignored.
            emit(dict(type='rate_limit_event', session_id='wrong-session', uuid='x', rate_limit_info=dict(status='rejected', rateLimitType='five_hour', utilization=1)))
            emit(dict(type='rate_limit_event', session_id='fixture-session', uuid='a', rate_limit_info=dict(status='allowed_warning', rateLimitType='seven_day', utilization=0.82, resetsAt=1800000000)))
            emit(dict(type='rate_limit_event', session_id='fixture-session', uuid='b', rate_limit_info=dict(status='allowed', unifiedWindows=dict(five_hour=dict(utilization=0.25, resetsAt=1790000000)))))
            emit(dict(type='rate_limit_event', session_id='fixture-session', uuid='c', rate_limit_info=dict(status='allowed')))
            emit(dict(type='result', session_id='fixture-session', is_error=False))
            continue
        if mode == 'disconnect': sys.exit(0)
        if mode == 'error':
            emit(dict(type='result', session_id='fixture-session', is_error=True, errors=['fixture error']))
            continue
        if mode == 'cancel-start': time.sleep(5); continue
        if mode == 'hold':
            request('approval', 'Bash', dict(command='echo fixture'))
            continue
        if mode == 'cancel-request':
            request('approval', 'Bash', dict(command='echo fixture'))
            emit(dict(type='control_cancel_request', request_id='approval'))
            continue
        if mode == 'question':
            request('question', 'AskUserQuestion', dict(questions=[dict(question='Which option?', options=[dict(label='A'), dict(label='B')], multiSelect=False)]))
            continue
        if mode == 'unsupported':
            request('unsupported', 'AskUserQuestion', dict(questions=[dict(question='Which options?', options=[dict(label='A'), dict(label='B')], multiSelect=True)]))
            continue
        # Ignore unrelated session and child-agent text, and suppress completed duplicates.
        emit(dict(type='stream_event', session_id='wrong-session', event=dict(type='content_block_delta', index=0, delta=dict(type='text_delta',text='Wrong'))))
        emit(dict(type='assistant', session_id='fixture-session', parent_tool_use_id='child', message=dict(id='child', content=[dict(type='text',text='Child')])) )
        for index, text in enumerate(['Hello 🐙', ' again']):
            emit(dict(type='stream_event', session_id='fixture-session', event=dict(type='message_start')))
            emit(dict(type='stream_event', session_id='fixture-session', event=dict(type='content_block_delta', index=0, delta=dict(type='text_delta',text=text))))
            msg = dict(type='assistant', session_id='fixture-session', message=dict(id=str(index), content=[dict(type='text',text=text)]))
            emit(msg); emit(msg)
        emit(dict(type='assistant', session_id='fixture-session', message=dict(id='buffered',content=[dict(type='text',text=' fallback'),dict(type='tool_use',id='tool-1',name='Read',input=dict(file_path='secret'))])))
        emit(dict(type='user',session_id='fixture-session',message=dict(content=[dict(type='tool_result',tool_use_id='tool-1',content='token=secret-value',is_error=False)])))
        request('approval', 'Bash', dict(command='echo fixture'))
    elif obj['type'] == 'control_response':
        response = obj['response']['response']; id = obj['response']['request_id']
        if id == 'question': assert response['updatedInput']['answers'] == {'Which option?':'B'}
        elif id == 'unsupported': assert response['behavior'] == 'deny'
        elif id == 'approval':
            assert 'updatedPermissions' not in response
            if response['behavior'] == 'allow': assert response['updatedInput'] == dict(command='echo fixture')
        emit(dict(type='result', session_id='fixture-session', is_error=False))
