from __future__ import annotations
import argparse, json, os, secrets, signal, sqlite3, threading, time, traceback
from pathlib import Path
from urllib.parse import urlsplit,parse_qs
from http.server import ThreadingHTTPServer
from researchos.store import Store,Problem
from researchos.server import Handler as LegacyHandler
from .store import Workspace,Conflict,stamp,encode
from .library import Library,scholarly,digest
from .agent import Agent
from .ui import catalog_text

class Server(ThreadingHTTPServer):
    daemon_threads=True
    def __init__(self,directory,port=0,bootstrap_enabled=True):
        self.workspace=Workspace(directory);self.workspace.retire_file_catalogs();self.library=Library(self.workspace)
        legacy_dir=self.workspace.root/'experiments';legacy_dir.mkdir(exist_ok=True)
        old=Path.home()/'Library/Application Support/Research OS/researchos.sqlite3'
        target=legacy_dir/'researchos.sqlite3'
        if old.is_file() and not target.exists():
            source=sqlite3.connect(f'file:{old}?mode=ro',uri=True);dest=sqlite3.connect(target)
            try:source.backup(dest)
            finally:source.close();dest.close()
        self.store=Store(legacy_dir);self.agent=Agent(self.workspace,self.library,self.store)
        self.token=secrets.token_urlsafe(32);self.closing=threading.Event()
        super().__init__(('127.0.0.1',port),Handler);self.origin=f'http://127.0.0.1:{self.server_port}'
        bootstrap=Path(__file__).resolve().parents[1]/'initial-connections.json'
        if bootstrap_enabled and bootstrap.is_file() and not self.workspace.setting('initial_connections_loaded',False):
            for entry in json.loads(bootstrap.read_text()):
                if Path(entry['path']).is_dir():
                    self.workspace.root_add(entry['path'],entry['kind'])
            self.workspace.set_setting('initial_connections_loaded',True)
        # Always discover changes once on launch; auto_index only controls polling.
        if bootstrap_enabled:
            for root in self.workspace.rows("SELECT id FROM roots WHERE enabled=1 ORDER BY CASE kind WHEN 'notes' THEN 0 WHEN 'papers' THEN 1 WHEN 'data' THEN 2 ELSE 3 END"):
                self.library.start(root['id'])
        threading.Thread(target=self.watch,daemon=True).start()
    def watch(self):
        while not self.closing.wait(90):
            if self.workspace.setting('auto_index',False):
                for root in self.workspace.rows('SELECT * FROM roots WHERE enabled=1'):
                    try:self.library.start(root['id'])
                    except Exception:pass
    def server_close(self):
        self.closing.set();self.agent.close();super().server_close()

