import json, tempfile, threading, unittest, urllib.request, urllib.error
from pathlib import Path
from unittest.mock import patch
from ros.server import Server
from ros.store import Workspace
from ros.library import Library

class AdditionalWorkspaceTests(unittest.TestCase):
    def setUp(self):
        self.tmp=tempfile.TemporaryDirectory();self.base=Path(self.tmp.name);self.w=Workspace(self.base/'state')
    def tearDown(self):self.tmp.cleanup()
    def test_launch_refreshes_connected_roots_when_polling_disabled(self):
        folder=self.base/'repos';folder.mkdir()
        root=self.w.root_add(str(folder),'repo')
        self.w.set_setting('auto_index',False)
        self.w.set_setting('initial_connections_loaded',True)
        with patch.object(Library,'start',return_value={'job_id':'fixture'}) as start:
            server=Server(self.w.root)
            try:start.assert_called_once_with(root['id'])
            finally:server.server_close()
    def test_delete_has_recovery_snapshot(self):
        o=self.w.put({'kind':'idea','title':'recover','body':'recoverable'})
        self.w.delete(o['id'],1);backups=list((self.w.root/'backups').glob('*.sqlite3'));self.assertEqual(len(backups),1)
        self.w.restore(backups[0]);self.assertEqual(self.w.object(o['id'])['body'],'recoverable')
    def test_forgotten_session_cannot_rephrase_memory(self):
        o=self.w.put({'kind':'memory','title':'old','body':'value','data':{'source':'session:x'}},source='session:x')
        self.w.delete(o['id'],1)
        with self.assertRaises(ValueError):self.w.put({'kind':'memory','title':'different','body':'paraphrase','data':{'source':'session:x'}},source='session:x')
    def test_discussion_search(self):
        s=self.w.session();self.w.message(s['id'],'user','historical evidence 932')
        r=self.w.search('932');self.assertEqual(r[0]['source_type'],'session');self.assertEqual(r[0]['id'],s['id'])
    def test_root_relation_scope(self):
        rootdir=self.base/'notes';rootdir.mkdir();(rootdir/'a.md').write_text('scope932')
        root=self.w.root_add(rootdir,'notes');Library(self.w).scan(root)
        p=self.w.put({'kind':'project','title':'project','body':''});self.w.link(p['id'],root['id'])
        self.assertEqual(len(self.w.search('scope932',p['id'])),1)
    def test_cancel_before_scan(self):
        folder=self.base/'files';folder.mkdir();root=self.w.root_add(folder,'notes');lib=Library(self.w);job=self.w.job('test');lib.cancel(job)
        with self.assertRaises(InterruptedError):lib.scan(root,job)
    def test_pdf_image_hash_guard(self):
        import pymupdf
        folder=self.base/'papers';folder.mkdir();path=folder/'a.pdf'
        d=pymupdf.open();d.new_page();d.save(path);d.close()
        root=self.w.root_add(folder,'papers');lib=Library(self.w);lib.scan(root);doc=self.w.rows('SELECT id FROM documents')[0]
        path.write_bytes(b'changed')
        with self.assertRaises(ValueError):lib.page_image(doc['id'],1)
    def test_catalog_is_shallow_and_uses_readme_paths(self):
        from unittest.mock import patch
        folder=self.base/'datasets';folder.mkdir()
        for name in ['first','second']:
            child=folder/name;child.mkdir();(child/'nested').mkdir()
            (child/'nested'/'unlistedstructure731.pdb').write_text('never index this')
        (folder/'first'/'README.md').write_text('do not duplicate this description')
        (folder/'link').symlink_to(folder/'first',target_is_directory=True)
        root=self.w.root_add(folder,'data');lib=Library(self.w)
        with patch('ros.library.os.walk',side_effect=AssertionError('recursive walk forbidden')),patch.object(Path,'open',side_effect=AssertionError('content read forbidden')):
            self.assertEqual(lib.scan(root)['entries'],2)
        records=self.w.rows('SELECT * FROM documents');self.assertEqual(len(records),2)
        self.assertTrue(any('README.md' in r['body'] for r in records))
        self.assertFalse(any('do not duplicate' in r['body'] for r in records))
        self.assertEqual(self.w.search('unlistedstructure731'),[])
        self.assertTrue(lib.read(records[0]['id'])['catalog_only'])
        (folder/'second').rename(folder/'renamed');lib.scan(root)
        self.assertEqual(self.w.browse('data')['total'],2)
    def test_retire_file_index_preserves_records_and_papers(self):
        rootdir=self.base/'repo';rootdir.mkdir();root=self.w.root_add(rootdir,'repo')
        with self.w.db() as db:
            db.execute('INSERT INTO documents VALUES(?,?,?,?,?,?,?,?,?,?,?,?)',('old',root['id'],str(rootdir/'source.py'),'source','repo','hash',0,1,'obsoletecache',1,0,''))
            db.execute('INSERT INTO search_index VALUES(?,?,?)',('old','source','obsoletecache'))
        idea=self.w.put({'kind':'idea','title':'keep','body':'authored research'})
        self.assertEqual(self.w.retire_file_catalogs(),1)
        self.assertIsNotNone(self.w.object(idea['id']))
        self.assertEqual(self.w.search('obsoletecache'),[])
        self.assertEqual(self.w.rows('SELECT * FROM documents'),[])
        self.assertEqual(self.w.retire_file_catalogs(),0)
    def test_new_documents_do_not_scan_fts_for_nonexistent_ids(self):
        from contextlib import contextmanager
        statements=[];original=self.w.db
        @contextmanager
        def traced(*args,**kwargs):
            with original(*args,**kwargs) as db:
                db.set_trace_callback(statements.append)
                yield db
        self.w.db=traced
        for kind,extension in [('notes','md'),('data','pdb')]:
            folder=self.base/kind;folder.mkdir()
            (folder/f'fresh.{extension}').write_text('fresh content')
            root=self.w.root_add(folder,kind);Library(self.w).scan(root)
        self.assertFalse([s for s in statements if s.startswith('DELETE FROM search_index WHERE id=')])
    def test_catalog_refresh_has_single_search_entry(self):
        folder=self.base/'structures';folder.mkdir()
        root=self.w.root_add(folder,'data');lib=Library(self.w);lib.scan(root)
        before=self.w.rows('SELECT id FROM documents')[0]['id']
        (folder/'README.md').write_text('existing description')
        self.assertEqual(lib.scan(root)['entries'],1)
        self.assertEqual(self.w.rows('SELECT id FROM documents')[0]['id'],before)
        self.assertEqual(len(self.w.rows('SELECT * FROM search_index WHERE id=?',(before,))),1)
    def test_parallel_roots_and_state_reads_complete(self):
        roots=[]
        for kind in ['notes','papers','repo','data']:
            folder=self.base/kind;folder.mkdir()
            for i in range(30):(folder/f'{i}.md').write_text('parallel fixture')
            roots.append(self.w.root_add(folder,kind))
        lib=Library(self.w);jobs=[lib.start(root['id'])['job_id'] for root in roots]
        import time
        deadline=time.monotonic()+15
        while time.monotonic()<deadline:
            self.w.state()
            states=[self.w.one('SELECT status FROM jobs WHERE id=?',(job,))['status'] for job in jobs]
            if all(state=='completed' for state in states):break
            time.sleep(.01)
        self.assertEqual(states,['completed']*4)
        self.assertEqual(self.w.one('SELECT count(*) n FROM documents')['n'],62)
    def test_parent_validation(self):
        with self.assertRaises(ValueError):self.w.put({'kind':'task','title':'x','body':'','data':{'parent_id':'missing'}})
    def test_event_image_not_persisted(self):
        s=self.w.session();self.w.event(s['id'],'item',{'image':'data:image/png;base64,private'});self.assertNotIn('base64',self.w.rows('SELECT payload FROM events')[0]['payload'])

