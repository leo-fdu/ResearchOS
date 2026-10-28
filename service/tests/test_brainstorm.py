import json, tempfile, threading, time, unittest
from pathlib import Path
from unittest.mock import patch
from ros.store import Workspace
from ros.library import Library
from ros.brainstorm import Brainstorm,response_object
from ros.brainstorm_tools import workbench,canonical_url,run_script

class BrainstormTests(unittest.TestCase):
    def setUp(self):
        self.temp=tempfile.TemporaryDirectory();self.root=Path(self.temp.name)
        self.store=Workspace(self.root/'state');self.library=Library(self.store)
        self.prompts=[]
        test=self
        class Runner:
            def run(self,prompt,timeout,stop):
                context=json.loads(prompt.split('\n\n',1)[1]);test.prompts.append(context)
                return json.dumps({'summary':'Independent proposal '+context['you']['name'],'reasoning':'fixture evidence','weakness':'small sample','changes':'No new evidence','novelty':False,'verification':'Not executed','next_step':'Collect a matched sample','positions':{key:{'stance':'support','reason':'bounded fixture'} for key in context['agenda']}})
            def close(self):pass
            def steer(self,text):pass
        self.brain=Brainstorm(self.store,self.library,lambda *_:Runner())
    def tearDown(self):self.brain.close();self.temp.cleanup()
    def room(self,**config):
        return self.brain.create({'topic':'Test a hypothesis','members':[{'runtime':'codex','model':'fixture','name':'A'},{'runtime':'pi','provider':'fixture','model':'fixture','name':'B'}],'config':{'max_calls':12,**config}})
    def wait(self,id):
        deadline=time.monotonic()+5
        while id in self.brain.active and time.monotonic()<deadline:time.sleep(.01)
        self.assertNotIn(id,self.brain.active)
        return self.brain.detail(id)
    def test_independent_proposals_sequential_discussion_and_early_convergence(self):
        r=self.room(mode='discuss',max_rounds=10);self.brain.start(r['id']);done=self.wait(r['id'])
        self.assertEqual(done['status'],'completed');self.assertEqual(done['calls'],9)
        self.assertEqual(self.prompts[0]['history'],[]);self.assertEqual(self.prompts[1]['history'],[])
        discussion=[p for p in self.prompts if p['phase']=='discussion' and p['round']==1]
        self.assertEqual(len(discussion),2)
        self.assertEqual(len(discussion[1]['history']),len(discussion[0]['history'])+1)
        self.assertEqual(discussion[1]['history'][-1]['member'],r['members'][0]['id'])
        self.assertIn('全体明确支持',done['report_details']);self.assertIn('系统没有记录任何脚本运行',done['report_details'])
    def test_budget_reserves_final_statements(self):
        r=self.room(max_calls=4,mode='discuss');self.brain.start(r['id']);done=self.wait(r['id'])
        self.assertEqual(done['calls'],4);self.assertEqual([p['phase'] for p in self.prompts],['proposal','proposal','final','final'])
    def test_all_failed_does_not_burn_remaining_budget(self):
        class Failed:
            def run(self,*args):raise RuntimeError('No entitlement')
            def close(self):pass
        self.brain.runner_factory=lambda *_:Failed()
        r=self.room();self.brain.start(r['id']);done=self.wait(r['id'])
        self.assertEqual(done['status'],'paused');self.assertEqual(done['calls'],2)
        self.assertNotIn('全体明确支持',done['report']);self.assertIn('No entitlement',done['report'])
    def test_missing_and_stale_final_votes_are_not_consensus(self):
        r=self.room();a,b=r['members']
        response={'summary':'A','positions':{'proposal:'+a['id']:{'stance':'support','reason':'x'},'proposal:'+b['id']:{'stance':'support','reason':'x'}}}
        self.brain.entry(r['id'],a['id'],'final',0,'completed',{'response':response})
        report=self.brain.report(r['id']);self.assertIn('未表态',report);self.assertNotIn('全体明确支持',report)
        self.brain.entry(r['id'],b['id'],'final',0,'completed',{'response':response})
        self.assertIn('全体明确支持',self.brain.report(r['id']))
        self.brain.control(r['id'],'guidance','New constraint')
        self.assertNotIn('全体明确支持',self.brain.report(r['id']))
    def test_mentions_are_public_to_every_member(self):
        r=self.room();a,b=r['members'];self.brain.control(r['id'],'guidance','Please check this',target=a['id'])
        pa=json.loads(self.brain.prompt(r['id'],a,'proposal',0).split('\n\n',1)[1])
        pb=json.loads(self.brain.prompt(r['id'],b,'proposal',0).split('\n\n',1)[1])
        self.assertEqual(pa['user_guidance'][0]['text'],'Please check this');self.assertEqual(pb['user_guidance'][0]['text'],'Please check this')
        self.assertEqual(pb['user_guidance'][0]['mentions'],[a['id']])
    def test_pause_cancels_and_resume_does_not_replay_charged_turn(self):
        entered=threading.Event()
        class Waiting:
            def run(self,prompt,timeout,stop):entered.set();stop.wait(2);raise RuntimeError('stopped')
            def close(self):pass
        self.brain.runner_factory=lambda *_:Waiting()
        r=self.room();self.brain.start(r['id']);self.assertTrue(entered.wait(1))
        self.brain.control(r['id'],'pause');done=self.wait(r['id'])
        self.assertIn(done['calls'],[1,2]);self.assertEqual(done['status'],'paused')
        self.assertEqual(done['entries'][0]['status'],'interrupted')
    def test_source_dedup_read_ack_and_immutable_artifacts(self):
        r=self.room(work_mode=True);id=r['id'];a,b=[m['id'] for m in r['members']]
        first=workbench(self.brain,id,a,{'action':'share_source','title':'Paper','url':'10.1234/ABC','reading':'abstract'})
        second=workbench(self.brain,id,b,{'action':'share_source','title':'Same','url':'https://doi.org/10.1234/abc','reading':'found'})
        self.assertEqual(first['id'],second['id']);self.assertEqual(second['read_by'],[a]);self.assertEqual(len(second['found_by']),2)
        workbench(self.brain,id,b,{'action':'acknowledge','id':first['id']});self.assertEqual(len(self.brain.room(id)['sources'][0]['read_by']),2)
        workbench(self.brain,id,a,{'action':'write_file','path':'x.py','text':'print(1)'})
        v1=workbench(self.brain,id,a,{'action':'publish_file','path':'x.py'})
        workbench(self.brain,id,a,{'action':'write_file','path':'x.py','text':'print(2)'})
        v2=workbench(self.brain,id,a,{'action':'publish_file','path':'x.py'})
        self.assertNotEqual(v1['path'],v2['path']);self.assertEqual(Path(v1['path']).read_text(),'print(1)')
    def test_path_traversal_symlink_and_other_personal_workspace_denied(self):
        r=self.room(work_mode=True);id=r['id'];a,b=[m['id'] for m in r['members']]
        personal=self.brain.path(id)/'members'/a
        (personal/'escape').symlink_to(self.root)
        for path in ('../../outside','escape/outside'):
            with self.assertRaises(ValueError):workbench(self.brain,id,a,{'action':'write_file','path':path,'text':'bad'})
        with self.assertRaises(ValueError):workbench(self.brain,id,a,{'action':'list','path':str(self.brain.path(id)/'members'/b)})
    def test_all_resource_types_not_filtered_by_project(self):
        repo=self.root/'repo';repo.mkdir();(repo/'readme.md').write_text('real content')
        self.store.root_add(repo,'repo')
        for kind in ('project','idea','note'):self.store.put({'kind':kind,'title':kind,'body':'resource'})
        r=self.room();id=r['id'];m=r['members'][0]['id']
        result=workbench(self.brain,id,m,{'action':'resources'})
        self.assertEqual({x['kind'] for x in result['records']},{'project','idea','note'})
        self.assertEqual(workbench(self.brain,id,m,{'action':'read_file','path':str(repo/'readme.md')})['text'],'real content')
    def test_personal_files_allowed_without_work_mode(self):
        r=self.room(mode='discuss');m=r['members'][0]['id']
        result=workbench(self.brain,r['id'],m,{'action':'write_file','path':'x.py','text':'x'})
        self.assertEqual(Path(result['path']).read_text(),'x')
    def test_tool_limit_and_inactive_capability(self):
        r=self.room(max_tools=1);id=r['id'];m=r['members'][0]['id']
        with self.assertRaises(ValueError):self.brain.tool(id,m,{'action':'resources'})
        self.brain.active[id]={'stop':threading.Event(),'deadline':time.monotonic()+10,'tool_counts':{}}
        try:
            self.brain.tool(id,m,{'action':'resources'})
            with self.assertRaises(ValueError):self.brain.tool(id,m,{'action':'resources'})
        finally:self.brain.active.pop(id)
    def test_response_parser_accepts_free_text_and_rejects_empty_output(self):
        self.assertEqual(response_object('你好！')['text'],'你好！')
        with self.assertRaises(ValueError):response_object('   ')
        self.assertEqual(response_object('```json\n{"summary":"bounded"}\n```')['summary'],'bounded')
    def test_verification_turns_are_reserved_in_tight_budget(self):
        r=self.room(max_calls=6,mode='verify');self.brain.start(r['id']);done=self.wait(r['id'])
        self.assertEqual(done['calls'],6)
        self.assertEqual([p['phase'] for p in self.prompts],['proposal','proposal','verification','verification','final','final'])
    def test_explicit_retry_preserves_spent_calls_and_completes(self):
        original=self.brain.runner_factory
        class Failed:
            def run(self,*args):raise RuntimeError('temporary failure')
            def close(self):pass
        self.brain.runner_factory=lambda *_:Failed()
        r=self.room(mode='discuss',max_rounds=1);self.brain.start(r['id']);self.wait(r['id'])
        self.brain.runner_factory=original;self.brain.control(r['id'],'retry');done=self.wait(r['id'])
        self.assertEqual(done['status'],'completed');self.assertEqual(done['calls'],9)
        self.assertEqual(sum(e['status']=='retry_requested' for e in done['entries']),2)
    def test_live_guidance_reaches_active_member_and_survives_scheduler(self):
        original=self.brain.runner_factory;entered=threading.Event();received=threading.Event();messages=[]
        class Waiting:
            def run(self,prompt,timeout,stop):
                entered.set();received.wait(2)
                return original().run(prompt,timeout,stop)
            def close(self):pass
            def steer(self,text):messages.append(text);received.set()
        self.brain.runner_factory=lambda *_:Waiting()
        r=self.room(mode='discuss',max_calls=4);self.brain.start(r['id']);self.assertTrue(entered.wait(1))
        self.brain.control(r['id'],'guidance','Keep the control fixed')
        self.assertTrue(received.wait(1));done=self.wait(r['id'])
        self.assertTrue(messages);self.assertTrue(all(m=='Keep the control fixed' for m in messages));self.assertEqual(done['guidance'][0]['text'],'Keep the control fixed')
    def test_invalid_budget_rejected(self):
        with self.assertRaises(ValueError):self.room(max_calls=1)
        with self.assertRaises(ValueError):self.room(minutes=-1)