class Handler(LegacyHandler):
    server_version='ResearchOS/2.0'
    def route(self):
        parsed=urlsplit(self.path);path=parsed.path
        if not path.startswith('/v2/'):
            return super().route()
        self.guard(True);w=self.server.workspace;lib=self.server.library;agent=self.server.agent
        q={k:v[0] for k,v in parse_qs(parsed.query).items()}
        try:
            if self.command=='GET':
                if path=='/v2/settings':return self.send({'auto_index':w.setting('auto_index',False)})
                if path=='/v2/state':return self.send(w.state())
                if path=='/v2/search':return self.send(lib.store.search(q.get('q',''),q.get('project','')))
                if path=='/v2/documents':return self.send(w.browse(q.get('kind',''),q.get('q',''),q.get('project',''),q.get('limit',100),q.get('sort','name_asc')))
                if path=='/v2/document':
                    d=w.document(q['id']);p=w.allowed_path(d['path'])
                    if d['kind'] in ('repo_catalog','data_catalog'):
                        if not d['available'] or not p.is_dir():raise ValueError('Folder is offline')
                        return self.send(dict(d,body=catalog_text(d['body']),current_hash='',catalog_only=True))
                    if not d['available'] or not p.is_file():raise ValueError(d.get('error') or 'Source file is offline or changed')
                    d['current_hash']=digest(p) if d['kind']!='data' else ''
                    if d['kind']=='pdf' and d['current_hash']!=d['hash']:raise ValueError('PDF content changed. Refresh the library and open the new version.')
                    if d['kind'] not in ('data','pdf'):d['body']=p.read_text(encoding='utf-8',errors='replace')[:2_000_000]
                    return self.send(d)
                if path=='/v2/paper-sessions':return self.send(w.paper_sessions(q['document_id']))
                if path=='/v2/session':
                    id=q['id'];events=w.rows('SELECT * FROM events WHERE session_id=? ORDER BY id DESC LIMIT 80',(id,))
                    for e in events:e['payload']=json.loads(e['payload'])
                    return self.send({'session':w.one('SELECT * FROM sessions WHERE id=?',(id,)),'can_steer':bool(agent.active.get(id,{}).get('turn_id')),'messages':w.messages(id),'documents':w.session_documents(id),'events':list(reversed(events)),'approvals':[dict(key=k,**v) for k,v in agent.approvals.copy().items() if v['session_id']==id]})
                if path=='/v2/deleted-sessions':return self.send(w.rows('SELECT s.* FROM sessions s JOIN deleted_sessions d ON d.id=s.id ORDER BY d.deleted_at DESC'))
                if path=='/v2/agent':return self.send(agent.status())
                if path=='/v2/audit':return self.send(w.rows('SELECT * FROM audit WHERE object_id=? ORDER BY id DESC',(q['id'],)))
                if path=='/v2/backups':return self.send([str(p) for p in sorted((w.root/'backups').glob('*.sqlite3'),reverse=True)])
                if path=='/v2/widget':return self.send(w.snapshot_widget())
                if path=='/v2/export':return self.send({'version':2,'state':w.state(),'messages':w.rows('SELECT * FROM messages'),'paper_sessions':w.rows('SELECT * FROM session_papers'),'audit':w.rows('SELECT * FROM audit')})
            if self.command=='POST':
                d=self.body()
                if path=='/v2/record':return self.send(w.put(d.get('record',d),id=d.get('id')))
                if path=='/v2/delete':w.delete(d['id'],d['revision']);return self.send({'ok':True})
                if path=='/v2/link':return self.send(w.link(**d))
                if path=='/v2/root':
                    r=w.root_add(d['path'],d['kind'],d.get('project_id',''));lib.start(r['id']);return self.send(r)
                if path=='/v2/disconnect':w.root_remove(d['id']);return self.send({'ok':True})
                if path=='/v2/cancel-job':return self.send(lib.cancel(d['id']))
                if path=='/v2/scan':return self.send(lib.start(d['id'],d.get('organize',False)))
                if path=='/v2/session':return self.send(w.session(d.get('title','New discussion'),d.get('project_id',''),d.get('model','')))
                if path=='/v2/turn':return self.send(agent.turn(d['session_id'],d['text'],d.get('documents'),d.get('model',''),d.get('memory',True),d.get('execution',False),d.get('effort',''),d.get('web_search',True)))
                if path=='/v2/delete-session':return self.send(w.delete_session(d['id']))
                if path=='/v2/restore-session':return self.send(w.restore_session(d['id']))
                if path=='/v2/stop':return self.send(agent.stop(d['session_id']))
                if path=='/v2/approval':return self.send(agent.approve(d['key'],d.get('accept',False),d.get('answers')))
                if path=='/v2/login':return self.send(agent.login())
                if path=='/v2/scholarly':return self.send(scholarly(d['query'],d.get('source','pubmed')))
                if path=='/v2/save-text':return self.send(lib.save_text(d['id'],d['text'],d['hash']))
                if path=='/v2/backup':return self.send({'path':w.backup()})
                if path=='/v2/restore':
                    if agent.active:raise ValueError('Stop running discussions first')
                    if w.one("SELECT id FROM jobs WHERE status IN ('running','queued') LIMIT 1"):raise ValueError('Stop background refresh or organization tasks first')
                    if d.get('confirmation') not in ('RESTORE','恢复'):raise ValueError('Type RESTORE to confirm')
                    with lib.scan_lock:
                        if w.one("SELECT id FROM jobs WHERE status IN ('running','queued') LIMIT 1"):raise ValueError('Background tasks are running. Stop them before restoring.')
                        w.restore(d['path']);agent.loaded.clear()
                    return self.send({'ok':True})
                if path=='/v2/settings':
                    for k,v in d.items():
                        if k in ('auto_index','memory_default','model'):w.set_setting(k,v)
                    return self.send({'ok':True})
                if path=='/v2/import-legacy':return self.send(self.import_legacy())
                if path=='/v2/import-pdfchat':return self.send(self.import_pdfchat())
            raise Problem('Endpoint not found',404)
        except Conflict as exc:raise Problem(str(exc),409)
        except (ValueError,KeyError,FileNotFoundError) as exc:raise Problem(str(exc),400)
        except RuntimeError as exc:raise Problem(str(exc),502)
    def import_legacy(self):
        w=self.server.workspace;state=self.server.store.state();mapping=w.setting('v1_mapping',{});count=0
        names={'projects':'project','hypotheses':'idea','notes':'note','decisions':'task'}
        for collection,kind in names.items():
            for x in state.get(collection,[]):
                if x['id'] in mapping:continue
                p=mapping.get(x.get('project_id',''),'')
                body=x.get('body') or '\n\n'.join(f'{k}: {x[k]}' for k in ('question','description','rationale','prediction','criterion') if x.get(k))
                o=w.put({'kind':kind,'title':x.get('title') or x.get('name','Untitled'),'body':body,'project_id':p,'status':x.get('status','active'),'data':{'legacy_id':x['id'],'repo_path':x.get('repo_path',''),'source':'Research OS 1.0'}},source='migration')
                mapping[x['id']]=o['id'];w.set_setting('v1_mapping',mapping);count+=1
        return {'imported':count}
    def import_pdfchat(self):
        w=self.server.workspace;base=Path.home()/'Library/Application Support/PDFChat/History';count=0
        imported=set(w.setting('pdfchat_imports',[]))
        for path in base.glob('*.json'):
            try:conversations=json.loads(path.read_text())
            except (ValueError,OSError):continue
            if not isinstance(conversations,list):continue
            for c in conversations:
                key=path.stem+':'+str(c.get('id',''))
                if key in imported:continue
                s=w.session('PDFChat · '+str(c.get('title','Imported discussion')))
                for m in c.get('messages',[]):
                    w.message(s['id'],m.get('role','assistant'),m.get('text',''),metadata={'imported':True,'pdf_hash':path.stem,'original':{k:v for k,v in m.items() if k not in ('images','text')}})
                imported.add(key);w.set_setting('pdfchat_imports',list(imported));count+=1
        return {'imported':count,'note':'Original files and PDFChat attachments stay in place. Text and references are imported into this workspace.'}

def main():
    p=argparse.ArgumentParser();p.add_argument('--data-dir',default=str(Path.home()/'Library/Application Support/Research OS 2'));p.add_argument('--port',type=int,default=0);p.add_argument('--ready');args=p.parse_args()
    server=Server(args.data_dir,args.port)
    if args.ready:
        path=Path(args.ready);path.write_text(encode({'url':server.origin,'token':server.token,'pid':os.getpid()}));path.chmod(0o600)
    print(server.origin,flush=True)
    def stop(*_):threading.Thread(target=server.shutdown,daemon=True).start()
    signal.signal(signal.SIGTERM,stop);signal.signal(signal.SIGINT,stop)
    try:server.serve_forever()
    finally:server.server_close()
if __name__=='__main__':main()
