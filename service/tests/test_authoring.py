import tempfile,unittest,json
from pathlib import Path
from unittest.mock import patch
from ros.store import Workspace,Conflict
from ros.library import Library
from ros.agent import Agent
from ros import authoring
from researchos.store import Store

class AuthoringTests(unittest.TestCase):
 def setUp(self):
  self.tmp=tempfile.TemporaryDirectory();self.base=Path(self.tmp.name).resolve();self.w=Workspace(self.base/'state');self.lib=Library(self.w)
  self.notes=self.base/'notes';self.notes.mkdir();self.root=self.w.root_add(self.notes,'notes')
  self.agent=Agent(self.w,self.lib,Store(self.base/'legacy'));self.sid=self.w.session()['id']
 def tearDown(self):self.tmp.cleanup()
 def record(self,kind='project',**kw):return self.w.put(dict(kind=kind,title='Research',body='Original analysis',**kw))
 def test_journal_remove_attachment_edit_and_delete(self):
  owner=self.record();image=self.base/'figure.png';image.write_bytes(b'fixture')
  note=self.record('note',data={'entry_type':'experiment_log','owner_id':owner['id'],'attachments':[{'path':str(image)}]})
  md=Path(authoring.markdown(self.w,note['id'])['path']);md.write_text('Edited in Typora')
  current=authoring.journals(self.w,owner['id'])[0]
  updated=self.w.put({**current,'data':{**current['data'],'attachments':[]}},id=note['id'])
  self.assertEqual(updated['data']['attachments'],[]);self.assertEqual(md.read_text(),'Edited in Typora')
  self.w.delete(updated['id'],updated['revision'])
  authoring.sync(self.w)
  self.assertEqual(authoring.journals(self.w,owner['id']),[])
  self.assertIsNone(self.w.object(note['id']));self.assertTrue(image.exists())
  self.assertFalse(self.w.search('Edited in Typora'))

 def paper(self):
  import pymupdf
  path=self.notes/'Test.pdf';pdf=pymupdf.open();pdf.new_page().insert_text((50,50),'Paper evidence');pdf.save(path);pdf.close();self.lib.scan(self.root)
  return self.w.one("SELECT * FROM documents WHERE kind='pdf'")
 def test_paper_note_is_file_linked_and_not_duplicated(self):
  paper=self.paper();note=self.record('note',data={'paper_id':paper['id']})
  file=authoring.markdown(self.w,note['id']);self.assertEqual(Path(file['path']).parent,self.notes/'paper')
  self.assertEqual(Path(file['path']).read_text(),note['body'])
  self.assertTrue(self.w.one('SELECT id FROM edges WHERE source=? AND target=?',(note['id'],paper['id'])))
  self.lib.scan(self.root)
  self.assertFalse(self.w.one('SELECT id FROM documents WHERE path=? AND available=1',(file['path'],)))
  graph=authoring.graph(self.w);self.assertEqual(sum(n['id']==note['id'] for n in graph['nodes']),1)
 def test_notes_metadata_hidden_categories_preserved(self):
  for folder in ['blog','concepts','paper']:
   p=self.notes/folder;p.mkdir();(p/'Entry.md').write_text(folder+' example')
  (self.notes/'AGENTS.md').write_text('terminal instructions');(self.notes/'INDEX.md').write_text('terminal index')
  self.lib.scan(self.root)
  self.assertEqual(self.w.browse('notes')['total'],3)
  self.assertEqual(self.w.browse('notes',category='blog')['total'],1)
  self.assertEqual(self.w.search('terminal'),[])
  self.assertTrue((self.notes/'AGENTS.md').exists())
 def test_external_edit_updates_revision_and_blocks_stale_save(self):
  obj=self.record();file=authoring.markdown(self.w,obj['id']);old=self.w.object(obj['id'])
  Path(file['path']).write_text('Typora saved unique_marker')
  with self.assertRaises(Conflict):self.w.put({**old,'body':'stale overwrite'},id=obj['id'])
  self.assertEqual(self.w.object(obj['id'])['body'],'Typora saved unique_marker')
  self.assertTrue(self.w.search('unique_marker'))
  fresh=self.w.object(obj['id']);self.w.put({**fresh,'body':'Assistant next edit'},id=obj['id'])
  self.assertEqual(Path(file['path']).read_text(),'Assistant next edit')
  self.assertTrue(list((self.w.root/'backups'/'markdown').glob('*')))
 def test_file_conflict_rolls_back_record_transaction(self):
  obj=self.record('note');old=self.w.object(obj['id']);file=authoring.markdown(self.w,obj['id'])
  Path(file['path']).write_text('User external change')
  with patch('ros.authoring.sync'):
   with self.assertRaises(Conflict):self.w.put({**old,'body':'overwrite'},id=obj['id'])
  self.assertEqual(self.w.object(obj['id']),old)
  self.assertEqual(Path(file['path']).read_text(),'User external change')
 def test_existing_assistant_tools_read_write_markdown(self):
  p=self.notes/'Existing.md';p.write_text('Before');self.lib.scan(self.root);doc=self.w.one('SELECT * FROM documents')
  value=self.agent.tool('read_record',{'id':'researchos://markdown/'+doc['id']},self.sid,'r')
  args=dict(kind='note',title='Markdown edit',body='After',data=dict(operation='edit_markdown',target_id=doc['id'],expected_hash=value['hash']))
  saved=self.agent.tool('save_record',args,self.sid,'w')
  self.assertEqual(saved['text'],'After');self.assertEqual(p.read_text(),'After');self.assertFalse(self.w.rows('SELECT * FROM objects'))
  with self.assertRaises(Conflict):self.agent.tool('save_record',args,self.sid,'again')
 def test_note_category_move_keeps_identity_and_link(self):
  obj=self.record('note',data={'category':'concepts'});file=Path(authoring.markdown(self.w,obj['id'])['path'])
  obj=self.w.object(obj['id']);self.w.put({**obj,'data':{**obj['data'],'category':'blog'}},id=obj['id'])
  moved=Path(authoring.markdown(self.w,obj['id'])['path']);self.assertEqual(moved.parent,self.notes/'blog');self.assertFalse(file.exists());self.assertEqual(moved.read_text(),obj['body'])
 def test_journals_append_and_copy_attachments_for_project_and_idea(self):
  project=self.record();idea=self.record('idea',project_id=project['id']);data=self.notes/'results.csv';data.write_text('seed,score\n1,0.81')
  for owner in [project,idea]:
   for i in range(2):
    entry=self.agent.tool('save_record',dict(kind='note',title='Run '+str(i),body='Observed result, not proven mechanism',data={'entry_type':'experiment_log','owner_id':owner['id'],'attachments':[{'path':str(data)}]}),self.sid,owner['id']+str(i))
    self.assertEqual(entry['project_id'],project['id']);attachment=entry['data']['attachments'][0]
    self.assertEqual(attachment['mode'],'copy');self.assertNotEqual(attachment['path'],str(data));self.assertEqual(Path(attachment['path']).read_text(),data.read_text())
    current=self.w.object(entry['id']);updated=self.w.put({**current,'body':'Revised analysis'},id=entry['id'])
    self.assertEqual(updated['data']['attachments'],entry['data']['attachments'])
   self.assertEqual(len(authoring.journals(self.w,owner['id'])),2)
  data.unlink();self.assertTrue(Path(attachment['path']).exists())
  with self.assertRaises(ValueError):self.w.delete(idea['id'],idea['revision'])
 def test_figure_captions_survive_copy_assistant_read_and_edit(self):
  owner=self.record();figure=self.notes/'plot.png';figure.write_bytes(b'fixture')
  caption='Validation loss, seed 1; a single run is inconclusive.'
  entry=self.agent.tool('save_record',dict(kind='note',title='Run with figure',body='Analysis',data={'entry_type':'experiment_log','owner_id':owner['id'],'attachments':[{'path':str(figure),'caption':caption}]}),self.sid,'figure')
  saved=entry['data']['attachments'][0];self.assertEqual(saved['caption'],caption)
  figure.unlink();self.assertTrue(Path(saved['path']).exists())
  updated=self.w.put({**entry,'data':{**entry['data'],'attachments':[{**saved,'caption':'Updated interpretation'}]}},id=entry['id'])
  self.assertEqual(updated['data']['attachments'][0]['path'],saved['path'])
  self.assertEqual(authoring.journals(self.w,owner['id'])[0]['data']['attachments'][0]['caption'],'Updated interpretation')
  with self.assertRaises(ValueError):self.w.put({**updated,'data':{**updated['data'],'attachments':[{**saved,'caption':123}]}},id=entry['id'])
 def test_journal_rejects_invalid_owner_and_unapproved_assistant_path(self):
  with self.assertRaises(ValueError):self.record('note',data={'entry_type':'experiment_log','owner_id':'missing'})
  owner=self.record();private=self.base/'secret.txt';private.write_text('sensitive')
  with self.assertRaises(ValueError):self.agent.tool('save_record',dict(kind='note',title='Bad attachment',body='x',data={'entry_type':'experiment_log','owner_id':owner['id'],'attachments':[{'path':str(private)}]}),self.sid,'bad')
 def test_folder_attachment_remains_reference(self):
  owner=self.record();entry=self.record('note',data={'entry_type':'experiment_log','owner_id':owner['id'],'attachments':[{'path':str(self.notes)}]})
  self.assertEqual(entry['data']['attachments'][0]['mode'],'reference')
 def test_repo_and_dataset_descriptions_survive_rescan_without_recursion(self):
  for kind in ['repo','data']:
   folder=self.base/kind;folder.mkdir();sub=folder/'Example';sub.mkdir();readme=sub/'README.md';readme.write_text('Existing description')
   root=self.w.root_add(folder,kind)
   with patch('os.walk',side_effect=AssertionError('No recursive indexing')):
    self.lib.scan(root);doc=self.w.one('SELECT * FROM documents WHERE root_id=?',(root['id'],));value=authoring.markdown(self.w,doc['id'])
    self.assertEqual(value['text'],'Existing description')
    authoring.save_markdown(self.w,doc['id'],'Improved description',value['hash']);self.lib.scan(root)
    self.assertEqual(self.lib.read(doc['id'])['text'],'Improved description');self.assertEqual(readme.read_text(),'Improved description')
 def test_symlink_parent_cannot_redirect_edits(self):
  (self.notes/'concepts').symlink_to(self.base,target_is_directory=True)
  with self.assertRaises(ValueError):self.record('note',data={'category':'concepts'})
  self.assertFalse(self.w.rows('SELECT * FROM objects'))
 def test_disconnected_bound_file_cannot_be_written(self):
  file=self.notes/'test.md';file.write_text('Original');self.lib.scan(self.root);doc=self.w.one('SELECT * FROM documents');value=authoring.markdown(self.w,doc['id']);self.w.root_remove(self.root['id'])
  with self.assertRaises(ValueError):authoring.save_markdown(self.w,doc['id'],'Unsafe',value['hash'])
  self.assertEqual(file.read_text(),'Original')
 def test_all_seven_kinds_link_and_graph_excludes_deleted_room(self):
  project=self.record();idea=self.record('idea',project_id=project['id']);note=self.record('note');paper=self.paper()
  for kind in ['repo','data']:
   path=self.base/kind;path.mkdir();self.lib.scan(self.w.root_add(path,kind))
  with self.w.db() as db:
   db.execute('CREATE TABLE brainstorm_rooms(id TEXT PRIMARY KEY,payload TEXT)')
   db.execute('INSERT INTO brainstorm_rooms VALUES(?,?)',('room',json.dumps(dict(id='room',topic='Debate',project_id=project['id'],idea_id=idea['id']))))
  graph=authoring.graph(self.w);self.assertEqual({n['kind'] for n in graph['nodes']},{'project','idea','note','paper','repo','data','brainstorm'})
  ids=[n['id'] for n in graph['nodes']]
  for i in ids:
   for j in ids:
    if i!=j:self.agent.tool('link_records',dict(source=i,target=j),self.sid,i+j)
  self.assertGreaterEqual(len(authoring.graph(self.w)['edges']),len(ids)*(len(ids)-1))
  with self.w.db() as db:db.execute('UPDATE brainstorm_rooms SET payload=?',(json.dumps(dict(id='room',topic='Deleted',deleted_at='now')),))
  self.assertNotIn('room',[n['id'] for n in authoring.graph(self.w)['nodes']])
  with self.assertRaises(ValueError):self.w.link('room',project['id'])
 def test_restore_reconciles_authored_file_with_database(self):
  obj=self.record('note');file=authoring.markdown(self.w,obj['id']);backup=self.w.backup()
  current=self.w.object(obj['id']);self.w.put({**current,'body':'Newer edit'},id=obj['id']);self.w.restore(backup)
  self.w.state();self.assertEqual(self.w.object(obj['id'])['body'],'Original analysis');self.assertEqual(Path(file['path']).read_text(),'Original analysis')
 def test_deleted_note_does_not_reappear_as_imported_document(self):
  obj=self.record('note');file=authoring.markdown(self.w,obj['id']);current=self.w.object(obj['id']);self.w.delete(obj['id'],current['revision']);self.lib.scan(self.root)
  self.assertFalse(self.w.object(obj['id']));self.assertFalse(self.w.one('SELECT id FROM documents WHERE path=? AND available=1',(file['path'],)))
 def test_authoring_guide_sent_to_existing_thread(self):
  session=self.w.session();session['thread_id']='existing';self.agent.active[session['id']]={'memory':False};self.agent.start=lambda:None;calls=[]
  def rpc(method,params):calls.append((method,params));return {'turn':{'id':'turn'}}
  self.agent.rpc=rpc;self.agent._begin(session,'Append an experiment log',[],'fixture',False,False,'low')
  turn=next(params for method,params in calls if method=='turn/start')
  self.assertIn('researchos://markdown/',json.dumps(turn));self.assertIn('experiment_log',json.dumps(turn));self.assertIn('CSV and TSV attachments render',json.dumps(turn))

if __name__=='__main__':unittest.main()
