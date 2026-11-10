import importlib.util
import json
from pathlib import Path
import ssl
import tempfile
import threading
import unittest
from urllib import request, error
from unittest.mock import patch
import subprocess

spec=importlib.util.spec_from_file_location('bridge',Path(__file__).with_name('bridge.py'))
bridge=importlib.util.module_from_spec(spec);spec.loader.exec_module(bridge)
PAYLOAD={'model':'codex-subscription','messages':[{'role':'system','content':'Return JSON'},{'role':'user','content':'synthetic only'}],'stream':False}
class BridgeTests(unittest.TestCase):
 def test_strict_shape(self):
  self.assertEqual(len(bridge.validate_payload(PAYLOAD)),2)
  for mutation in [{'model':'paid-api'},{'stream':True},{'messages':[]},{'messages':[{'role':'system','content':'a'},{'role':'user','content':['image']}]},{'messages':[{'role':'user','content':'b'},{'role':'system','content':'a'}]}]:
   with self.subTest(mutation=mutation),self.assertRaises(bridge.BridgeError):bridge.validate_payload(dict(PAYLOAD,**mutation))
 def test_no_shell_interpolation_or_tools(self):
  cmd=bridge.command_for('/official/codex',Path('/safe/temp'),Path('/safe/schema'))
  self.assertIn('--ignore-user-config',cmd);self.assertIn('--ephemeral',cmd);self.assertIn('project_doc_max_bytes=0',cmd)
  self.assertIn('read-only',cmd);self.assertIn('shell_tool',cmd);self.assertIn('multi_agent',cmd)
  self.assertNotIn('danger-full-access',cmd);self.assertEqual(cmd[-1],'-')
  self.assertNotIn(PAYLOAD['messages'][1]['content'],cmd)
 def test_subscription_required(self):
  for text in ['Logged in using an API key','Not logged in']:
   with patch.object(bridge.subprocess,'run',return_value=subprocess.CompletedProcess([],0,text,'')),self.assertRaises(bridge.BridgeError):bridge.ensure_subscription('codex')
  with patch.object(bridge.subprocess,'run',return_value=subprocess.CompletedProcess([],0,'Logged in using ChatGPT','')):bridge.ensure_subscription('codex')
 def test_recovered_error_is_not_a_tool(self):
  class FakeProcess:
   pid=123
   returncode=0
   def __init__(self,cmd,**kwargs):
    assert 'OPENAI_API_KEY' not in kwargs['env']
    kwargs['stdout'].write(b'{"item":{"type":"error","message":"transient transport retry"}}\n')
    kwargs['stdout'].write(b'{"item":{"type":"agent_message"}}\n')
    Path(cmd[cmd.index('--output-last-message')+1]).write_text('{"body":"synthetic"}')
   def communicate(self,*args,**kwargs):return None,None
  with patch.object(bridge,'ensure_subscription'),patch.object(bridge.subprocess,'Popen',FakeProcess),patch.dict(bridge.os.environ,{'OPENAI_API_KEY':'synthetic-not-a-real-key'}):
   self.assertEqual(bridge.run_codex(PAYLOAD['messages'],'codex'),'{"body":"synthetic"}')
 def test_tool_result_withheld(self):
  class FakeProcess:
   pid=123
   returncode=0
   def __init__(self,cmd,**kwargs):
    kwargs['stdout'].write(b'{"item":{"type":"command_execution"}}\n')
    Path(cmd[cmd.index('--output-last-message')+1]).write_text('{"body":"synthetic"}')
   def communicate(self,*args,**kwargs):return None,None
  with patch.object(bridge,'ensure_subscription'),patch.object(bridge.subprocess,'Popen',FakeProcess),self.assertRaises(bridge.BridgeError):bridge.run_codex(PAYLOAD['messages'],'codex')
 def test_hostname_validation(self):
  self.assertEqual(bridge.safe_host('My-Mac.local'),'My-Mac.local')
  for value in ['bad\nhost','$(echo token)','*','host,IP:evil']:
   with self.subTest(value=value),self.assertRaises(ValueError):bridge.safe_host(value)
 def test_authenticated_https_and_size(self):
  with tempfile.TemporaryDirectory() as raw:
   folder=Path(raw);token=bridge.initialize(folder,'localhost',8787)
   pairing=json.loads((folder/'pairing.json').read_text())
   self.assertEqual(pairing['model'],'codex-subscription');self.assertEqual(len(pairing['certificateSHA256']),64)
   self.assertEqual((folder/'token').stat().st_mode&0o777,0o600)
   self.assertEqual((folder/'server.key').stat().st_mode&0o777,0o600)
   self.assertEqual(token,bridge.initialize(folder,'localhost',8787))
   seen=[]
   def runner(messages,binary):seen.append(messages);return '{"body":"synthetic"}'
   server=bridge.BridgeServer(('127.0.0.1',0),token,'unused',runner)
   tls=ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER);tls.load_cert_chain(str(folder/'server.pem'),str(folder/'server.key'));server.socket=tls.wrap_socket(server.socket,server_side=True)
   thread=threading.Thread(target=server.serve_forever,daemon=True);thread.start()
   context=ssl.create_default_context(cafile=str(folder/'server.pem'));base='https://localhost:'+str(server.server_port)
   def post(body,credential=token):return request.urlopen(request.Request(base+'/v1/chat/completions',data=body,headers={'Authorization':'Bearer '+credential,'Content-Type':'application/json'}),context=context,timeout=5)
   try:
    with self.assertRaises(error.HTTPError) as missing:post(json.dumps(PAYLOAD).encode(),'wrong')
    self.assertEqual(missing.exception.code,401);self.assertFalse(seen)
    with post(json.dumps(PAYLOAD).encode()) as response:self.assertEqual(json.load(response)['choices'][0]['message']['content'],'{"body":"synthetic"}')
    self.assertEqual(len(seen),1)
    with self.assertRaises(error.HTTPError) as oversize:post(b' '*33_000)
    self.assertEqual(oversize.exception.code,413)
    # An unrelated self-signed certificate cannot authenticate this service.
    with self.assertRaises(error.URLError):request.urlopen(base+'/health',timeout=3)
   finally:server.shutdown();server.server_close();thread.join()
if __name__=='__main__':unittest.main(verbosity=2)
