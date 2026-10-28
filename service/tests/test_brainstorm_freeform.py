import json,unittest
from test_brainstorm import BrainstormTests as Fixture
from ros.brainstorm import RULES,response_object
class FreeformTests(unittest.TestCase):
 setUp=Fixture.setUp
 tearDown=Fixture.tearDown
 room=Fixture.room
 wait=Fixture.wait
 def natural_runner(self):
  test=self
  class Runner:
   def run(self,prompt,timeout,stop):
    c=json.loads(prompt.split('\n\n',1)[1]);test.prompts.append(c)
    if c['phase']=='report':return '# 讨论报告\n\n## 独立提案概要\n双方问候。\n\n## 讨论结果\n完成招呼。\n\n## 验证方法与细节\n无研究验证任务。\n\n## 共识与分歧\n没有提出实质性研究观点。'
    return '你好！很高兴一起讨论。\n\n有问题直接说就好。'
   def close(self):pass
  return lambda *_:Runner()
 def test_markdown_with_code_braces_is_preserved(self):
  text='## Example\n```python\nx = {"a": 1}\n```\nNo JSON protocol.'
  self.assertEqual(response_object(text)['text'],text)
  self.assertNotIn('weakness',response_object(text))
 def test_casual_turn_succeeds_without_fields_and_context_is_prose(self):
  self.brain.runner_factory=self.natural_runner();r=self.room(participation='agent_and_user');self.brain.start(r['id']);done=self.wait(r['id'])
  self.assertEqual(done['status'],'waiting_user');self.assertEqual(done['calls'],2)
  entries=[e for e in done['entries'] if e['phase']=='proposal'];self.assertTrue(all(e['status']=='completed' for e in entries))
  self.assertTrue(all(e['payload']['response']['format']=='prose' for e in entries))
  self.brain.control(r['id'],'message','继续');self.wait(r['id'])
  c=[p for p in self.prompts if p['phase']=='reply'][0]
  self.assertTrue(all('text' in h and 'response' not in h for h in c['history']))
  self.assertNotIn('MUST be one JSON',RULES)
 def test_report_is_separate_and_uses_one_remaining_turn(self):
  self.brain.runner_factory=self.natural_runner();r=self.room(mode='discuss',max_rounds=1);self.brain.start(r['id']);done=self.wait(r['id'])
  self.assertEqual(done['calls'],7);self.assertEqual(done['status'],'completed')
  phases=[p['phase'] for p in self.prompts];self.assertEqual(phases.count('report'),1)
  self.assertIn('# 讨论报告',done['report']);self.assertNotIn('Weakness',done['report'])
 def test_manual_report_without_replaying_participants(self):
  self.brain.runner_factory=self.natural_runner();r=self.room(participation='agent_and_user');self.brain.start(r['id']);self.wait(r['id'])
  self.brain.control(r['id'],'summarize');done=self.wait(r['id'])
  self.assertEqual(done['calls'],3);self.assertEqual(self.prompts[-1]['phase'],'report')
  self.assertIn('# 讨论报告',done['report'])
 def test_no_budget_report_is_explicitly_an_excerpt(self):
  self.brain.runner_factory=self.natural_runner();r=self.room(mode='discuss',max_calls=4);self.brain.start(r['id']);done=self.wait(r['id'])
  self.assertEqual(done['calls'],4);self.assertIn('讨论摘录',done['report']);self.assertNotIn('# 讨论报告',done['report'])
 def test_old_report_is_not_reused_after_new_guidance(self):
  self.brain.runner_factory=self.natural_runner();r=self.room(participation='agent_and_user');self.brain.start(r['id']);self.wait(r['id'])
  self.brain.control(r['id'],'summarize');self.wait(r['id']);self.brain.control(r['id'],'guidance','New constraint')
  self.assertNotIn('# 讨论报告',self.brain.report(r['id']))
 def test_model_name_mentions_keep_legacy_names_working(self):
  r=self.brain.create({'topic':'names','members':[{'runtime':'codex','model':'gpt-6-astra','name':'Member 1'},{'runtime':'pi','provider':'fixture','model':'deepseek-flash','model_name':'DeepSeek Flash'}]})
  a,b=r['members'];self.assertEqual(b['name'],'deepseek-flash')
  for alias,mid in [('gpt-6-astra',a['id']),('Member 1',a['id']),('DeepSeek Flash',b['id'])]:
   self.brain.control(r['id'],'guidance','@'+alias+' hello')
   self.assertEqual(self.brain.room(r['id'])['guidance'][-1]['mentions'],[mid])
del Fixture