if __name__=='__main__':unittest.main()

class BrainstormHTTPTests(unittest.TestCase):
    def setUp(self):
        from ros.server import Server
        self.temp=tempfile.TemporaryDirectory();self.server=Server(self.temp.name,bootstrap_enabled=False)
        self.thread=threading.Thread(target=self.server.serve_forever,daemon=True);self.thread.start()
    def tearDown(self):self.server.shutdown();self.server.server_close();self.temp.cleanup()
    def request(self,path,data=None,headers=None):
        import urllib.request
        h={'X-ResearchOS-Token':self.server.token,'Content-Type':'application/json'} if headers is None else headers
        req=urllib.request.Request(self.server.origin+path,data=None if data is None else json.dumps(data).encode(),headers=h)
        with urllib.request.urlopen(req,timeout=3) as response:return json.load(response)
    def test_room_crud_and_report_note_preserve_memory(self):
        room=self.request('/v2/brainstorm/create',{'topic':'http fixture','members':[{'runtime':'codex','model':'a'},{'runtime':'pi','provider':'b','model':'b'}]})
        self.assertEqual(len(self.request('/v2/brainstorm/rooms')),1)
        self.request('/v2/brainstorm/control',{'id':room['id'],'action':'guidance','text':'Important constraint'})
        detail=self.request('/v2/brainstorm/room?id='+room['id']);self.assertEqual(detail['guidance'][0]['text'],'Important constraint')
        note=self.request('/v2/brainstorm/save-note',{'id':room['id']});self.assertEqual(note['kind'],'note')
        memory=self.server.workspace.put({'kind':'memory','title':'Retained','body':'still works','data':{'source':'test'}})
        self.assertEqual(self.server.workspace.object(memory['id'])['kind'],'memory')
    def test_scoped_token_cannot_access_general_workspace_api(self):
        import urllib.error
        with self.assertRaises(urllib.error.HTTPError) as caught:self.request('/v2/state',headers={'X-Brainstorm-Token':'invalid'})
        self.assertEqual(caught.exception.code,403)
        with self.assertRaises(urllib.error.HTTPError) as caught:self.request('/v2/brainstorm/tool',{'action':'resources'},headers={'X-Brainstorm-Token':'invalid','Content-Type':'application/json'})
        self.assertEqual(caught.exception.code,403)
