#!/usr/bin/env python3
"""Exerce le provider HTTP avec un modèle simulé et un transcript fictif."""
import http.server, json, os, subprocess, threading
class Handler(http.server.BaseHTTPRequestHandler):
    def do_POST(self):
        assert self.path == '/v1/chat/completions'
        body=json.loads(self.rfile.read(int(self.headers['Content-Length'])))
        assert body['response_format']['type']=='json_schema'
        due=body['response_format']['json_schema']['schema']['properties']['action_items']['items']['properties']['due_date']
        assert due == {'type':'null'}, due
        prompt, payload = body['messages'][1]['content'].split('\n', 1)
        payload = json.loads(payload)
        if prompt.startswith('EXTRACT:'):
            segments = payload
        else:
            assert prompt.startswith('WRITE_TOPIC:'), prompt
            segments = payload['original_transcript']
        assert segments and all('id' in segment for segment in segments)
        summary={'overview':'Synthèse HTTP synthétique','decisions':[{'text':'Décision fictive','evidence_segment_ids':[segments[0]['id']]}],'action_items':[], 'key_points':[], 'details':[{'title':'Contexte', 'text':'Discussion synthétique.', 'evidence_segment_ids':[segments[0]['id']]}]}
        data=json.dumps({'choices':[{'message':{'content':json.dumps(summary)}}]}).encode()
        self.send_response(200); self.send_header('Content-Type','application/json'); self.send_header('Content-Length',len(data)); self.end_headers(); self.wfile.write(data)
    def log_message(self,*args): pass
server=http.server.HTTPServer(('127.0.0.1',0),Handler)
threading.Thread(target=server.serve_forever,daemon=True).start()
env=dict(os.environ, DEVELOPER_DIR='/Applications/Xcode.app/Contents/Developer', HWYD_TEST_LLM_URL=f'http://127.0.0.1:{server.server_port}/v1')
try: subprocess.run(['swift','test','--package-path','Packages/HWYDCore','--filter','IntegrationTests'],env=env,check=True)
finally: server.shutdown()
