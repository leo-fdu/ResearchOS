from __future__ import annotations
import hashlib, json, os, re, subprocess, sys, threading, time, html, urllib.request, urllib.parse, xml.etree.ElementTree as ET
from pathlib import Path
from .store import stamp, uid, encode

IGNORED={'.git','.venv','venv','node_modules','__pycache__','.build','.papermind-backups','.codex','.aws','.ssh','build','dist','checkpoints','wandb'}
TEXT={'.md','.txt','.py','.json','.yaml','.yml','.toml','.csv','.tsv','.log','.ipynb','.rs','.swift','.js','.ts','.sh','.tex','.bib','.r','.cpp','.h'}
def digest(path):
    h=hashlib.sha256()
    with path.open('rb') as f:
        for b in iter(lambda:f.read(1024*1024),b''):h.update(b)
    return h.hexdigest()

class Library:
    def __init__(self,store):self.store=store;self.scan_lock=threading.RLock();self.root_locks={};self.pending_roots={};self.organize_lock=threading.Lock();self.cancelled=set();self.processes={}
    def start(self,root_id,organize=False):
        with self.scan_lock:
            previous=self.pending_roots.get(root_id)
            if previous and self.store.one("SELECT id FROM jobs WHERE id=? AND status IN ('queued','running')",(previous,)):
                if organize:raise ValueError('This folder has an active task. Wait before organizing it.')
                return {'job_id':previous,'already_queued':True}
            root=self.store.one('SELECT * FROM roots WHERE id=? AND enabled=1',(root_id,))
            if not root:raise ValueError('Resource folder not found')
            if organize and root['kind']!='papers':raise ValueError('Only paper libraries can be organized')
            job=self.store.job('Organize papers' if organize else 'Refresh library');self.pending_roots[root_id]=job
            threading.Thread(target=self._run,args=(root,job,organize),daemon=True).start();return {'job_id':job}
    def cancel(self,job):
        self.cancelled.add(job)
        process=self.processes.get(job)
        if process and process.poll() is None:process.terminate()
        self.store.job_update(job,'cancelled','Stop requested. Completed work is preserved.')
        return {'ok':True}
    def check_cancel(self,job):
        if job in self.cancelled:raise InterruptedError('Stopped. Run again to continue.')
    def _run(self,root,job,organize):
        try:
            organization=self.organize(root,job) if organize else None
            result=self.scan(root,job)
            if organization is not None:result['organization']=organization
            self.store.job_update(job,'completed',encode(result))
        except InterruptedError as exc:self.store.job_update(job,'cancelled',str(exc))
        except Exception as exc:self.store.job_update(job,'cancelled' if job in self.cancelled else 'failed',str(exc))
        finally:
            self.processes.pop(job,None)
            with self.scan_lock:
                if self.pending_roots.get(root['id'])==job:self.pending_roots.pop(root['id'],None)
    def organize(self,root,job):
        base=Path(root['path'])
        if not (base/'pdf').is_dir():raise ValueError('PaperMind library requires a pdf/ subfolder. Connect the parent folder.')
        with self.organize_lock:
            self.check_cancel(job)
            env=dict(os.environ,PAPERMIND_ROOT=str(base),PYTHONUNBUFFERED='1')
            p=subprocess.Popen([sys.executable,'-S',str(Path(__file__).resolve().parents[1]/'launch.py'),'--organize'],cwd=Path(__file__).resolve().parents[1],env=env,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,text=True)
            self.processes[job]=p
            log=[]
            for line in p.stdout:
                log.append(line.rstrip());self.store.job_update(job,'running','\n'.join(log[-40:]))
            if p.wait()!=0:raise ValueError('PaperMind organization failed: \n'+'\n'.join(log[-20:]))
            summary=next((line.removeprefix('ORGANIZE_RESULT: ') for line in reversed(log) if line.startswith('ORGANIZE_RESULT: ')),None)
            if summary is None:raise ValueError('PaperMind did not return an organization summary')
            return json.loads(summary)
    def scan(self,root,job=None):
        with self.root_locks.setdefault(root['id'],threading.Lock()):
            self.check_cancel(job)
            if job:self.store.job_update(job,'running','Refreshing folder')
            if root['kind'] in ('repo','data'):return self._scan_catalog(root,job)
            base=Path(root['path']);seen=set();processed=0;skipped=0;errors=[]
            if not base.is_dir():
                with self.store.db(fast=True) as db:db.execute('UPDATE roots SET error=? WHERE id=?',('Folder offline or missing',root['id']))
                raise ValueError('Folder offline or missing. Previous cache preserved.')
            for folder,dirs,files in os.walk(base,followlinks=False):
                dirs[:]=[d for d in dirs if d not in IGNORED and not d.startswith('.')]
                for name in files:
                    self.check_cancel(job)
                    path=Path(folder)/name
                    if name.startswith('.') or any(x in name.lower() for x in ('credential','secret','api_key','id_rsa','auth.json')):continue
                    ext=path.suffix.lower()
                    if (ext not in TEXT|{'.pdf'} and root['kind']!='data') or path.is_symlink():continue
                    try:
                        self.store.allowed_path(path);stat=path.stat()
                        metadata_only=root['kind']=='data' or stat.st_size>(100*1024*1024 if ext=='.pdf' else 8*1024*1024) or (ext in {'.csv','.tsv','.log'} and stat.st_size>256*1024)
                        seen.add(str(path));old=self.store.one('SELECT * FROM documents WHERE path=?',(str(path),))
                        if old and old['mtime']==stat.st_mtime_ns and old['size']==stat.st_size and old['available'] and (old['kind']=='pdf' or len(old['body'])<=200000) and (not metadata_only or old['kind']=='data'):
                            skipped+=1;continue
                        hash=digest(path) if not metadata_only else '';id=old['id'] if old else None
                        if old and ext=='.pdf' and hash and old['hash']!=hash:
                            with self.store.db(fast=True) as db:
                                db.execute('UPDATE documents SET path=?,available=0,error=? WHERE id=?',(str(path)+'.previous-'+old['hash'][:12],'PDF content changed. This reference points to the old version. Original path: '+str(path),old['id']))
                                db.execute('DELETE FROM search_index WHERE id=?',(old['id'],))
                            id=None
                        if not id and hash:
                            moved=self.store.rows('SELECT * FROM documents WHERE root_id=? AND hash=?',(root['id'],hash))
                            missing=next((x for x in moved if not Path(x['path']).exists()),None)
                            if missing:id=missing['id']
                        replacing=bool(id)
                        id=id or uid();title=path.stem;pages=0;error=''
                        if metadata_only:
                            body=encode({'path':str(path),'bytes':stat.st_size,'modified_ns':stat.st_mtime_ns,'note':'Metadata only; content was not read or hashed'})
                        elif ext=='.pdf':
                            import pymupdf
                            with pymupdf.open(path) as pdf:
                                pages=len(pdf);parts=[];size=0
                                for i,page in enumerate(pdf):
                                    text=page.get_text();parts.append(f'\n<!-- Page {i+1} -->\n{text}');size+=len(text)
                                    if size>2_000_000:break
                                body=''.join(parts)
                                if size>2_000_000:error='Text exceeds 2 million characters. Only the beginning is cached; read original pages as needed.'
                                elif not body.strip() or sum(len(x) for x in parts)<pages*30:error='Little extractable text. Organize papers to run OCR'
                        elif ext=='.ipynb':
                            notebook=json.loads(path.read_text(encoding='utf-8'))
                            body='\n\n'.join(''.join(c.get('source',[])) for c in notebook.get('cells',[]))[:200000]
                            error='Notebook Markdown and code cells only; outputs and embedded images excluded'
                        else:
                            with path.open(encoding='utf-8',errors='replace') as file:body=file.read(200001)
                            if len(body)>200000:body=body[:200000];error='First 200,000 characters cached. The assistant can read the original file.'
                        with self.store.db(fast=True) as db:
                            db.execute('INSERT OR REPLACE INTO documents VALUES(?,?,?,?,?,?,?,?,?,?,?,?)',(id,root['id'],str(path),title,'data' if metadata_only else 'pdf' if ext=='.pdf' else root['kind'],hash,stat.st_mtime_ns,stat.st_size,body,1,pages,error))
                            if replacing:db.execute('DELETE FROM search_index WHERE id=?',(id,))
                            db.execute('INSERT INTO search_index VALUES(?,?,?)',(id,title,body))
                        processed+=1
                    except Exception as exc:
                        errors.append(f'{name}: {exc}')
                        with self.store.db(fast=True) as db:
                            oldrow=db.execute('SELECT id FROM documents WHERE path=?',(str(path),)).fetchone()
                            if oldrow:
                                db.execute('UPDATE documents SET available=0,error=? WHERE id=?',(str(exc),oldrow[0]));db.execute('DELETE FROM search_index WHERE id=?',(oldrow[0],))
                    if job and (processed+skipped)%20==0:self.store.job_update(job,'running',f'Updated {processed}, Unchanged {skipped}, Error {len(errors)}')
            with self.store.db(fast=True) as db:
                for d in db.execute('SELECT id,path FROM documents WHERE root_id=?',(root['id'],)).fetchall():
                    if d['path'] not in seen:
                        db.execute('UPDATE documents SET available=0 WHERE id=?',(d['id'],));db.execute('DELETE FROM search_index WHERE id=?',(d['id'],))
                db.execute('UPDATE roots SET last_scan=?,error=? WHERE id=?',(stamp(),'\n'.join(errors[:20]),root['id']))
            return {'updated':processed,'unchanged_or_skipped':skipped,'errors':errors[:30]}
    def _scan_catalog(self,root,job):
        """Register one entry per immediate repository/dataset, never its files."""
        base=Path(root['path'])
        if not base.is_dir():raise ValueError('Folder offline. Existing entries preserved.')
        if root['kind']=='repo' and (base/'.git').exists():
            directories=[base]
        else:
            directories=sorted((p for p in base.iterdir() if not p.name.startswith('.')
                and p.name not in IGNORED and not p.is_symlink() and p.is_dir()),key=lambda p:p.name.lower())
            if not directories:directories=[base]
        entries=[]
        for directory in directories:
            self.check_cancel(job)
            readme=next((directory/name for name in ('README.md','README','README.txt','README.rst','readme.md','readme.txt','Readme.md')
                if (directory/name).is_file() and not (directory/name).is_symlink()),None)
            old=self.store.one('SELECT id FROM documents WHERE path=?',(str(directory),))
            ident=old['id'] if old else uid()
            label='Repository' if root['kind']=='repo' else 'Dataset'
            body=f"# {directory.name}\n\n{label} folder: `{directory}`\n\n"
            body+=(f"README: `{readme}`.Read this file when you need context: README." if readme
                else 'No README in this folder. Purpose, source and version are not documented yet; add them through a discussion.')
            body+='\n\nThis entry stores the folder and README paths only. Internal files are not traversed or indexed.'
            entries.append((ident,root['id'],str(directory),directory.name,root['kind']+'_catalog','',0,0,body,1,0,''))
        with self.store.db(fast=True) as db:
            db.execute('DELETE FROM search_index WHERE id IN (SELECT id FROM documents WHERE root_id=?)',(root['id'],))
            db.execute('UPDATE documents SET available=0 WHERE root_id=?',(root['id'],))
            db.executemany('INSERT OR REPLACE INTO documents VALUES(?,?,?,?,?,?,?,?,?,?,?,?)',entries)
            db.executemany('INSERT INTO search_index VALUES(?,?,?)',[(r[0],r[3],r[8]) for r in entries])
            db.execute('UPDATE roots SET last_scan=?,error=? WHERE id=?',(stamp(),'',root['id']))
        return {'entries':len(entries),'scope':'immediate_directories_only','errors':[]}
    def read(self,id,page=None,start=0,limit=16000):
        d=self.store.document(id);path=self.store.allowed_path(d['path'])
        if d['kind'] in ('repo_catalog','data_catalog'):
            if not d['available'] or not path.is_dir():raise ValueError('Folder is offline')
            return {'id':id,'title':d['title'],'path':str(path),'text':d['body'],'catalog_only':True}
        if not path.is_file() or not d['available']:raise ValueError(d.get('error') or 'Source file missing. Refresh the library.')
        if d['kind']=='data':return {'id':id,'text':d['body'],'metadata_only':True}
        if d['kind']=='pdf' and digest(path)!=d['hash']:raise ValueError('PDF content changed. Refresh the library and select the new version.')
        if d['kind']=='pdf' and page is not None:
            import pymupdf
            with pymupdf.open(path) as doc:
                page=int(page)
                if not 1<=page<=len(doc):raise ValueError('Page number out of range')
                text=doc[page-1].get_text()
            return {'id':id,'title':d['title'],'page':page,'text':text,'citation':f'researchos://document/{id}?page={page}'}
        # Re-read mutable text so file edits aren't hidden by a stale index.
        text=d['body'] if d['kind']=='pdf' else path.read_text(encoding='utf-8',errors='replace')
        start=max(0,int(start));limit=max(1,min(40000,int(limit)))
        return {'id':id,'title':d['title'],'path':str(path),'text':text[start:start+limit],'start':start,'total_chars':len(text),'truncated':start+limit<len(text),'citation':f'researchos://document/{id}'}
    def page_image(self,id,page):
        import pymupdf,base64
        d=self.store.document(id);path=self.store.allowed_path(d['path'])
        if not d['available'] or not path.is_file() or digest(path)!=d['hash']:raise ValueError('PDF is offline or changed. Refresh the library.')
        with pymupdf.open(path) as pdf:
            if not 1<=int(page)<=len(pdf):raise ValueError('Page number out of range')
            pix=pdf[int(page)-1].get_pixmap(matrix=pymupdf.Matrix(1.3,1.3),alpha=False)
            return 'data:image/png;base64,'+base64.b64encode(pix.tobytes('png')).decode()
    def save_text(self,id,text,expected_hash):
        d=self.store.document(id);p=self.store.allowed_path(d['path'])
        if p.suffix.lower() not in {'.md','.txt'}:raise ValueError('Only Markdown and plain-text notes can be edited')
        if digest(p)!=expected_hash:raise ValueError('File changed externally. Reopen it before editing.')
        if len(text)>2_000_000:raise ValueError('Note is too long')
        backup=self.store.root/'file-backups';backup.mkdir(exist_ok=True)
        (backup/(uid()+'-'+p.name)).write_bytes(p.read_bytes())
        temp=p.with_name('.'+p.name+'.researchos-'+uid());temp.write_text(text);temp.replace(p)
        return self.start(d['root_id'])

