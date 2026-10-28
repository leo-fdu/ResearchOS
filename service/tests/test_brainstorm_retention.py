import json, unittest, shutil
from datetime import datetime,timedelta,timezone
from test_brainstorm import BrainstormTests as Fixture

class RetentionAndLinksTests(unittest.TestCase):
 setUp=Fixture.setUp
 tearDown=Fixture.tearDown
 room=Fixture.room
 def test_only_expired_deleted_rooms_and_own_files_are_removed(self):
  now=datetime(2030,1,31,tzinfo=timezone.utc)
  expired=self.room();fresh=self.room();live=self.room();restored=self.room()
  for room,days in [(expired,30),(fresh,29),(restored,40)]:
   room['deleted_at']=(now-timedelta(days=days)).isoformat();self.brain.save(room)
  self.brain.control(restored['id'],'restore')
  own=self.brain.path(expired['id']);(own/'test.txt').write_text('private')
  external=self.root/'original.txt';external.write_text('original');(own/'original-link').symlink_to(external)
  self.brain.entry(expired['id'],expired['members'][0]['id'],'proposal',0,'completed',{'text':'old'})
  self.assertEqual(self.brain.cleanup_deleted(now),[expired['id']])
  self.assertFalse(own.exists());self.assertEqual(external.read_text(),'original')
  self.assertEqual(self.brain.entries(expired['id']),[])
  for room in [fresh,live,restored]:self.assertEqual(self.brain.room(room['id'])['id'],room['id'])
  self.assertEqual(self.brain.cleanup_deleted(now),[])
 def test_active_room_and_malformed_timestamp_are_not_removed(self):
  r=self.room();r['deleted_at']='bad';self.brain.save(r);self.assertEqual(self.brain.cleanup_deleted(),[])
  r['deleted_at']='2000-01-01T00:00:00+00:00';self.brain.save(r);self.brain.active[r['id']]={}
  try:self.assertEqual(self.brain.cleanup_deleted(),[])
  finally:self.brain.active.pop(r['id'])
 def test_expiry_is_exposed_and_room_symlink_does_not_delete_target(self):
  r=self.room();r['deleted_at']='2000-01-01T00:00:00+00:00';self.brain.save(r)
  self.assertEqual(self.brain.list(True)[0]['purge_after'],'2000-01-31T00:00:00+00:00')
  path=self.brain.path(r['id']);shutil.rmtree(path)
  external=self.root/'external';external.mkdir();(external/'keep').write_text('keep');path.symlink_to(external,target_is_directory=True)
  self.brain.cleanup_deleted();self.assertTrue((external/'keep').exists());self.assertFalse(path.is_symlink())
 def test_expired_rooms_are_cleaned_on_next_startup(self):
  r=self.room();r['deleted_at']='2000-01-01T00:00:00+00:00';self.brain.save(r)
  folder=self.brain.path(r['id']);self.brain.close()
  from ros.brainstorm import Brainstorm
  self.brain=Brainstorm(self.store,self.library)
  self.assertEqual(self.brain.list(True),[])
  self.assertFalse(folder.exists())
 def create_linked(self,**links):
  return self.brain.create({'topic':'Linked question','members':[{'runtime':'codex','model':'fixture'},{'runtime':'pi','provider':'fixture','model':'fixture'}],**links})
 def test_idea_project_and_prompt_context(self):
  project=self.store.put({'kind':'project','title':'Project','body':'Project context'})
  idea=self.store.put({'kind':'idea','title':'Idea','body':'Pending hypothesis','project_id':project['id']})
  r=self.create_linked(idea_id=idea['id']);self.assertEqual(r['project_id'],project['id']);self.assertEqual(r['idea_id'],idea['id'])
  context=json.loads(self.brain.prompt(r['id'],r['members'][0],'proposal',0).split('\n\n',1)[1])
  self.assertEqual([o['id'] for o in context['linked_context']],[project['id'],idea['id']])
  self.assertIn('No project filter',context['resources'])
  other=self.store.put({'kind':'project','title':'Other'})
  with self.assertRaisesRegex(ValueError,'another project'):self.create_linked(idea_id=idea['id'],project_id=other['id'])
  with self.assertRaisesRegex(ValueError,'Idea not found'):self.create_linked(idea_id=project['id'])
  self.assertEqual(self.create_linked()['idea_id'],'')
del Fixture
