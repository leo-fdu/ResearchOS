import copy
import json
import math
import sqlite3
import subprocess
import sys
import tempfile
import threading
import unittest
from pathlib import Path
from urllib.error import HTTPError
from urllib.request import Request, urlopen
from researchos.store import Store, Problem, KINDS, compare, git_snapshot, summarize, ClosingConnection
from researchos.server import Server, ROOT

class WorkspaceTests(unittest.TestCase):
    def setUp(self):
        self.temp=tempfile.TemporaryDirectory()
        self.store=Store(Path(self.temp.name))
        self.demo=json.loads((ROOT/'examples/demo.json').read_text())
        self.store.restore(self.demo,replace=False)
    def tearDown(self): self.temp.cleanup()
    def get(self,k,id): return next(x for x in self.store.state()[k] if x['id']==id)
    def test_persistence_and_links(self):
        data=Store(Path(self.temp.name)).state()
        self.assertEqual(len(data['projects']),3); self.assertEqual(len(data['runs']),13)
        for k in KINDS[1:]:
            for x in data[k]: self.assertIn(x['project_id'],{p['id'] for p in data['projects']})
    def test_crud_and_stale_revision(self):
        n=self.store.put('notes',{'project_id':'pep','title':'<script>alert(1)</script>','body':"Robert'); DROP TABLE records;--"})
        changed=self.store.put('notes',dict(n,body='观察更新'),n['id'])
        self.assertEqual(changed['revision'],n['revision']+1)
        with self.assertRaises(Problem): self.store.put('notes',n,n['id'])
        with self.assertRaises(Problem): self.store.delete('notes',n['id'],n['revision'])
        self.store.delete('notes',changed['id'],changed['revision'])
        self.assertEqual(len(self.store.state()['projects']),3)
    def test_cross_project_links_blocked(self):
        with self.assertRaises(Problem): self.store.put('notes',{'project_id':'mol','title':'bad','experiment_id':'exp-base'})
    def test_parent_delete_restricted(self):
        with self.assertRaises(Problem): self.store.delete('projects','pep',self.get('projects','pep')['revision'])
    def test_frozen_config_and_dataset(self):
        exp=self.get('experiments','exp-base')
        for k,v in [('config',{'lr':1}),('split','other'),('git',{'commit':'other'})]:
            with self.subTest(k=k),self.assertRaises(Problem): self.store.put('experiments',dict(exp,**{k:v}),exp['id'])
        ds=self.get('datasets','ds-pep')
        with self.assertRaises(Problem): self.store.put('datasets',dict(ds,version='v2'),ds['id'])
        self.assertEqual(self.store.put('datasets',dict(ds,description='更新'),ds['id'])['description'],'更新')
    def test_primary_metric_required(self):
        with self.assertRaises(Problem): self.store.put('runs',{'project_id':'pep','experiment_id':'exp-base','seed':99,'status':'completed','metrics':{'other':1}})
    def test_duplicate_seed_rejected(self):
        with self.assertRaises(Problem): self.store.put('runs',{'project_id':'pep','experiment_id':'exp-base','seed':11,'status':'failed','metrics':{}})
    def test_invalid_metrics_and_seeds(self):
        for v in [math.nan,math.inf,True,'2.4']:
            with self.subTest(v=v),self.assertRaises(Problem): self.store.put('runs',{'project_id':'pep','experiment_id':'exp-base','seed':99,'status':'completed','metrics':{'RMSE':v}})
        for v in [-1,1.5,True,2**32]:
            with self.subTest(v=v),self.assertRaises(Problem): self.store.put('runs',{'project_id':'pep','experiment_id':'exp-base','seed':v,'status':'failed','metrics':{}})
    def test_history_strict_step_order(self):
        with self.assertRaises(Problem): self.store.put('runs',{'project_id':'pep','experiment_id':'exp-base','seed':99,'status':'failed','metrics':{},'history':[{'step':1,'metrics':{'loss':2}},{'step':1,'metrics':{'loss':1}}]})
    def test_csv_atomic_preview_commit(self):
        bad='seed,status,RMSE,notes\n101,completed,2.4,good\n102,completed,NaN,invalid\n'
        p=self.store.import_csv('exp-base',bad)
        self.assertEqual(p['count'],1); self.assertEqual(p['errors'][0]['line'],3)
        with self.assertRaises(Problem): self.store.import_csv('exp-base',bad,True)
        self.assertEqual(len(self.store.state()['runs']),13)
        good='seed,status,RMSE,notes\n101,completed,2.4,"with, comma"\n102,failed,,out of memory\n'
        self.assertTrue(self.store.import_csv('exp-base',good,True)['committed'])
        self.assertEqual(len(self.store.state()['runs']),15)
    def test_csv_duplicates_and_bad_columns(self):
        self.assertEqual(len(self.store.import_csv('exp-base','seed,RMSE\n99,2.4\n99,2.3\n')['errors']),1)
        with self.assertRaises(Problem): self.store.import_csv('exp-base','seed,RMSE,RMSE\n99,2.4,2.3\n')
    def test_known_paired_statistics(self):
        r=compare(self.store.state(),['exp-base','exp-gate']);p=r['results'][1]['paired']
        self.assertEqual(p['n'],5); self.assertAlmostEqual(p['mean'],-.076,places=12)
        self.assertAlmostEqual(p['sd'],.0167332005307,places=10)
        self.assertAlmostEqual(p['ci95'][0],-.09677368181136889,places=10)
        self.assertAlmostEqual(r['results'][0]['summary']['mean'],2.602)
    def test_running_and_unmatched_seeds(self):
        r=compare(self.store.state(),['exp-base','exp-shuffle'])['results'][1]
        self.assertEqual(r['paired']['seeds'],[11,22]);self.assertEqual(r['excluded'],1)
        self.assertEqual(r['summary']['n'],2)
    def test_comparability_guards(self):
        for ids in [['exp-base','exp-size'],['exp-base','exp-base'],['exp-base']]:
            with self.subTest(ids=ids),self.assertRaises(Problem):compare(self.store.state(),ids)
    def test_single_seed_sd_unknown(self):
        self.assertIsNone(summarize([.5])['sd']);self.assertIsNone(summarize([])['mean'])
    def test_export_restore_and_stale_clients(self):
        before=self.store.export();stale=self.get('projects','pep');self.store.restore(before)
        after=self.store.export()
        for k in KINDS:self.assertEqual({x['id'] for x in before['data'][k]},{x['id'] for x in after['data'][k]})
        self.assertEqual(self.get('experiments','exp-gate')['config'],next(e['config'] for e in before['data']['experiments'] if e['id']=='exp-gate'))
        with self.assertRaises(Problem):self.store.put('projects',stale,'pep')
    def test_invalid_restore_rolls_back(self):
        before=self.store.export()['data'];bad=copy.deepcopy(self.demo);bad['data']['notes'][0]['project_id']='missing'
        with self.assertRaises(Problem):self.store.restore(bad)
        self.assertEqual(self.store.export()['data'],before)
    def test_restore_rejects_markup_in_ids(self):
        bad=copy.deepcopy(self.demo);bad['data']['projects'][0]['id']='bad" onclick="alert(1)'
        with self.assertRaises(Problem):self.store.restore(bad)
        self.assertEqual(len(self.store.state()['projects']),3)
    def test_backup_readable(self):
        with sqlite3.connect(self.store.backup(),factory=ClosingConnection) as db:self.assertEqual(db.execute("SELECT count(*) FROM records WHERE kind='runs'").fetchone()[0],13)
    def test_demo_cannot_overwrite(self):
        with self.assertRaises(Problem):self.store.restore(self.demo,replace=False)
        self.assertEqual(len(self.store.state()['projects']),3)
    def test_url_date_validation(self):
        with self.assertRaises(Problem):self.store.put('papers',{'project_id':'pep','title':'bad','url':'javascript:alert(1)'})
        with self.assertRaises(Problem):self.store.put('decisions',{'project_id':'pep','title':'bad','due_date':'2026-99-99'})
    def test_snapshot_recovery_after_delete(self):
        note=self.store.put('notes',{'project_id':'pep','title':'recover me'})
        self.store.delete('notes',note['id'],note['revision'])
        snap=next(x for x in self.store.snapshots() if 'before-delete' in x['name'])
        self.store.recover_snapshot(snap['name'])
        self.assertEqual(self.get('notes',note['id'])['title'],'recover me')
        with self.assertRaises(Problem):self.store.recover_snapshot('../researchos.sqlite3')
    def test_cli_ingestion_and_explicit_updates(self):
        command=[sys.executable,'-m','researchos.cli','--data-dir',self.temp.name,'log-run','--experiment','exp-base','--seed','101','--metrics','{"RMSE":2.4}']
        result=subprocess.run(command,text=True,capture_output=True)
        self.assertEqual(result.returncode,0,result.stderr)
        self.assertEqual(json.loads(result.stdout)['metrics']['RMSE'],2.4)
        again=subprocess.run(command,text=True,capture_output=True)
        self.assertEqual(again.returncode,1)
        update=subprocess.run(command+['--update'],text=True,capture_output=True)
        self.assertEqual(update.returncode,0,update.stderr)

    def test_git_snapshot_real_repo(self):
        repo=Path(self.temp.name)/'repo';repo.mkdir()
        def git(*args):subprocess.run(['git','-C',str(repo),*args],check=True,capture_output=True)
        git('init');git('config','user.name','Test');git('config','user.email','test@example.invalid')
        (repo/'README').write_text('initial');git('add','README');git('commit','-m','initial')
        self.assertFalse(git_snapshot(str(repo))['dirty']);(repo/'README').write_text('modified')
        snap=git_snapshot(str(repo));self.assertTrue(snap['dirty']);self.assertRegex(snap['commit'],r'^[0-9a-f]{40}$')

class HTTPTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temp=tempfile.TemporaryDirectory();cls.server=Server(0,Store(Path(cls.temp.name)))
        cls.thread=threading.Thread(target=cls.server.serve_forever,daemon=True);cls.thread.start();cls.url=cls.server.origin
    @classmethod
    def tearDownClass(cls):
        cls.server.shutdown();cls.server.server_close();cls.thread.join();cls.temp.cleanup()
    def request(self,path,data=None,headers=None):
        h={'X-ResearchOS-Token':self.server.token}
        if data is not None:h['Content-Type']='application/json'
        h.update(headers or {})
        try:
            return urlopen(Request(self.url+path,data=json.dumps(data).encode() if data is not None else None,headers=h),timeout=5)
        except HTTPError as exc:
            exc.close()
            raise
    def test_bootstrap_and_static_assets(self):
        with self.request('/') as r:
            self.assertIn(self.server.token,r.read().decode());self.assertIn("frame-ancestors 'none'",r.headers['Content-Security-Policy'])
        for p in ['/app.js','/style.css','/favicon.svg']:
            with self.request(p) as r:self.assertEqual(r.status,200)
    def test_token_required(self):
        with self.assertRaises(HTTPError) as r:self.request('/api/state',headers={'X-ResearchOS-Token':''})
        self.assertEqual(r.exception.code,403)
    def test_host_origin_and_traversal(self):
        for h in [{'Host':'evil.invalid'},{'Origin':'https://evil.invalid'},{'Sec-Fetch-Site':'cross-site'}]:
            with self.subTest(h=h),self.assertRaises(HTTPError) as r:self.request('/api/state',headers=h)
            self.assertEqual(r.exception.code,403)
        with self.assertRaises(HTTPError) as r:self.request('/../researchos/store.py')
        self.assertEqual(r.exception.code,404)
    def test_http_create_and_read(self):
        with self.request('/api/projects',{'name':'HTTP smoke project'}) as r:
            created=json.load(r);self.assertEqual(r.status,201)
        with self.request('/api/state') as r:self.assertIn(created['id'],{p['id'] for p in json.load(r)['projects']})
    def test_bad_json(self):
        req=Request(self.url+'/api/projects',data=b'{"name": NaN}',headers={'X-ResearchOS-Token':self.server.token,'Content-Type':'application/json'})
        with self.assertRaises(HTTPError) as r:urlopen(req,timeout=5)
        self.assertEqual(r.exception.code,400);r.exception.close()

if __name__=='__main__':unittest.main(verbosity=2)
