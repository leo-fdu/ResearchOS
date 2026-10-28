import base64,json,unittest
from ros.agent import Agent
from ros.brainstorm import SCHEMA
from ros.brainstorm_tools import workbench
from ros.brainstorm_reader import uri,GUIDE
from test_brainstorm import BrainstormTests as Fixture

class BrainstormReaderTests(unittest.TestCase):
 _setup=Fixture.setUp
 tearDown=Fixture.tearDown
 room=Fixture.room
 def setUp(self):
  self._setup()
  self.agent=Agent(self.store,self.library,None);self.session=self.store.session();self.r=self.room()
 def call(self,name,**args):return self.agent.tool(name,args,self.session['id'],'reader-test')
 def readall(self,url,limit=101):
  start=0;parts=[]
  while True:
   p=self.call('read_record',id=url,start=start,limit=limit);parts.append(p['text'])
   if p['next_start'] is None:break
   start=p['next_start']
  return ''.join(parts)
 def test_full_transcript_search_and_pagination_beyond_30_messages(self):
  for i in range(45):self.brain.entry(self.r['id'],'user','user',i,'completed',{'text':f'needle_{i} '+('长内容'*80)})
  hits=self.call('search_workspace',query='needle_0');self.assertEqual(hits[0]['id'],self.r['id'])
  overview=json.loads(self.readall(hits[0]['read_uri']))
  entries=json.loads(self.readall(overview['links']['transcript'],1500))
  self.assertEqual(len(entries),45);self.assertTrue(entries[0]['payload']['text'].startswith('needle_0'))
  self.assertTrue(entries[-1]['payload']['text'].startswith('needle_44'))
 def test_reports_personal_scripts_shared_outputs_binary_are_readable(self):
  root=self.brain.path(self.r['id']);script=root/'members'/self.r['members'][0]['id']/'check.py';script.write_text('print("not executed")')
  binary=root/'shared'/'resources'/'result.bin';binary.write_bytes(b'\x00\xff\x01')
  self.brain.report(self.r['id'])
  before=self.store.rows('SELECT * FROM brainstorm_entries')
  files=json.loads(self.readall(uri(self.r['id'],section='files')))
  script_link=next(f['read_uri'] for f in files if f['path'].endswith('check.py'))
  self.assertEqual(self.readall(script_link),'print("not executed")')
  data=self.call('read_record',id=next(f['read_uri'] for f in files if f['path'].endswith('result.bin')))
  self.assertEqual(base64.b64decode(data['data']),b'\x00\xff\x01')
  self.assertTrue(self.readall(uri(self.r['id'],section='report')))
  self.assertEqual(before,self.store.rows('SELECT * FROM brainstorm_entries'))
 def test_deleted_requires_explicit_read_and_is_not_searchable_by_default(self):
  self.brain.control(self.r['id'],'delete')
  self.assertEqual(self.call('list_records',kind='brainstorm')['records'],[])
  self.assertEqual(self.call('search_workspace',query='Test a hypothesis'),[])
  with self.assertRaisesRegex(ValueError,'Deleted'):self.call('read_record',id=self.r['id'])
  values=self.call('read_record',id=uri('index',deleted=1))
  self.assertEqual(json.loads(self.readall(values['records'][0]['read_uri']))['id'],self.r['id'])
 def test_path_traversal_symlinks_and_mutating_sections_are_rejected(self):
  root=self.brain.path(self.r['id']);outside=self.root/'outside';outside.write_text('secret');(root/'escape').symlink_to(outside)
  for path in ['../outside',str(outside),'escape']:
   with self.assertRaises(ValueError):self.call('read_record',id=uri(self.r['id'],section='file',path=path))
  with self.assertRaises(ValueError):self.call('read_record',id=uri(self.r['id'],section='delete'))
  self.assertEqual(outside.read_text(),'secret')
 def test_member_tools_still_cannot_create_records_or_links(self):
  actions=SCHEMA['properties']['action']['enum']
  for action in ['save_record','create_idea','create_project','link_records']:
   self.assertNotIn(action,actions)
   with self.assertRaisesRegex(ValueError,'Unknown workbench action'):workbench(self.brain,self.r['id'],self.r['members'][0]['id'],{'action':action})
 def test_usage_guidance_reaches_existing_thread_without_new_tools(self):
  s=self.session;s['thread_id']='existing-thread';self.agent.loaded.add(s['thread_id']);self.agent.thread_web[s['thread_id']]=True
  self.agent.active[s['id']]={'memory':False};self.agent.start=lambda:None
  calls=[]
  def rpc(method,params):calls.append((method,params));return {'turn':{'id':'fake-turn'}}
  self.agent.rpc=rpc;self.agent._begin(s,'Review the brainstorm',[],'fixture',False,False)
  prompt=next(p for m,p in calls if m=='turn/start')['input'][0]['text']
  self.assertIn(GUIDE,prompt);self.assertNotIn('thread/start',[m for m,p in calls])
  self.assertIn('read_record',prompt);self.assertIn('Do not claim it was started',prompt)
del Fixture
