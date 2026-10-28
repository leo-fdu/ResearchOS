"""Session lifecycle, actual overlapping proposals, public guidance and workspace policy."""
import json,threading,time,unittest
from pathlib import Path
from unittest.mock import patch
from test_brainstorm import BrainstormTests as Fixture
from ros.brainstorm_tools import workbench

class SessionTests(unittest.TestCase):
    setUp=Fixture.setUp
    tearDown=Fixture.tearDown
    room=Fixture.room
    wait=Fixture.wait
    # Reuse isolated setup/fixtures without inheriting and rerunning the v1 suite.
    def test_proposals_overlap_but_no_peer_proposal_is_visible(self):
        barrier=threading.Barrier(2);original=self.brain.runner_factory;seen=[]
        class Runner:
            def run(inner,prompt,timeout,stop):
                c=json.loads(prompt.split('\n\n',1)[1])
                if c['phase']=='proposal':
                    seen.append(c);barrier.wait(timeout=2)
                return original().run(prompt,timeout,stop)
            def close(inner):pass
        self.brain.runner_factory=lambda *_:Runner()
        r=self.room(participation='agent_and_user');self.brain.start(r['id']);done=self.wait(r['id'])
        self.assertEqual(done['status'],'waiting_user');self.assertEqual(done['calls'],2)
        self.assertEqual(len(seen),2);self.assertTrue(all(not p['history'] for p in seen))

    def test_user_mode_waits_then_one_round_with_prior_speakers(self):
        r=self.room(participation='agent_and_user');self.brain.start(r['id']);self.wait(r['id'])
        self.brain.control(r['id'],'message','@A please test the alternative')
        done=self.wait(r['id']);self.assertEqual(done['status'],'waiting_user');self.assertEqual(done['calls'],4)
        replies=[p for p in self.prompts if p['phase']=='reply'];self.assertEqual(len(replies),2)
        self.assertEqual([p['you']['name'] for p in replies],['A','B'])
        self.assertEqual(replies[1]['history'][-1]['member'],r['members'][0]['id'])
        self.assertTrue(all(p['user_guidance'][-1]['text'].startswith('@A') for p in replies))
        self.assertEqual(done['guidance'][-1]['mentions'],[r['members'][0]['id']])
        calls=done['calls'];time.sleep(.05);self.assertEqual(self.brain.room(r['id'])['calls'],calls)

    def test_completed_agent_only_session_can_continue_and_change_topics(self):
        r=self.room(max_rounds=1,max_calls=30);self.brain.start(r['id']);done=self.wait(r['id']);self.assertEqual(done['status'],'completed')
        count=done['calls'];self.brain.control(r['id'],'message','What would falsify your claim?');done=self.wait(r['id'])
        self.assertEqual(done['calls'],count+2);self.assertEqual(done['status'],'waiting_user')
        self.brain.control(r['id'],'topic','Explore another explanation',participation='agent_and_user');done=self.wait(r['id'])
        self.assertEqual(done['cycle'],1);self.assertEqual(done['cycle_topic'],'Explore another explanation');self.assertEqual(done['status'],'waiting_user')
        self.assertEqual(done['calls'],count+4);self.assertTrue((self.brain.path(r['id'])/'shared/reports/topic-1-report.md').exists())
        current=[e for e in done['entries'] if e['phase']=='proposal' and e['payload']['cycle']==1];self.assertEqual(len(current),2)
        self.assertEqual(len(self.brain.list()),1)

    def test_delete_restore_preserves_history_and_workspace(self):
        r=self.room();id=r['id'];self.brain.control(id,'guidance','Keep this message')
        path=self.brain.path(id)/'members'/r['members'][0]['id']/'scratch.txt';path.write_text('preserved')
        self.brain.control(id,'delete');self.assertEqual(self.brain.list(),[]);self.assertEqual(len(self.brain.list(True)),1)
        with self.assertRaises(ValueError):self.brain.start(id)
        self.brain.control(id,'restore');self.assertEqual(len(self.brain.list()),1);self.assertEqual(path.read_text(),'preserved')
        self.assertEqual(self.brain.detail(id)['guidance'][0]['text'],'Keep this message')

    def test_work_mode_only_gates_shared_code(self):
        r=self.room();id=r['id'];m=r['members'][0]['id']
        workbench(self.brain,id,m,{'action':'write_file','path':'check.py','text':'print(1)'})
        workbench(self.brain,id,m,{'action':'write_file','path':'results.csv','text':'n,value\n1,2'})
        artifact=workbench(self.brain,id,m,{'action':'publish_file','path':'results.csv'});self.assertIn('/shared/resources/',artifact['path'])
        for action in ({'action':'publish_file','path':'check.py'},{'action':'write_shared','path':'check.py','text':'print(1)'}):
            with self.assertRaises(ValueError):workbench(self.brain,id,m,action)
        self.brain.control(id,'settings',work_mode=True)
        result=workbench(self.brain,id,m,{'action':'write_shared','path':'check.py','text':'print(2)'})
        self.assertIn('/shared/work/',result['path'])
        self.brain.control(id,'settings',work_mode=False)
        with self.assertRaises(ValueError):workbench(self.brain,id,m,{'action':'write_shared','path':'check.py','text':'print(3)'})
        with self.assertRaises(ValueError):workbench(self.brain,id,m,{'action':'write_file','path':'../../shared/work/escape.py','text':'bad'})

    def test_storage_limit_is_enforced_before_file_write(self):
        r=self.room();m=r['members'][0]['id']
        with patch('ros.brainstorm_tools.MEMBER_BYTES',5):
            with self.assertRaises(ValueError):workbench(self.brain,r['id'],m,{'action':'write_file','path':'too-large.txt','text':'123456'})
        self.assertFalse((self.brain.path(r['id'])/'members'/m/'too-large.txt').exists())

    def test_effort_change_during_turn_applies_to_next_member(self):
        original=self.brain.runner_factory;entered=threading.Event();release=threading.Event()
        class Runner:
            def run(inner,prompt,timeout,stop):
                c=json.loads(prompt.split('\n\n',1)[1])
                if c['phase']=='reply' and c['you']['name']=='A':entered.set();release.wait(2)
                return original().run(prompt,timeout,stop)
            def close(inner):pass
        self.brain.runner_factory=lambda *_:Runner()
        r=self.room(participation='agent_and_user');self.brain.start(r['id']);self.wait(r['id'])
        self.brain.control(r['id'],'message','Please respond');self.assertTrue(entered.wait(1))
        with patch('ros.brainstorm_runtime.catalog',return_value={'levels':['high','low']}):self.brain.control(r['id'],'effort',member_id=r['members'][1]['id'],effort='high')
        release.set();self.wait(r['id'])
        reply=next(p for p in self.prompts if p['phase']=='reply' and p['you']['name']=='B');self.assertEqual(reply['you']['effort'],'high')

    def test_exhausted_budget_keeps_followup_without_model_calls(self):
        r=self.room(mode='discuss',max_calls=4);self.brain.start(r['id']);self.wait(r['id'])
        self.brain.control(r['id'],'message','A follow-up');done=self.brain.detail(r['id'])
        self.assertEqual(done['calls'],4);self.assertEqual(done['status'],'paused');self.assertEqual(done['guidance'][-1]['text'],'A follow-up')
        self.brain.control(r['id'],'budget',calls=2);self.brain.start(r['id']);done=self.wait(r['id']);self.assertEqual(done['calls'],6)

    def test_proposal_cannot_read_peer_transcript_through_tools(self):
        r=self.room();self.brain.report(r['id']);m=r['members'][0]['id']
        for name in ('transcript.json','reports/latest.md'):
            with self.assertRaises(ValueError):workbench(self.brain,r['id'],m,{'action':'read_file','path':str(self.brain.path(r['id'])/'shared'/name)})


    def test_switch_to_user_mode_during_proposals_waits_without_auto_discussion(self):
        entered=threading.Barrier(3);release=threading.Event();original=self.brain.runner_factory
        class Runner:
            def run(inner,prompt,timeout,stop):
                c=json.loads(prompt.split('\n\n',1)[1])
                if c['phase']=='proposal':entered.wait(timeout=2);release.wait(2)
                return original().run(prompt,timeout,stop)
            def close(inner):pass
        self.brain.runner_factory=lambda *_:Runner()
        r=self.room();self.brain.start(r['id']);entered.wait(timeout=2)
        self.brain.control(r['id'],'settings',participation='agent_and_user');release.set();done=self.wait(r['id'])
        self.assertEqual(done['calls'],2);self.assertEqual(done['status'],'waiting_user')

    def test_old_interventions_migrate_once_and_runs_keep_topic_identity(self):
        from ros.brainstorm import Brainstorm
        r=self.room();r['guidance']=[{'id':'old','text':'Earlier question','target':'','delivery':{},'at':'2026-10-20T10:00:00.000+00:00'}];r['cycle']=1
        self.brain.save(r)
        migrated=Brainstorm(self.store,self.library, self.brain.runner_factory)
        again=Brainstorm(self.store,self.library, self.brain.runner_factory)
        entries=again.entries(r['id']);self.assertEqual(len([e for e in entries if e['phase']=='user']),1)
        key=again.entry(r['id'],r['members'][0]['id'],'run',0,'running',{})
        again.finish_entry(key,'completed',{'output':'ok'})
        self.assertEqual(again.entries(r['id'])[-1]['payload']['cycle'],1)
        self.assertIn('实际脚本运行：1',again.report(r['id']))
        migrated.close();again.close()

    def test_active_session_cannot_be_deleted(self):
        entered=threading.Event()
        class Runner:
            def run(inner,prompt,timeout,stop):entered.set();stop.wait(2);raise RuntimeError('stopped')
            def close(inner):pass
        self.brain.runner_factory=lambda *_:Runner()
        r=self.room();self.brain.start(r['id']);self.assertTrue(entered.wait(1))
        with self.assertRaises(ValueError):self.brain.control(r['id'],'delete')
        self.brain.control(r['id'],'pause');self.wait(r['id']);self.brain.control(r['id'],'delete')
        self.assertEqual(len(self.brain.list(True)),1)


del Fixture