_fetch_cache={};_fetch_lock=threading.Lock();_arxiv_at=0
def fetch(url):
    global _arxiv_at
    with _fetch_lock:
        cached=_fetch_cache.get(url)
        if cached and time.monotonic()-cached[0]<300:return cached[1]
        if 'export.arxiv.org' in url:
            time.sleep(max(0,3-(time.monotonic()-_arxiv_at)));_arxiv_at=time.monotonic()
    data=_fetch_uncached(url)
    with _fetch_lock:
        if len(_fetch_cache)>100:_fetch_cache.clear()
        _fetch_cache[url]=(time.monotonic(),data)
    return data

def _fetch_uncached(url):
    req=urllib.request.Request(url,headers={'User-Agent':'ResearchOS/2.0 (personal academic research)'})
    with urllib.request.urlopen(req,timeout=25) as r:return r.read(5_000_000)

def scholarly(query,source='pubmed',limit=8):
    limit=max(1,min(20,int(limit)));query=query[:1000]
    if source=='arxiv':
        url='https://export.arxiv.org/api/query?'+urllib.parse.urlencode({'search_query':query if ':' in query else 'all:'+query,'max_results':limit,'sortBy':'relevance'})
        root=ET.fromstring(fetch(url));ns={'a':'http://www.w3.org/2005/Atom'};records=[]
        for e in root.findall('a:entry',ns):
            txt=lambda tag:e.findtext('a:'+tag,'',ns).strip()
            records.append({'title':txt('title'),'abstract':txt('summary'),'url':txt('id'),'published':txt('published'),'authors':[x.findtext('a:name','',ns) for x in e.findall('a:author',ns)],'type':'preprint','source':'arXiv'})
        return {'records':records,'query':query,'source':'arXiv','url':url}
    # Europe PMC provides a structured PubMed and preprint index, including bioRxiv.
    filt='SRC:MED' if source=='pubmed' else '(SRC:PPR AND (DOI:10.1101/*))' if source=='biorxiv' else ''
    q=f'({query}) AND {filt}' if filt else query
    url='https://www.ebi.ac.uk/europepmc/webservices/rest/search?'+urllib.parse.urlencode({'query':q,'format':'json','resultType':'core','pageSize':limit})
    data=json.loads(fetch(url));records=[]
    for x in data.get('resultList',{}).get('result',[]):
        records.append({'title':x.get('title'),'authors':x.get('authorString'),'abstract':html.unescape(re.sub('<[^>]+>',' ',x.get('abstractText') or '')),'doi':x.get('doi'),'pmid':x.get('pmid'),'year':x.get('pubYear'),'type':'preprint' if x.get('source')=='PPR' else 'publication','source':x.get('source'),'url':'https://doi.org/'+x['doi'] if x.get('doi') else 'https://europepmc.org/article/'+x.get('source','')+'/'+x.get('id','')})
    return {'records':records,'query':q,'total':data.get('hitCount'),'source':'Europe PMC','note':'bioRxiv search uses Europe PMC records for 10.1101 preprints, including medRxiv. It is not a complete real-time bioRxiv feed.' if source=='biorxiv' else ''}
