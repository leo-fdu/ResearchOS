"""Research workspace: authoritative objects, rebuildable source index and audit trail."""
from __future__ import annotations
import hashlib, json, os, re, sqlite3, tempfile, threading, uuid
from pathlib import Path
from datetime import datetime, timezone
from contextlib import contextmanager
from .ui import system_text

def stamp(): return datetime.now(timezone.utc).isoformat(timespec='milliseconds')
def uid(): return uuid.uuid4().hex
def encode(value): return json.dumps(value,ensure_ascii=False,allow_nan=False)

class Conflict(ValueError): pass

RESEARCH_STATUSES={'doing','todo','paused','archived','done'}
LEGACY_RESEARCH_STATUSES={'active':'doing','testing':'doing','exploring':'todo','blocked':'paused','disputed':'paused','superseded':'archived'}

class Workspace:
    kinds={'project','idea','plan','task','note','memory'}
    def __init__(self, directory):
        self.root=Path(directory).resolve();self.root.mkdir(parents=True,exist_ok=True)
        self.path=self.root/'workspace.sqlite3';self.lock=threading.RLock()
        (self.root/'artifacts').mkdir(exist_ok=True)
        with self.db() as db:
            db.executescript('''
            PRAGMA journal_mode=WAL;
            CREATE TABLE IF NOT EXISTS objects(id TEXT PRIMARY KEY,kind TEXT,title TEXT,body TEXT,project_id TEXT,status TEXT,data TEXT,revision INTEGER,created_at TEXT,updated_at TEXT);
            CREATE TABLE IF NOT EXISTS roots(id TEXT PRIMARY KEY,path TEXT UNIQUE,kind TEXT,name TEXT,project_id TEXT,enabled INTEGER DEFAULT 1,last_scan TEXT,error TEXT);
            CREATE TABLE IF NOT EXISTS documents(id TEXT PRIMARY KEY,root_id TEXT,path TEXT UNIQUE,title TEXT,kind TEXT,hash TEXT,mtime INTEGER,size INTEGER,body TEXT,available INTEGER DEFAULT 1,pages INTEGER DEFAULT 0,error TEXT);
            CREATE VIRTUAL TABLE IF NOT EXISTS search_index USING fts5(id UNINDEXED,title,body,tokenize='unicode61');
            CREATE TABLE IF NOT EXISTS edges(id TEXT PRIMARY KEY,source TEXT,target TEXT,relation TEXT,detail TEXT,UNIQUE(source,target,relation));
            CREATE TABLE IF NOT EXISTS resource_summaries(id TEXT PRIMARY KEY,summary TEXT,source TEXT,readme TEXT,updated_at TEXT);
            CREATE TABLE IF NOT EXISTS deleted_sessions(id TEXT PRIMARY KEY,deleted_at TEXT);
            CREATE TABLE IF NOT EXISTS sessions(id TEXT PRIMARY KEY,title TEXT,project_id TEXT,thread_id TEXT,model TEXT,created_at TEXT,updated_at TEXT,status TEXT);
            CREATE TABLE IF NOT EXISTS messages(id TEXT PRIMARY KEY,session_id TEXT,role TEXT,text TEXT,status TEXT,at TEXT,metadata TEXT);
            CREATE TABLE IF NOT EXISTS events(id INTEGER PRIMARY KEY AUTOINCREMENT,session_id TEXT,method TEXT,payload TEXT,at TEXT);
            CREATE TABLE IF NOT EXISTS jobs(id TEXT PRIMARY KEY,kind TEXT,status TEXT,detail TEXT,created_at TEXT,updated_at TEXT);
            CREATE TABLE IF NOT EXISTS audit(id INTEGER PRIMARY KEY AUTOINCREMENT,object_id TEXT,action TEXT,before TEXT,after TEXT,source TEXT,at TEXT);
            CREATE TABLE IF NOT EXISTS forgotten(fingerprint TEXT PRIMARY KEY,at TEXT);
            CREATE TABLE IF NOT EXISTS calls(id TEXT PRIMARY KEY,result TEXT);
            CREATE TABLE IF NOT EXISTS memory_blocks(source TEXT PRIMARY KEY,at TEXT);
            CREATE INDEX IF NOT EXISTS documents_display ON documents((CASE kind WHEN 'pdf' THEN 0 WHEN 'notes' THEN 1 ELSE 2 END),title);
            CREATE INDEX IF NOT EXISTS documents_root ON documents(root_id);
            CREATE TABLE IF NOT EXISTS settings(key TEXT PRIMARY KEY,value TEXT);
            ''')
            db.execute("UPDATE jobs SET status='interrupted',detail='Task interrupted when the app quit. Run it again to continue.',updated_at=? WHERE status IN ('running','queued')",(stamp(),))
            db.execute("UPDATE sessions SET status='interrupted' WHERE status='running'")
            db.execute("UPDATE messages SET status='interrupted' WHERE status='streaming'")
        from . import authoring
        authoring.init(self)
        self.hide_note_metadata()
        self.migrate_research_statuses()
        self.migrate_paper_sessions()
        self.snapshot_widget()
    @contextmanager
    def db(self,fast=False):
        # Keep connection open/close and short transactions ordered across
        # HTTP and indexing threads. File extraction runs outside this lock.
        with self.lock:
            con=sqlite3.connect(self.path,timeout=30);con.row_factory=sqlite3.Row
            if fast:con.execute("PRAGMA synchronous=NORMAL")
            try:
                with con: yield con
            finally: con.close()
    def rows(self,sql,args=()):
        with self.db() as db:return [dict(x) for x in db.execute(sql,args)]
    def one(self,sql,args=()):
        r=self.rows(sql,args);return r[0] if r else None
    def object(self,id):
        r=self.one('SELECT * FROM objects WHERE id=?',(id,))
        if r:r['data']=json.loads(r['data'])
        return r
    def hide_note_metadata(self):
        hidden=[r['id'] for r in self.rows("SELECT d.id,d.path FROM documents d JOIN roots r ON r.id=d.root_id WHERE r.kind='notes'") if Path(r['path']).name.upper() in ('AGENTS.MD','INDEX.MD')]
        with self.db() as db:
            for ident in hidden:
                db.execute('UPDATE documents SET available=0 WHERE id=?',(ident,))
                db.execute('DELETE FROM search_index WHERE id=?',(ident,))

    def setting(self,key,default=None):
        r=self.one('SELECT value FROM settings WHERE key=?',(key,));return json.loads(r['value']) if r else default
    def retire_file_catalogs(self):
        """Remove the obsolete per-file repo/data cache; keep authored records."""
        if self.setting('directory_catalog_v1',False):return 0
        with self.db() as db:
            db.execute("CREATE TEMP TABLE obsolete_catalog_ids AS SELECT d.id FROM documents d JOIN roots r ON r.id=d.root_id WHERE r.kind IN ('repo','data') AND d.kind NOT IN ('repo_catalog','data_catalog')")
            db.execute('CREATE UNIQUE INDEX obsolete_catalog_key ON obsolete_catalog_ids(id)')
            count=db.execute('SELECT count(*) FROM obsolete_catalog_ids').fetchone()[0]
            db.execute('DELETE FROM search_index WHERE id IN (SELECT id FROM obsolete_catalog_ids)')
            # Keep explicitly linked IDs as unavailable references, without cached file bodies.
            db.execute("UPDATE documents SET body='',available=0,error='Per-file indexing removed. Read files on demand through their repository or dataset folder.' WHERE id IN (SELECT id FROM obsolete_catalog_ids) AND id IN (SELECT source FROM edges UNION SELECT target FROM edges)")
            db.execute('DELETE FROM documents WHERE id IN (SELECT id FROM obsolete_catalog_ids) AND id NOT IN (SELECT source FROM edges UNION SELECT target FROM edges)')
            db.execute("UPDATE roots SET last_scan=NULL WHERE kind IN ('repo','data')")
            db.execute("INSERT OR REPLACE INTO settings VALUES('directory_catalog_v1','true')")
            db.execute("INSERT OR REPLACE INTO settings VALUES('auto_index','false')")
        if count:
            with self.db() as db:db.execute("INSERT INTO search_index(search_index) VALUES('optimize')")
            with self.db() as db:db.execute('VACUUM')
        return count
    def set_setting(self,key,value):
        with self.db() as db:db.execute('INSERT OR REPLACE INTO settings VALUES(?,?)',(key,encode(value)))
    def migrate_research_statuses(self):
        records=self.rows("SELECT id,status FROM objects WHERE kind IN ('project','idea')")
        outdated=[r for r in records if r['status'] not in RESEARCH_STATUSES]
        if not outdated:return
        self.backup()
        for record in outdated:
            current=self.object(record['id'])
            current['status']=LEGACY_RESEARCH_STATUSES.get(record['status'],'todo')
            self.put(current,source='migration:five-research-statuses',id=record['id'])

    def put(self,d,source='user',id=None):
        from . import authoring
        if id:authoring.sync(self,id)
        with self.lock, self.db() as db:
            db.execute('BEGIN IMMEDIATE')
            old=self.object(id) if id else None
            if id and not old:raise ValueError('Record not found')
            if old and d.get('revision')!=old['revision']:raise Conflict('Record changed. Refresh and retry.')
            value={**(old or {}),**d};kind=value.get('kind');title=str(value.get('title','')).strip()
            if kind not in self.kinds or not title or len(title)>300:raise ValueError('Invalid record type or title')
            if kind in ('project','idea'):
                status=value.get('status','todo')
                status=LEGACY_RESEARCH_STATUSES.get(status,status)
                if status not in RESEARCH_STATUSES:raise ValueError('Project and idea status must be doing, todo, paused, archived or done')
                value['status']=status
            body=value.get('body','');data=value.get('data',{})
            if not isinstance(body,str) or len(body)>500_000 or not isinstance(data,dict):raise ValueError('Invalid or oversized record content')
            data=authoring.validate_record(self,value,source)
            project=value.get('project_id') or ''
            if project and (not self.object(project) or self.object(project)['kind']!='project'):raise ValueError('Linked project not found')
            parent=data.get('parent_id')
            if parent:
                target=self.object(parent)
                if not target or target['kind'] not in ('plan','task','project') or parent==id:raise ValueError('Parent plan or task not found')
            if kind=='memory':
                if not data.get('source'):raise ValueError('Memory requires a source')
                if source.startswith('session:') and db.execute('SELECT 1 FROM memory_blocks WHERE source=?',(source,)).fetchone():raise ValueError('A memory from this discussion was forgotten. It cannot be extracted again automatically; you may add it manually.')
                fp=hashlib.sha256((title+'\n'+body).encode()).hexdigest()
                if db.execute('SELECT 1 FROM forgotten WHERE fingerprint=?',(fp,)).fetchone():raise ValueError('This content was forgotten and cannot be added again automatically.')
                data['fingerprint']=fp
            ident=id or uid();now=stamp();revision=(old['revision']+1) if old else 1
            data=authoring.attach_files(self,ident,data)
            row=(ident,kind,title,body,project,value.get('status','active'),encode(data),revision,old['created_at'] if old else now,now)
            db.execute('INSERT OR REPLACE INTO objects VALUES(?,?,?,?,?,?,?,?,?,?)',row)
            db.execute('INSERT INTO audit(object_id,action,before,after,source,at) VALUES(?,?,?,?,?,?)',(ident,'update' if old else 'create',encode(old),encode(dict(zip(['id','kind','title','body','project_id','status','data','revision','created_at','updated_at'],row))),source,now))
            db.execute('DELETE FROM search_index WHERE id=?',(ident,));db.execute('INSERT INTO search_index VALUES(?,?,?)',(ident,title,body))
            authoring.push_object(self,dict(id=ident,kind=kind,title=title,body=body,data=data),db)
        self.snapshot_widget();return self.object(ident)
    def delete(self,id,revision):
        with self.lock:
            self.backup()
            return self._delete(id,revision)
    def _delete(self,id,revision):
        with self.lock,self.db() as db:
            db.execute('BEGIN IMMEDIATE');old=self.object(id)
            if not old or old['revision']!=revision:raise Conflict('Record changed')
            if db.execute('SELECT 1 FROM objects WHERE project_id=? LIMIT 1',(id,)).fetchone():raise ValueError('This project has linked records. Archive it instead.')
            if db.execute("SELECT 1 FROM objects WHERE json_extract(data,'$.owner_id')=? LIMIT 1",(id,)).fetchone():raise ValueError('This resource has experiment logs. Archive it instead.')
            if old['kind']=='memory':
                db.execute('INSERT OR REPLACE INTO forgotten VALUES(?,?)',(old['data'].get('fingerprint',''),stamp()))
                origin=old['data'].get('source','')
                if origin.startswith('session:'):db.execute('INSERT OR REPLACE INTO memory_blocks VALUES(?,?)',(origin,stamp()))
            db.execute('DELETE FROM objects WHERE id=?',(id,));db.execute('DELETE FROM search_index WHERE id=?',(id,))
            db.execute('DELETE FROM edges WHERE source=? OR target=?',(id,id))
            db.execute('INSERT INTO audit(object_id,action,before,after,source,at) VALUES(?,?,?,?,?,?)',(id,'delete',encode(old),'null','user',stamp()))
        self.snapshot_widget()
    def root_add(self,path,kind,project_id=''):
        path=Path(path).expanduser().resolve()
        if not path.is_dir():raise ValueError('Folder not found')
        if kind not in ('papers','notes','repo','results','data'):raise ValueError('Invalid folder type')
        if project_id and (not self.object(project_id) or self.object(project_id)['kind']!='project'):raise ValueError('Project not found')
        with self.db() as db:
            old=db.execute('SELECT id FROM roots WHERE path=?',(str(path),)).fetchone();id=old[0] if old else uid()
            db.execute('INSERT OR REPLACE INTO roots VALUES(?,?,?,?,?,1,NULL,NULL)',(id,str(path),kind,path.name,project_id))
        return self.one('SELECT * FROM roots WHERE id=?',(id,))
    def root_remove(self,id):
        with self.db() as db:
            for row in db.execute('SELECT id FROM documents WHERE root_id=?',(id,)).fetchall():db.execute('DELETE FROM search_index WHERE id=?',(row[0],))
            db.execute('UPDATE documents SET available=0 WHERE root_id=?',(id,));db.execute('UPDATE roots SET enabled=0 WHERE id=?',(id,))
    def allowed_path(self,path):
        p=Path(path).expanduser().resolve()
        if any(p.is_relative_to(Path(r['path'])) for r in self.rows('SELECT path FROM roots WHERE enabled=1')):return p
        if p.is_relative_to(self.root/'artifacts'):return p
        raise ValueError('File is outside connected folders')
    def document(self,id):
        d=self.one('SELECT * FROM documents WHERE id=?',(id,))
        if not d:raise ValueError('Resource not found')
        return d
    def search(self,query,project='',limit=40):
        query=query.strip()[:500];limit=max(1,min(100,int(limit)))
        if not query:return []
        words=re.findall(r'[\w\u3400-\u9fff]+',query)
        ids=[]
        if words:
            try:ids=[r['id'] for r in self.rows('SELECT id FROM search_index WHERE search_index MATCH ? ORDER BY rank LIMIT ?',(' OR '.join('"'+w+'"' for w in words),limit*2))]
            except sqlite3.OperationalError:pass
        # Substring fallback also finds Chinese phrases without relying on tokenizer segmentation.
        for r in self.rows('SELECT id FROM search_index WHERE title LIKE ? OR body LIKE ? LIMIT ?',('%'+query+'%','%'+query+'%',limit*2)):
            if r['id'] not in ids:ids.append(r['id'])
        out=[]
        for id in ids:
            o=self.object(id)
            if o:
                if project and o['project_id']!=project and o['id']!=project:continue
                if o['kind']=='memory' and o['status'] not in ('active','confirmed'):continue
                o['source_type']='object'
            else:
                o=self.one('SELECT d.*,r.project_id FROM documents d JOIN roots r ON r.id=d.root_id WHERE d.id=? AND d.available=1 AND r.enabled=1',(id,))
                if not o:continue
                if project and o['project_id']!=project and not self.one('SELECT id FROM edges WHERE (source=? AND target IN (?,?)) OR (target=? AND source IN (?,?))',(project,id,o['root_id'],project,id,o['root_id'])):continue
                o['source_type']='document'
            body=o.get('body','');pos=max(0,body.lower().find(query.lower())-120)
            o['excerpt']=body[pos:pos+650];o.pop('body',None);out.append(o)
            if len(out)>=limit:break
        if len(out)<limit:
            for session in self.rows("SELECT s.id,s.title,s.project_id,s.updated_at,m.text FROM sessions s JOIN messages m ON m.session_id=s.id WHERE s.id NOT IN (SELECT id FROM deleted_sessions) AND (s.title LIKE ? OR m.text LIKE ?) AND (?='' OR s.project_id=?) GROUP BY s.id ORDER BY s.updated_at DESC LIMIT ?",('%'+query+'%','%'+query+'%',project,project,limit-len(out))):
                session.update(source_type='session',kind='discussion',excerpt=session.pop('text')[:650]);out.append(session)
        return out
    def link(self,source,target,relation='related',detail=''):
        for id in (source,target):
            room=self.one('SELECT payload FROM brainstorm_rooms WHERE id=?',(id,)) if self.one("SELECT name FROM sqlite_master WHERE name='brainstorm_rooms'") else None
            active_room=room and not json.loads(room['payload']).get('deleted_at')
            if not active_room and not self.object(id) and not self.one('SELECT id FROM documents WHERE id=? AND available=1',(id,)) and not self.one('SELECT id FROM roots WHERE id=? AND enabled=1',(id,)):raise ValueError('Linked record not found')
        with self.db() as db:db.execute('INSERT OR IGNORE INTO edges VALUES(?,?,?,?,?)',(uid(),source,target,relation,detail))
        return {'linked':True}
    def state(self,sync_files=True):
        if sync_files:
            from .authoring import sync
            sync(self)
        objects=self.rows('SELECT * FROM objects ORDER BY updated_at DESC')
        jobs=self.rows('SELECT * FROM jobs ORDER BY created_at DESC LIMIT 30')
        for job in jobs:
            job['kind']=system_text(job['kind']);job['detail']=system_text(job['detail'])
        for o in objects:o['data']=json.loads(o['data'])
        return dict(objects=objects,roots=self.rows('SELECT * FROM roots WHERE enabled=1'),documents=self.rows("SELECT id,root_id,path,title,kind,pages,available,error,hash,mtime FROM documents ORDER BY CASE kind WHEN 'pdf' THEN 0 WHEN 'notes' THEN 1 ELSE 2 END,title LIMIT 10000"),sessions=self.rows('SELECT * FROM sessions WHERE id NOT IN (SELECT id FROM deleted_sessions) ORDER BY updated_at DESC'),jobs=jobs,edges=self.rows('SELECT * FROM edges'),counts=self.one('SELECT count(*) total,sum(available) available FROM documents'))
    def browse(self,kind,query='',project='',limit=100,sort='name_asc',category=''):
        limit=max(1,min(2000,int(limit)));args=[]
        where=['d.available=1','r.enabled=1']
        if kind=='papers':where.append("d.kind='pdf'")
        elif kind:where.append('r.kind=?');args.append(kind)
        if query:where.append('(d.title LIKE ? OR d.path LIKE ?)');args.extend(['%'+query[:300]+'%']*2)
        if project:
            where.append('(r.project_id=? OR EXISTS (SELECT 1 FROM edges e WHERE (e.source=? AND e.target IN (d.id,r.id)) OR (e.target=? AND e.source IN (d.id,r.id))))');args.extend([project]*3)
        clause=' AND '.join(where)
        count=self.one('SELECT count(*) total FROM documents d JOIN roots r ON r.id=d.root_id WHERE '+clause,args)['total']
        records=self.rows("SELECT d.id,d.root_id,d.path,d.title,d.kind,d.pages,d.available,d.error,d.mtime,COALESCE(s.summary,'') summary FROM documents d JOIN roots r ON r.id=d.root_id LEFT JOIN resource_summaries s ON s.id=d.id WHERE "+clause,args)
        if kind=='notes':
            roots={r['id']:Path(r['path']) for r in self.rows("SELECT id,path FROM roots WHERE kind='notes'")}
            for row in records:
                parts=Path(row['path']).relative_to(roots[row['root_id']]).parts
                row['category']=parts[0] if len(parts)>1 else 'other'
            if category:records=[r for r in records if r['category']==category]
            count=len(records)
        # Only stat known entries; do not enumerate any directory contents.
        for row in records:
            try:row['modified_ns']=Path(row['path']).stat().st_mtime_ns
            except OSError:row['modified_ns']=row['mtime']
        if sort not in ('name_asc','name_desc','modified_asc','modified_desc'):raise ValueError('Invalid resource sort order')
        if sort.startswith('modified'):records.sort(key=lambda x:(x['modified_ns'],x['title'].casefold()),reverse=sort.endswith('desc'))
        else:records.sort(key=lambda x:(Path(x['path']).name.casefold(),x['id']),reverse=sort.endswith('desc'))
        return {'documents':records[:limit],'total':count,'limit':limit}
    def delete_session(self,id):
        with self.lock,self.db() as db:
            session=db.execute('SELECT status FROM sessions WHERE id=?',(id,)).fetchone()
            if not session:raise ValueError('Conversation not found')
            if session['status']=='running':raise ValueError('Stop the discussion before deleting it')
            db.execute('INSERT OR REPLACE INTO deleted_sessions VALUES(?,?)',(id,stamp()))
        return {'ok':True}
    def restore_session(self,id):
        with self.db() as db:db.execute('DELETE FROM deleted_sessions WHERE id=?',(id,))
        return {'ok':True}
    def session(self,title='New discussion',project='',model=''):
        id=uid();now=stamp()
        with self.db() as db:db.execute('INSERT INTO sessions VALUES(?,?,?,?,?,?,?,?)',(id,title[:100],project,'',model,now,now,'idle'))
        return self.one('SELECT * FROM sessions WHERE id=?',(id,))
    def _link_message_papers(self,db,session,metadata,at):
        # Content hashes survive rename/organize and keep changed PDF versions apart.
        snapshots=[]
        ids=metadata.get('documents',[])
        for id in ids if isinstance(ids,list) else []:
            if not isinstance(id,str):continue
            d=db.execute("SELECT id,hash FROM documents WHERE id=? AND kind='pdf'",(id,)).fetchone()
            if d and d['hash']:snapshots.append({'id':d['id'],'hash':d['hash']})
        saved=metadata.get('paper_versions',[])
        if isinstance(saved,list) and saved:snapshots=saved
        imported=metadata.get('pdf_hash')
        if isinstance(imported,str) and re.fullmatch(r'[0-9a-f]{64}',imported):
            snapshots.append({'id':'','hash':imported})
        for paper in snapshots:
            if not isinstance(paper,dict):continue
            hash=paper.get('hash','')
            if not isinstance(hash,str) or not re.fullmatch(r'[0-9a-f]{64}',hash):continue
            db.execute('INSERT OR IGNORE INTO session_papers VALUES(?,?,?,?)',(session,hash,str(paper.get('id','')),at))
        return snapshots
    def migrate_paper_sessions(self):
        with self.db() as db:
            db.executescript('''
            CREATE TABLE IF NOT EXISTS session_papers(session_id TEXT,pdf_hash TEXT,document_id TEXT,linked_at TEXT,PRIMARY KEY(session_id,pdf_hash));
            CREATE INDEX IF NOT EXISTS session_papers_hash ON session_papers(pdf_hash);
            ''')
            if db.execute("SELECT 1 FROM settings WHERE key='paper_sessions_v1'").fetchone():return
            # Only existing message metadata; never scan source files or repositories.
            for m in db.execute('SELECT session_id,metadata,at FROM messages').fetchall():
                try:metadata=json.loads(m['metadata'])
                except (ValueError,TypeError):continue
                if isinstance(metadata,dict):self._link_message_papers(db,m['session_id'],metadata,m['at'])
            db.execute("INSERT INTO settings VALUES('paper_sessions_v1','true')")
    def paper_sessions(self,document):
        paper=self.document(document)
        if paper['kind']!='pdf':raise ValueError('Paper discussions require a PDF')
        return self.rows('''SELECT s.*,(SELECT count(*) FROM messages m WHERE m.session_id=s.id) message_count
            FROM sessions s JOIN session_papers p ON p.session_id=s.id
            WHERE p.pdf_hash=? AND s.id NOT IN (SELECT id FROM deleted_sessions)
            ORDER BY s.updated_at DESC,s.id''',(paper['hash'],))
    def session_documents(self,session):
        last=self.one("SELECT metadata FROM messages WHERE session_id=? AND role='user' ORDER BY rowid DESC LIMIT 1",(session,))
        if not last:return []
        metadata=json.loads(last['metadata']);out=[]
        for id in metadata.get('documents',[]):
            d=self.one('SELECT id FROM documents WHERE id=? AND available=1',(id,))
            if d:out.append(d['id'])
            elif self.object(id):out.append(id)
        versions=metadata.get('paper_versions',[])
        if metadata.get('pdf_hash'):versions=versions+[{'hash':metadata['pdf_hash']}]
        for paper in versions:
            hash=paper.get('hash','')
            if not hash:continue
            # Prefer the same entry, then a live copy after a move or rename.
            d=self.one("SELECT id FROM documents WHERE kind='pdf' AND hash=? AND available=1 ORDER BY (id=?) DESC,id LIMIT 1",(hash,paper.get('id','')))
            if d and d['id'] not in out:out.append(d['id'])
        return out
    def message(self,session,role,text,status='completed',metadata=None):
        id=uid()
        metadata=dict(metadata or {});at=stamp()
        with self.db() as db:
            if role=='user' or metadata.get('imported'):
                metadata['paper_versions']=self._link_message_papers(db,session,metadata,at)
            db.execute('INSERT INTO messages VALUES(?,?,?,?,?,?,?)',(id,session,role,text,status,at,encode(metadata)))
        return id
    def event(self,session,method,payload):
        def compact(value):
            if isinstance(value,dict):return {k:compact(v) for k,v in value.items()}
            if isinstance(value,list):return [compact(v) for v in value[:100]]
            if isinstance(value,str):return '[image data omitted]' if value.startswith('data:image/') else value[:20000]
            return value
        payload=compact(payload)
        with self.db() as db:db.execute('INSERT INTO events(session_id,method,payload,at) VALUES(?,?,?,?)',(session,method,encode(payload),stamp()))
    def messages(self,id):
        result=self.rows('SELECT * FROM messages WHERE session_id=? ORDER BY rowid',(id,))
        for r in result:r['metadata']=json.loads(r['metadata'])
        return result
    def job(self,kind):
        id=uid();now=stamp()
        with self.db() as db:db.execute('INSERT INTO jobs VALUES(?,?,?,?,?,?)',(id,kind,'queued','Queued',now,now))
        return id
    def job_update(self,id,status,detail):
        with self.db() as db:db.execute('UPDATE jobs SET status=?,detail=?,updated_at=? WHERE id=?',(status,str(detail)[-16000:],stamp(),id))
    def backup(self):
        dest=self.root/'backups';dest.mkdir(exist_ok=True);path=dest/(datetime.now().strftime('%Y%m%d-%H%M%S')+'-'+uid()[:6]+'.sqlite3')
        with self.lock,self.db() as db:
            target=sqlite3.connect(path)
            try:db.backup(target)
            finally:target.close()
        return str(path)
    def restore(self,path):
        path=Path(path).resolve()
        if path.parent!=self.root/'backups' or not path.is_file():raise ValueError('Snapshot not found')
        c=sqlite3.connect(f'file:{path}?mode=ro',uri=True)
        try:
            if c.execute('PRAGMA integrity_check').fetchone()[0]!='ok':raise ValueError('Snapshot is corrupted')
            c.execute('SELECT id FROM objects LIMIT 1');c.execute('SELECT id FROM roots LIMIT 1')
            self.backup()
            with self.lock,self.db() as db:c.backup(db)
        finally:c.close()
        with self.db() as db:
            db.execute('CREATE TABLE IF NOT EXISTS deleted_sessions(id TEXT PRIMARY KEY,deleted_at TEXT)')
            db.execute('CREATE TABLE IF NOT EXISTS resource_summaries(id TEXT PRIMARY KEY,summary TEXT,source TEXT,readme TEXT,updated_at TEXT)')
            db.execute('UPDATE objects SET revision=revision+?',(int(datetime.now().timestamp()*1000),))
            db.execute("UPDATE sessions SET status='interrupted' WHERE status='running'")
        from .authoring import restore_objects
        restore_objects(self)
        self.hide_note_metadata()
        self.migrate_research_statuses()
        self.migrate_paper_sessions()
        self.snapshot_widget()
    def snapshot_widget(self):
        data={'updatedAt':stamp(),'projects':self.rows("SELECT id,title,body FROM objects WHERE kind='project' AND status!='archived' ORDER BY updated_at DESC LIMIT 3"),'tasks':self.rows("SELECT id,title,status FROM objects WHERE kind='task' AND status NOT IN ('done','archived') ORDER BY updated_at DESC LIMIT 5"),'ideas':self.rows("SELECT id,title FROM objects WHERE kind='idea' ORDER BY updated_at DESC LIMIT 3")}
        path=self.root/'widget.json';tmp=path.with_suffix('.tmp')
        with self.lock:tmp.write_text(encode(data));tmp.replace(path)
        return data