class HTTPV2Tests(unittest.TestCase):
    def setUp(self):
        self.tmp=tempfile.TemporaryDirectory();self.server=Server(self.tmp.name,bootstrap_enabled=False)
        self.thread=threading.Thread(target=self.server.serve_forever,daemon=True);self.thread.start()
    def tearDown(self):self.server.shutdown();self.server.server_close();self.thread.join();self.tmp.cleanup()
    def request(self,path,data=None,token=True,origin=None):
        headers={'Content-Type':'application/json'}
        if token:headers['X-ResearchOS-Token']=self.server.token
        if origin:headers['Origin']=origin
        req=urllib.request.Request(self.server.origin+path,data=json.dumps(data).encode() if data is not None else None,headers=headers)
        with urllib.request.urlopen(req) as r:return json.load(r)
    def test_token_required(self):
        with self.assertRaises(urllib.error.HTTPError) as e:self.request('/v2/state',token=False)
        self.assertEqual(e.exception.code,403)
    def test_external_origin_rejected(self):
        with self.assertRaises(urllib.error.HTTPError):self.request('/v2/state',origin='https://malicious.example')
    def test_record_revision_export(self):
        r=self.request('/v2/record',{'record':{'kind':'idea','title':'HTTP932','body':'write'}})
        self.assertEqual(self.request('/v2/search?q=HTTP932')[0]['id'],r['id'])
        r['body']='changed';self.request('/v2/record',{'id':r['id'],'record':r})
        with self.assertRaises(urllib.error.HTTPError) as e:self.request('/v2/record',{'id':r['id'],'record':r})
        self.assertEqual(e.exception.code,409);self.assertEqual(self.request('/v2/export')['version'],2)
    def test_empty_bootstrap_for_fixture(self):self.assertEqual(self.request('/v2/state')['roots'],[])

if __name__=='__main__':unittest.main()

class RuntimeIsolationTests(unittest.TestCase):
    def test_launcher_does_not_run_foreign_sitecustomize(self):
        import os,sys,subprocess
        with tempfile.TemporaryDirectory() as temp:
            (Path(temp)/'sitecustomize.py').write_text('import time; time.sleep(10)')
            environment=dict(os.environ,PYTHONPATH=temp)
            with self.assertRaises(subprocess.TimeoutExpired):
                subprocess.run([sys.executable,'-c','print("ready")'],env=environment,timeout=.5,capture_output=True)
            launch=Path(__file__).resolve().parents[1]/'launch.py'
            r=subprocess.run([sys.executable,'-S',str(launch),'--diagnose'],env=environment,timeout=5,capture_output=True,text=True)
            self.assertEqual(r.returncode,0,r.stderr);self.assertIn('RESEARCHOS_RUNTIME_READY',r.stdout)
