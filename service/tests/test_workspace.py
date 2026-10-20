import json, tempfile, threading, unittest, sqlite3
from pathlib import Path
from ros.store import Workspace,Conflict
from ros.library import Library,digest
from ros.agent import Agent
from researchos.store import Store

class WorkspaceTests(unittest.TestCase):
    def setUp(self):
        self.temp=tempfile.TemporaryDirectory();self.base=Path(self.temp.name);self.w=Workspace(self.base/'state');self.lib=Library(self.w)
        self.source=self.base/'notes';self.source.mkdir();self.root=self.w.root_add(self.source,'notes')
    def tearDown(self):self.temp.cleanup()
    def record(self,kind='idea',**kw):return self.w.put(dict(kind=kind,title='表示对齐',body='protein peptide embeddings',**kw))
    def test_discussion_delete_restore(self):
        session=self.w.session('Unique discussion')
        self.w.message(session['id'],'user','unique_discussion_evidence')
        self.w.delete_session(session['id'])
        self.assertFalse(self.w.state()['sessions'])
        self.assertEqual(self.w.search('unique_discussion_evidence'),[])
        self.assertEqual(len(self.w.messages(session['id'])),1)
        self.w.restore_session(session['id'])
        self.assertEqual(self.w.state()['sessions'][0]['id'],session['id'])
        self.assertEqual(len(self.w.search('unique_discussion_evidence')),1)
    def test_running_discussion_cannot_be_deleted(self):
        session=self.w.session()
        with self.w.db() as db:db.execute("UPDATE sessions SET status='running' WHERE id=?",(session['id'],))
        with self.assertRaises(ValueError):self.w.delete_session(session['id'])
    def test_project_progress_survives_updates(self):
        project=self.record('project',data={'summary':'Test overview','progress_summary':'Controls are ready'},status='testing')
        self.assertEqual(self.w.object(project['id'])['data']['progress_summary'],'Controls are ready')
        self.w.put({**project,'status':'done'},id=project['id'])
        self.assertEqual(self.w.object(project['id'])['data']['summary'],'Test overview')
    def test_reasoning_effort_reaches_turn(self):
        a=Agent(self.w,self.lib,Store(self.base/'legacy'));session=self.w.session()
        a.active[session['id']]={'memory':False};a.start=lambda:None
        calls=[]
        def rpc(method,params):
            calls.append((method,params))
            return {'thread':{'id':'fake-thread'}} if method=='thread/start' else {'turn':{'id':'fake-turn'}}
        a.rpc=rpc
        a._begin(session,'hello',[],'fixture',False,False,'high')
        params=next(p for m,p in calls if m=='turn/start')
        self.assertEqual(params['effort'],'high');self.assertEqual(params['model'],'fixture')
        self.assertEqual(params['sandboxPolicy']['type'],'readOnly')
    def test_invalid_effort_does_not_create_message(self):
        a=Agent(self.w,self.lib,Store(self.base/'legacy'));session=self.w.session()
        a.models=[{'id':'fixture','supportedReasoningEfforts':[{'reasoningEffort':'high'}]}]
        with self.assertRaises(ValueError):a.turn(session['id'],'hello',model='fixture',effort='unsupported')
        self.assertEqual(self.w.messages(session['id']),[])
    def test_compact_catalog_never_walks_repository(self):
        from ros.catalog import build
        from unittest.mock import patch
        repo=self.base/'repos';repo.mkdir();project=repo/'example';project.mkdir()
        (project/'README.md').write_text('# Example\nA molecular representation project using reproducible controls and careful evaluation.')
        (project/'deep').mkdir();(project/'deep'/'large-data.txt').write_text('do not index me')
        root=self.w.root_add(repo,'repo');self.lib.scan(root)
        before=len(self.w.rows('SELECT id FROM documents'))
        with patch('os.walk',side_effect=AssertionError('No recursive scan')):
            result=build(self.w)
        self.assertEqual(result['entries'],1)
        self.assertEqual(len(self.w.rows('SELECT id FROM documents')),before)
        self.assertIn('molecular representation',self.w.browse('repo')['documents'][0]['summary'])
        self.assertNotIn('do not index me',Path(result['path']).read_text())
    def test_resource_sort_uses_live_timestamps(self):
        import os
        a=self.source/'Alpha.md';b=self.source/'Zulu.md'
        a.write_text('alpha');b.write_text('zulu');self.lib.scan(self.root)
        os.utime(a,(100,100));os.utime(b,(200,200))
        self.assertEqual(self.w.browse('notes',sort='name_asc')['documents'][0]['title'],'Alpha')
        self.assertEqual(self.w.browse('notes',sort='name_desc')['documents'][0]['title'],'Zulu')
        self.assertEqual(self.w.browse('notes',sort='modified_desc')['documents'][0]['title'],'Zulu')
        self.assertEqual(self.w.browse('notes',sort='modified_asc')['documents'][0]['title'],'Alpha')
        with self.assertRaises(ValueError):self.w.browse('notes',sort='invalid')
    def test_persistence(self):
        o=self.record();self.assertEqual(Workspace(self.w.root).object(o['id'])['title'],'表示对齐')
    def test_revision_conflict(self):
        o=self.record();self.w.put({**o,'body':'new'},id=o['id'])
        with self.assertRaises(Conflict):self.w.put(o,id=o['id'])
    def test_reference_validation(self):
        with self.assertRaises(ValueError):self.record(project_id='missing')
    def test_project_delete_restriction(self):
        p=self.record('project');self.record(project_id=p['id'])
        with self.assertRaises(ValueError):self.w.delete(p['id'],p['revision'])
    def test_search_chinese_and_english(self):
        self.record();self.assertEqual(len(self.w.search('表示对齐')),1);self.assertEqual(len(self.w.search('embeddings')),1)
    def test_scope(self):
        p=self.record('project');self.record(project_id=p['id']);self.record()
        self.assertEqual(len(self.w.search('embeddings',p['id'])),2)
    def test_memory_requires_source(self):
        with self.assertRaises(ValueError):self.record('memory')
    def test_forget(self):
        o=self.record('memory',data={'source':'session:fixture'});self.w.delete(o['id'],o['revision'])
        with self.assertRaises(ValueError):self.record('memory',data={'source':'session:fixture'})
    def test_superseded_memory_not_searched(self):
        self.record('memory',data={'source':'fixture'},status='superseded');self.assertEqual(self.w.search('embeddings'),[])
    def test_index_move_preserves_id(self):
        p=self.source/'old.md';p.write_text('seed contrast test');self.lib.scan(self.root);id=self.w.search('contrast')[0]['id']
        p.rename(self.source/'new.md');self.lib.scan(self.root);self.assertEqual(self.w.search('contrast')[0]['id'],id)
    def test_index_delete_unavailable(self):
        p=self.source/'x.md';p.write_text('unique_word');self.lib.scan(self.root);p.unlink();self.lib.scan(self.root);self.assertEqual(self.w.search('unique_word'),[])
    def test_path_escape(self):
        with self.assertRaises(ValueError):self.w.allowed_path(self.base/'secret')
    def test_symlink_not_indexed(self):
        p=self.base/'private.md';p.write_text('do_not_index');(self.source/'link.md').symlink_to(p);self.lib.scan(self.root);self.assertEqual(self.w.search('do_not_index'),[])
    def test_external_edit_conflict(self):
        p=self.source/'x.md';p.write_text('old');self.lib.scan(self.root);d=self.w.search('old')[0];hash=digest(p);p.write_text('external')
        with self.assertRaises(ValueError):self.lib.save_text(d['id'],'overwrite',hash)
        self.assertEqual(p.read_text(),'external')
    def test_read_latest_text(self):
        p=self.source/'x.md';p.write_text('old');self.lib.scan(self.root);d=self.w.search('old')[0];p.write_text('new');self.assertEqual(self.lib.read(d['id'])['text'],'new')
    def test_disconnect_hides_index(self):
        (self.source/'x.md').write_text('hide_this');self.lib.scan(self.root);self.w.root_remove(self.root['id']);self.assertEqual(self.w.search('hide_this'),[])
    def test_dataset_directory_only(self):
        root=self.w.root_add(self.source,'data');p=self.source/'tensor.pt';p.write_bytes(b'\x00\xff'*30)
        self.lib.scan(root);self.assertEqual(self.w.search('tensor'),[])
        records=self.w.rows('SELECT * FROM documents');self.assertEqual(len(records),1)
        self.assertTrue(self.lib.read(records[0]['id'])['catalog_only'])
    def test_backup_restore(self):
        o=self.record();backup=self.w.backup();self.w.put({**o,'body':'changed'},id=o['id']);self.w.restore(backup);self.assertIn('embeddings',self.w.object(o['id'])['body'])
        with self.assertRaises(Conflict):self.w.put(o,id=o['id'])
    def test_restore_path_rejected(self):
        with self.assertRaises(ValueError):self.w.restore(self.base/'arbitrary.db')
    def test_audit(self):
        o=self.record();self.w.put({**o,'body':'new'},id=o['id']);self.assertEqual(len(self.w.rows('SELECT * FROM audit')),2)
    def test_relation(self):
        a=self.record();b=self.record();self.w.link(a['id'],b['id']);self.w.link(a['id'],b['id']);self.assertEqual(len(self.w.rows('SELECT * FROM edges')),1)
    def test_memory_tool_disabled(self):
        a=Agent(self.w,self.lib,Store(self.base/'legacy'));s=self.w.session()
        with self.assertRaises(ValueError):a.tool('remember',{'title':'test','body':'value','classification':'inference'},s['id'],'call1')
    def test_tool_write_idempotent(self):
        a=Agent(self.w,self.lib,Store(self.base/'legacy'));s=self.w.session();args={'kind':'plan','title':'test','body':'criteria'}
        x=a.tool('save_record',args,s['id'],'call1');y=a.tool('save_record',args,s['id'],'call1');self.assertEqual(x['id'],y['id'])
    def test_tool_update_requires_revision(self):
        a=Agent(self.w,self.lib,Store(self.base/'legacy'));s=self.w.session();o=self.record()
        with self.assertRaises(Conflict):a.tool('save_record',{'id':o['id'],'kind':'idea','title':'new','body':'x'},s['id'],'call2')
    def test_interrupted_recovery(self):
        s=self.w.session();self.w.message(s['id'],'assistant','partial','streaming');Workspace(self.w.root);self.assertEqual(self.w.messages(s['id'])[0]['status'],'interrupted')
    def test_pdf_page_and_image(self):
        import pymupdf
        p=self.source/'paper.pdf';doc=pymupdf.open();doc.new_page().insert_text((50,50),'Evidence 731');doc.save(p);doc.close();self.lib.scan(self.root)
        d=self.w.search('Evidence')[0];self.assertIn('731',self.lib.read(d['id'],1)['text']);self.assertTrue(self.lib.page_image(d['id'],1).startswith('data:image/png'))
        with self.assertRaises(ValueError):self.lib.read(d['id'],2)
    def test_pdf_version_not_silently_replaced(self):
        import pymupdf
        p=self.source/'paper.pdf'
        def write(text):
            d=pymupdf.open();d.new_page().insert_text((50,50),text);d.save(p);d.close()
        write('first_version');self.lib.scan(self.root);old=self.w.search('first_version')[0]['id'];write('second_version');self.lib.scan(self.root);new=self.w.search('second_version')[0]['id'];self.assertNotEqual(old,new)
        with self.assertRaises(ValueError):self.lib.read(old,1)

if __name__=='__main__':unittest.main()
