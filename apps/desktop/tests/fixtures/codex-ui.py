#!/usr/bin/python3
"""Offline Electron UI fixture. No models, credentials, network or repository changes."""
import json, sys, threading, time, uuid
if '--version' in sys.argv:
    print('codex-cli 0.160.0'); sys.exit(0)
if 'exec' in sys.argv:
    assert sys.argv[sys.argv.index('--sandbox')+1] == 'read-only'
    schema=json.load(open(sys.argv[sys.argv.index('--output-schema')+1]))
    if 'subject' in schema.get('properties', {}):
        with open(sys.argv[sys.argv.index('--output-last-message')+1], 'w') as out:
            json.dump(dict(subject='Update the fixture greeting', body=''), out)
        sys.exit(0)
    sys.exit(1)
owner = str(uuid.uuid4())
turn = 0
active = None
lock = threading.Lock()
def emit(value):
    with lock:
        print(json.dumps(value), flush=True)
def notify(method, **params):
    emit(dict(method=method, params=params))
def finish(text='Fixture response complete.'):
    global active
    if not active: return
    notify('item/agentMessage/delta', threadId=owner, turnId=active, itemId='answer-'+active, delta=text)
    notify('turn/completed', threadId=owner, turn=dict(id=active, status='completed'))
    active = None
for line in sys.stdin:
    obj=json.loads(line); method=obj.get('method'); p=obj.get('params', {})
    if method == 'initialize': emit(dict(id=obj['id'], result={}))
    elif method == 'model/list': emit(dict(id=obj['id'], result=dict(data=[], nextCursor=None)))
    elif method == 'skills/list': emit(dict(id=obj['id'], result=dict(data=[dict(cwd=p['cwds'][0], errors=[], skills=[dict(name='fixture-review', description='Review with an offline fixture', enabled=True, path='/tmp/fixture/SKILL.md')])])))
    elif method in ('thread/start', 'thread/resume'):
        assert p['sandbox'] == 'workspace-write' and p['approvalPolicy'] == 'on-request'
        owner=p.get('threadId', owner); emit(dict(id=obj['id'], result=dict(thread=dict(id=owner))))
    elif method == 'turn/start':
        assert p['sandboxPolicy']['type'] == 'workspaceWrite' and p['approvalPolicy'] == 'on-request'
        turn+=1; active=str(turn)
        emit(dict(id=obj['id'], result=dict(turn=dict(id=active))))
        notify('turn/started', threadId=owner, turn=dict(id=active))
        text=next((i['text'] for i in p['input'] if i['type']=='text'), '')
        if text in ('hold', 'long'):
            notify('item/agentMessage/delta', threadId=owner, turnId=active, itemId='answer-'+active, delta=('Waiting for your next action.' if text == 'hold' else '\n'.join('Reading line %d' % i for i in range(300))))
        elif text == 'work':
            # Reasoning, two commands and a Markdown reply, for the transcript's work rows.
            notify('item/reasoning/summaryTextDelta', threadId=owner, turnId=active, itemId='reason-'+active, delta='Checking the fixture greeting.')
            for index, command in enumerate(('cat example.ts', 'git diff --stat')):
                notify('item/started', threadId=owner, turnId=active, item=dict(id='command-%s-%d' % (active, index), type='commandExecution', command=command, status='inProgress'))
            finish('The greeting is **correct**:\n\n- It says `hello`\n- The file is staged nowhere yet\n\n```ts\nconst greeting = "hello";\n```')
        elif text == 'question':
            emit(dict(id='question-'+active, method='item/tool/requestUserInput', params=dict(threadId=owner, turnId=active, itemId='question', questions=[dict(id='direction', header='Direction', question='Which direction?', isOther=True, options=[dict(label='North', description='Go north.'), dict(label='South', description='Go south.')])], isBlocking=True)))
        elif text == 'approval':
            emit(dict(id='approval-'+active, method='item/commandExecution/requestApproval', params=dict(threadId=owner, turnId=active, itemId='command', command='echo fixture', cwd=p['cwd'], reason='Offline fixture approval')))
        else: finish()
    elif method == 'turn/steer':
        assert p['expectedTurnId'] == active
        emit(dict(id=obj['id'], result=dict(turnId=active)))
        notify('item/agentMessage/delta', threadId=owner, turnId=active, itemId='answer-'+active, delta='\nAdditional output while you are reading.')
    elif method == 'turn/interrupt':
        emit(dict(id=obj['id'], result={}))
        if active:
            notify('turn/completed', threadId=owner, turn=dict(id=active, status='interrupted')); active=None
    elif method is None and str(obj.get('id','')).startswith(('question-', 'approval-')):
        finish('Fixture decision received.')
    elif method not in ('initialized', None): emit(dict(id=obj['id'], error=dict(code=-32601, message='Unsupported offline fixture method')))
