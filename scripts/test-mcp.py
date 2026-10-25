#!/usr/bin/env python3
"""Test stdio sur un store synthétique créé par --ui-test, jamais le store utilisateur."""
import json, pathlib, sqlite3, subprocess, sys
binary, directory = sys.argv[1:]
root = pathlib.Path(directory).resolve()
assert 'test' in root.name and root.name != 'HWYD'
db = sqlite3.connect(root / 'hwyd.sqlite')
row = db.execute('select payload from ui_recordings limit 1').fetchone()
assert row
recording = json.loads(row[0]); rid = recording['id']; revision = recording['revision']
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
    _, item = c.tool('get_recording', {'id':rid}); assert item['recording']['revision']==revision
    assert 'Note enregistrée' in item['artifacts']['notes']['markdown']
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
print('MCP stdio, resources, FTS, read-only, CAS, idempotency, revocation: PASS')
