#!/usr/bin/env python3
"""Test stdio sur un store synthétique créé par --ui-test, jamais le store utilisateur."""
import json, pathlib, sqlite3, subprocess, sys
binary, directory = sys.argv[1:]
root = pathlib.Path(directory).resolve()
assert 'test' in root.name and root.name != 'HWYD'
db = sqlite3.connect(root / 'hwyd.sqlite')
row = db.execute('select id, payload from ui_recordings limit 1').fetchone()
assert row
recording = json.loads(row[1]); rid = recording['id']; revision = recording['revision']
# A summary made from an earlier transcript: corrections keep it, MCP says it is stale.
recording['summary'] = '## Résumé\n\nSynthèse périmée.'
recording['summaryProvenance'] = {'provider':'fixture','model':'fixture','promptVersion':'fixture','promptHash':'fixture','generatedAt':0,
    'transcriptVersion':recording['transcriptVersion'] + 1,'inputHash':'fixture','structured':{'overview':'Synthèse périmée.','decisions':[],'action_items':[]}}
db.execute('update ui_recordings set payload=? where id=?', (json.dumps(recording), row[0]))
db.execute("insert or replace into integration_settings values ('mcp_writes_enabled','true')"); db.commit()

class Client:
    def __init__(self, *flags):
        self.p = subprocess.Popen([binary, '--store', str(root), *flags], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        self.number = 0
        self.rpc('initialize', {'protocolVersion':'2025-06-18','capabilities':{},'clientInfo':{'name':'hwyd-test','version':'1'}})
        self.p.stdin.write(json.dumps({'jsonrpc':'2.0','method':'notifications/initialized'})+'\n'); self.p.stdin.flush()
    def rpc(self, method, params):
        self.number += 1
        self.p.stdin.write(json.dumps({'jsonrpc':'2.0','id':self.number,'method':method,'params':params})+'\n'); self.p.stdin.flush()
        while True:
            line = self.p.stdout.readline()
            if not line: raise RuntimeError(self.p.stderr.read())
            response = json.loads(line)
            if response.get('id') == self.number: return response
    def tool(self, name, arguments):
        result = self.rpc('tools/call', {'name':name,'arguments':arguments})['result']
        return result, json.loads(result['content'][0]['text'])
    def close(self):
        self.p.stdin.close()
        try: self.p.wait(timeout=5)
        except subprocess.TimeoutExpired: self.p.terminate(); self.p.wait(timeout=5)

c = Client()
try:
    tools = c.rpc('tools/list', {})['result']['tools']; assert len(tools)==4
    result, listing = c.tool('list_recordings', {}); assert not result.get('isError'); assert listing['items'][0]['id']==rid
    _, item = c.tool('get_recording', {'id':rid}); assert item['recording']['revision']==revision and item['recording']['capture_boundaries']==[]
    assert 'Note enregistrée' in item['artifacts']['notes']['markdown']
    summary = item['artifacts']['summary']; assert summary['status']=='stale' and 'Synthèse périmée' in summary['markdown'] and summary['reason'] is None, summary
    resource = c.rpc('resources/read', {'uri':f'hwyd://recording/{rid}/summary.md'}); assert 'Synthèse périmée' in resource['result']['contents'][0]['text']
    # A missing summary is never reported as removed by an edit, even with a provenance left behind.
    db.execute('update ui_recordings set payload=? where id=?', (json.dumps(dict(recording, summary=None)), row[0])); db.commit()
    _, item = c.tool('get_recording', {'id':rid, 'include':'summary'})
    summary = item['artifacts']['summary']; assert summary['status']=='unavailable' and summary['reason']=='not_generated_or_invalidated', summary
    # Recording resumed in the session: where on its timeline, when, why and with which microphone.
    db.execute('update ui_recordings set payload=? where id=?', (json.dumps(dict(recording, boundaries=[{'offset':12.5,'at':0,'reason':'resumed','microphone':'Micro'}])), row[0])); db.commit()
    _, item = c.tool('get_recording', {'id':rid, 'include':'notes'})
    assert item['recording']['capture_boundaries']==[{'offset_us':12500000,'at':'2001-01-01T00:00:00Z','reason':'resumed','microphone':'Micro'}], item['recording']
    # The marker goes before the first passage after the resume, and only when the resume is in the requested range.
    segments = [{'id':'00000000-0000-4000-8000-0000000000a1','start':5,'end':6,'source':'mic','text':'Avant la reprise'},
                {'id':'00000000-0000-4000-8000-0000000000a2','start':20,'end':21,'source':'mic','text':'Après la reprise'}]
    db.execute('update ui_recordings set payload=? where id=?', (json.dumps(dict(recording, segments=segments, boundaries=[{'offset':12.5,'at':0,'reason':'resumed'}])), row[0])); db.commit()
    _, item = c.tool('get_recording', {'id':rid, 'include':'transcript'})
    text = item['artifacts']['transcript']['markdown']
    assert text.count('Reprise à')==1 and text.index('Avant la reprise') < text.index('[00:00:12] Reprise à') < text.index('Après la reprise'), text
    for window in ({'from':15}, {'to':10}):
        _, item = c.tool('get_recording', dict({'id':rid, 'include':'transcript'}, **window))
        assert 'Reprise à' not in item['artifacts']['transcript']['markdown'], (window, item['artifacts']['transcript'])
    db.execute('update ui_recordings set payload=? where id=?', (json.dumps(recording), row[0])); db.commit()
    _, search = c.tool('search', {'query':'enregistrée'}); assert search['items']
    resource = c.rpc('resources/read', {'uri':f'hwyd://recording/{rid}/notes.md'}); assert 'Note enregistrée' in resource['result']['contents'][0]['text']
    assert len(c.rpc('resources/templates/list', {})['result']['resourceTemplates'])==3
    result, error = c.tool('list_recordings', {'limit':True}); assert result['isError'] and error['code']=='INVALID_ARGUMENTS'
    result, error = c.tool('set_notes', {'id':rid,'markdown':'forbidden','expected_revision':revision,'request_id':'00000000-0000-4000-8000-000000000001'}); assert result['isError']
finally: c.close()
c = Client('--allow-write')
try:
    assert len(c.rpc('tools/list', {})['result']['tools'])==6
    args={'id':rid,'markdown':'Note enregistrée par MCP','expected_revision':revision,'request_id':'00000000-0000-4000-8000-000000000002'}
    result, receipt=c.tool('set_notes',args); assert not result.get('isError'), receipt
    _, retry=c.tool('set_notes',args); assert retry==receipt
    args['request_id']='00000000-0000-4000-8000-000000000003'
    result,error=c.tool('set_notes',args); assert error['code']=='VERSION_CONFLICT'
    db.execute("update integration_settings set value='false' where key='mcp_writes_enabled'"); db.commit()
    args['expected_revision']=receipt['revision']
    result,error=c.tool('set_notes',args); assert error['code']=='WRITE_DISABLED'
finally: c.close(); db.close()
print('MCP stdio, resources, stale summary, capture boundaries, FTS, read-only, CAS, idempotency, revocation: PASS')
