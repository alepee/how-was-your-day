#!/usr/bin/env python3
"""Exercise live MCP pagination against an isolated copy of a synthetic UI-test store."""
import json, pathlib, select, shutil, sqlite3, subprocess, sys, tempfile, uuid
binary, source = sys.argv[1:]
source = pathlib.Path(source).resolve()
assert 'test' in source.name and source.name != 'HWYD'

class Client:
    def __init__(self, root):
        self.p = subprocess.Popen([binary, '--store', str(root), '--read-only'], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        self.n = 0
        self.rpc('initialize', {'protocolVersion':'2025-06-18','capabilities':{},'clientInfo':{'name':'pagination-test','version':'1'}})
        self.p.stdin.write('{"jsonrpc":"2.0","method":"notifications/initialized"}\n'); self.p.stdin.flush()
    def rpc(self, method, params):
        self.n += 1
        self.p.stdin.write(json.dumps({'jsonrpc':'2.0','id':self.n,'method':method,'params':params})+'\n'); self.p.stdin.flush()
        while True:
            assert select.select([self.p.stdout], [], [], 15)[0], 'MCP timeout'
            line = self.p.stdout.readline(); assert line, self.p.stderr.read()
            value = json.loads(line)
            if value.get('id') == self.n: return value['result']
    def call(self, args):
        result = self.rpc('tools/call', {'name':'get_recording','arguments':args})
        return result, json.loads(result['content'][0]['text'])
    def pages(self, args):
        result = []; cursor = None
        for _ in range(500):
            reply, page = self.call(args | ({'cursor':cursor} if cursor else {}))
            assert not reply.get('isError'), page
            assert page['page_chars'] <= args.get('max_chars', 30000)
            result.append(page); cursor = page['next_cursor']
            if cursor is None: break
        else: raise AssertionError('pagination did not terminate')
        assert len(result) == result[0]['total_pages']
        assert [p['page'] for p in result] == list(range(1,len(result)+1))
        assert sum(p['page_chars'] for p in result) == result[0]['total_chars']
        return result
    def close(self):
        self.p.stdin.close()
        try: self.p.wait(timeout=5)
        except subprocess.TimeoutExpired: self.p.terminate(); self.p.wait(timeout=5)

with tempfile.TemporaryDirectory(prefix='hwyd-mcp-pagination-test-') as temporary:
    root = pathlib.Path(temporary)
    src = sqlite3.connect(f'file:{source / "hwyd.sqlite"}?mode=ro', uri=True)
    db = sqlite3.connect(root / 'hwyd.sqlite'); src.backup(db); src.close()
    dbid, raw = db.execute('select id,payload from ui_recordings limit 1').fetchone()
    r = json.loads(raw); rid = r['id']; speaker = str(uuid.uuid4()).upper()
    r['speakers'] = [{'id':speaker,'label':'Speaker test','confirmed':True,'source':'mic'}]
    r['segments'] = [dict(id=str(uuid.uuid4()).upper(),start=i*10,end=i*10+8,source='mic' if i%2==0 else 'system',text=('Sentence %d. '%i)*25,**({'speakerID':speaker} if i%3 else {})) for i in range(18)]
    r['segments'][2]['echoSuspect'] = True
    r['summary'] = None; r.pop('summaryProvenance',None); r['transcriptState']='ready'; r['transcriptVersion']=1
    db.execute('update ui_recordings set payload=? where id=?',(json.dumps(r),dbid)); db.commit()
    c = Client(root)
    try:
        tools = c.rpc('tools/list', {})['tools']; assert all(len(t['description'])>40 for t in tools)
        args = {'id':rid,'include':'transcript','max_chars':1000,'max_segments':3}
        pages = c.pages(args)
        full = c.rpc('resources/read', {'uri':f'hwyd://recording/{rid}/transcript.md'})['contents'][0]['text']
        assert ''.join(p['artifacts']['transcript']['markdown'] for p in pages)==full
        assert not any(p['partial_segment'] for p in pages)
        structured = c.pages(args | {'format':'structured'})
        segments = [s for p in structured for s in p['segments']]
        assert [s['id'] for s in segments]==[s['id'] for s in r['segments']]
        assert all(s['confidence'] is None for s in segments)
        filtered = c.pages(args | {'format':'structured','from':20,'to':70,'track':'mic','speaker':speaker,'exclude_echo_suspect':True,'exclude_unattributed':True})
        assert [s['start'] for p in filtered for s in p['segments']]==[40]
        _, missing = c.call({'id':rid,'include':'summary'})
        assert missing['artifacts']['summary']['status']=='unavailable'
        assert missing['artifacts']['summary']['reason']=='not_generated_or_invalidated'
        for bad in [{'from':True},{'exclude_echo_suspect':1},{'from':10,'to':10},{'max_segments':True}]:
            result, error = c.call({'id':rid}|bad); assert result['isError'] and error['code']=='INVALID_ARGUMENTS'
        first = pages[0]
        result, error = c.call(args | {'cursor':first['next_cursor'],'track':'mic'})
        assert result['isError'] and error['code']=='INVALID_CURSOR'
    finally: c.close()
    # One oversized segment must remain reconstructable and never stall a cursor.
    r['segments'] = [r['segments'][0]]; r['segments'][0]['text']='Longword' * 1000 + ' end 👩🏽‍💻.'
    db.execute('update ui_recordings set payload=? where id=?',(json.dumps(r),dbid)); db.commit()
    c=Client(root)
    try:
        pages=c.pages({'id':rid,'include':'transcript','format':'structured','max_chars':1000})
        segments=[s for p in pages for s in p['segments']]
        assert ''.join(s['text'] for s in segments)==r['segments'][0]['text']
        assert all(s['partial'] for s in segments) and all(p['partial_segment'] for p in pages)
        assert segments[0]['text_offset']==0
    finally:c.close();db.close()
print('MCP segment boundaries, structured filters, budgets, totals, oversized segments, statuses: PASS')
