"""Common, scoped tools used by both Codex and Pi members."""
from __future__ import annotations
import hashlib, json, os, re, shutil, signal, subprocess, sys, time
from pathlib import Path
from urllib.parse import urlsplit, urlunsplit
from .store import uid,stamp,encode
from .library import scholarly


def canonical_url(value):
    value=value.strip()
    if re.match(r'^10\.\d{4,9}/',value,re.I):value='https://doi.org/'+value
    p=urlsplit(value)
    if p.scheme not in ('https','http','researchos') or not p.netloc:raise ValueError('Use an http(s) or Research OS resource link')
    if p.username or p.password:raise ValueError('Do not share credential-bearing URLs')
    host=p.netloc.lower()
    if host in ('doi.org','dx.doi.org'):return 'https://doi.org/'+p.path.lstrip('/').lower()
    return urlunsplit((p.scheme.lower(),host,p.path.rstrip('/'),p.query,''))


def safe_path(path,roots):
    value=Path(path).expanduser().resolve()
    if not any(value.is_relative_to(Path(root).resolve()) for root in roots):raise ValueError('Path is outside permitted resources/workspaces')
    return value


def share_source(brain,id,member,a):
    url=canonical_url(a.get('url',''));title=str(a.get('title','')).strip()
    if not title:raise ValueError('Source title is required')
    with brain.lock:
        room=brain.room(id);source=next((s for s in room['sources'] if s['url']==url),None)
        if not source:
            source={'id':uid(),'url':url,'title':title[:500],'note':str(a.get('note',''))[:2000],'found_by':[],'read_by':[],'reading':{},'at':stamp()};room['sources'].append(source)
        if member not in source['found_by']:source['found_by'].append(member)
        reading=a.get('reading','found')
        if reading not in ('found','abstract','full_text'):raise ValueError('Unknown reading state')
        source['reading'][member]=reading
        if reading!='found' and member not in source['read_by']:source['read_by'].append(member)
        brain.save(room);brain.sync_shared(room)
    return source


# Storage ceilings apply to tool writes and are monitored during script execution.
MEMBER_BYTES=100_000_000
ROOM_BYTES=300_000_000
MEMBER_FILES=2000
ROOM_FILES=6000
CODE_SUFFIXES={'.py','.sh','.js','.ts','.mjs','.cjs','.bash','.zsh','.rb','.pl','.swift','.r','.jl','.ipynb','.exe','.bin','.command','.scpt'}
RESOURCE_SUFFIXES={'.pdf','.txt','.md','.csv','.tsv','.json','.jsonl','.yaml','.yml','.png','.jpg','.jpeg','.webp','.svg','.bib','.ris','.sdf','.pdb','.cif','.fasta','.fa','.npy','.npz','.parquet'}

def usage(folder):
    size=count=0
    for root,dirs,files in os.walk(folder,followlinks=False):
        dirs[:]=[d for d in dirs if not (Path(root)/d).is_symlink()]
        for name in files:
            path=Path(root)/name
            try:
                if not path.is_symlink():size+=path.stat().st_size;count+=1
            except FileNotFoundError:pass
    return size,count

def check_storage(base,personal,extra_bytes=0,extra_files=0):
    for folder,limit,count_limit in ((personal,MEMBER_BYTES,MEMBER_FILES),(base,ROOM_BYTES,ROOM_FILES)):
        size,count=usage(folder)
        if size+extra_bytes>limit or count+extra_files>count_limit:raise ValueError('Workspace storage limit reached. Remove unnecessary scratch files before continuing.')
    if shutil.disk_usage(base).free<500_000_000:raise ValueError('Less than 500 MB free disk space; workspace writes paused')


def workbench(brain,id,member,a):
    room=brain.room(id)
    if member not in {m['id'] for m in room['members']}:raise ValueError('Unknown member')
    base=brain.path(id);personal=base/'members'/member;shared=base/'shared'
    resources=[Path(r['path']) for r in brain.store.rows('SELECT path FROM roots WHERE enabled=1')]
    read_roots=[*resources,personal,shared]
    action=a.get('action');offset=max(0,min(10000000,int(a.get('offset',0))))
    if action=='resources':
        records=brain.store.rows('SELECT id,kind,title,project_id,status FROM objects ORDER BY rowid LIMIT 100 OFFSET ?',(offset,))
        documents=brain.store.rows('SELECT id,kind,title,path,pages FROM documents WHERE available=1 ORDER BY rowid LIMIT 100 OFFSET ?',(offset,))
        return {'records':records,'documents':documents,'roots':brain.store.rows('SELECT id,path,kind,project_id FROM roots WHERE enabled=1'),'next_offset':offset+100 if len(records)==100 or len(documents)==100 else None}
    if action=='search':return brain.store.search(a.get('query',''),limit=60)
    if action=='read':
        record=brain.store.object(a['id'])
        if record:return record
        return brain.library.read(a['id'],a.get('page'),offset,16000)
    if action=='view_page':return {'image_url':brain.library.page_image(a['id'],int(a.get('page',1))),'citation':f"researchos://document/{a['id']}?page={a.get('page',1)}"}
    if action in ('list','read_file'):
        path=safe_path(a.get('path',''),read_roots)
        if room['phase']=='proposal' and (path.is_relative_to(shared/'reports') or path==shared/'transcript.json'):
            raise ValueError('Peer transcripts and reports are hidden during independent proposals')
        if action=='list':
            if not path.is_dir():raise ValueError('Not a directory')
            names=sorted(path.iterdir(),key=lambda p:p.name)
            return {'entries':[{'path':str(p),'directory':p.is_dir()} for p in names[offset:offset+100]],'next_offset':offset+100 if len(names)>offset+100 else None}
        if path.suffix.lower()=='.pdf':
            import pymupdf
            with pymupdf.open(path) as doc:
                page=int(a.get('page',1))
                if page<1 or page>len(doc):raise ValueError('Page outside document')
                return {'path':str(path),'page':page,'text':doc[page-1].get_text()[:20000]}
        with path.open('r',encoding='utf-8',errors='replace') as file:file.seek(offset);text=file.read(16000);next_offset=file.tell()
        return {'path':str(path),'text':text,'offset':offset,'next_offset':next_offset}
    if action in ('write_file','write_shared'):
        with brain.lock:
            room=brain.room(id)
            destination=personal if action=='write_file' else shared/'work'
            if action=='write_shared' and not room['config']['work_mode']:raise ValueError('Enable Work mode to write shared scripts')
            path=safe_path(destination/a.get('path',''),[destination])
            data=str(a.get('text','')).encode('utf-8')
            if path==destination or len(data)>500000:raise ValueError('Invalid file or content exceeds 500 KB')
            old_size=path.stat().st_size if path.is_file() else 0
            check_storage(base,personal,max(0,len(data)-old_size),0 if path.exists() else 1)
            path.parent.mkdir(parents=True,exist_ok=True);path.write_bytes(data)
        return {'path':str(path),'bytes':path.stat().st_size}
    if action=='publish_file':
        with brain.lock:
            room=brain.room(id)
            path=safe_path(personal/a.get('path',''),[personal,*resources])
            if not path.is_file() or path.stat().st_size>20_000_000:raise ValueError('Publish a file up to 20 MB')
            data=path.read_bytes()
            resource=path.suffix.lower() in RESOURCE_SUFFIXES and not data.startswith(b'#!')
            if not resource and not room['config']['work_mode']:raise ValueError('Only literature/data formats can be published with Work mode off. Enable Work mode to share code.')
            check_storage(base,personal,len(data),1)
            target=shared/('resources' if resource else 'work')/(uid()+'-'+path.name)
            target.parent.mkdir(parents=True,exist_ok=True);target.write_bytes(data)
            artifact={'id':uid(),'member_id':member,'title':a.get('title') or path.name,'path':str(target),'sha256':hashlib.sha256(data).hexdigest(),'at':stamp()}
            room['artifacts'].append(artifact);brain.save(room)
        return artifact
    if action=='share_source':return share_source(brain,id,member,a)
    if action=='sources':return {'sources':room['sources'][offset:offset+50],'total':len(room['sources']),'next_offset':offset+50 if len(room['sources'])>offset+50 else None}
    if action=='acknowledge':
        with brain.lock:
            room=brain.room(id);source=next((s for s in room['sources'] if s['id']==a.get('id')),None)
            if not source:raise ValueError('Source not found')
            if member not in source['read_by']:source['read_by'].append(member)
            source['reading'][member]=a.get('reading','abstract');brain.save(room);brain.sync_shared(room)
        return source
    if action=='read_source':
        source=next((s for s in room['sources'] if s['id']==a.get('id')),None)
        if not source:raise ValueError('Shared source not found')
        return read_public_source(source['url'],offset,a.get('page',1))
    if action=='scholarly_search':
        source=a.get('source','all')
        if source=='all':
            records=[];errors=[]
            for provider in ('pubmed','arxiv'):
                try:records.extend(scholarly(a.get('query',''),provider,6).get('records',[]))
                except Exception as exc:errors.append(provider+': '+str(exc))
            result={'records':records,'errors':errors,'coverage':'PubMed and arXiv; use source=biorxiv for indexed preprints'}
        else:result=scholarly(a.get('query',''),source,8)
        # Returned records are also shared so peers can discover the same evidence.
        items=result if isinstance(result,list) else result.get('records',[])
        for item in items:
            if isinstance(item,dict):
                url=item.get('url') or item.get('link') or ('https://doi.org/'+item['doi'] if item.get('doi') else '')
                if url:
                    try:share_source(brain,id,member,{'url':url,'title':item.get('title',url),'reading':'found','note':item.get('abstract','')[:800]})
                    except ValueError:pass
        return result
    if action=='run':return run_script(brain,id,member,a,personal,resources,shared)
    raise ValueError('Unknown workbench action')


def sandbox_profile(writable,readable):
    def clause(path):return '(subpath '+json.dumps(str(Path(path).resolve()))+')'
    # No network and no writes outside this run. The agent's login stores are
    # absent from the readable list. Failure to apply the OS sandbox is fatal.
    return '\n'.join(['(version 1)','(deny default)','(allow process*)','(allow sysctl-read)','(allow mach-lookup)',
        '(allow file-read-metadata)',
        '(allow file-read* (literal "/") '+ ' '.join(clause(p) for p in readable)+')',
        '(allow file-write* '+clause(writable)+' (literal "/dev/null"))'])


def run_script(brain,id,member,a,personal,resources,shared):
    if not shutil.which('sandbox-exec'):raise RuntimeError('OS sandbox is unavailable; script execution is disabled')
    with brain.lock:
        room=brain.room(id)
        check_storage(brain.path(id),personal,600000,5)
        if room['runs']>=room['config']['max_runs']:raise ValueError('Verification run budget reached')
        room['runs']+=1;brain.save(room)
    source=safe_path(personal/a.get('path',''),[personal,*([shared/'work'] if room['config']['work_mode'] else [])])
    interpreters={'.py':sys.executable,'.sh':'/bin/bash','.js':shutil.which('node')}
    interpreter=interpreters.get(source.suffix)
    if not source.is_file() or not interpreter:raise ValueError('Choose a .py, .sh or .js personal script')
    if source.stat().st_size>500000:raise ValueError('Script exceeds 500 KB')
    args=a.get('args',[])
    if not isinstance(args,list) or not all(isinstance(x,str) and len(x)<10000 for x in args):raise ValueError('Invalid script arguments')
    run_id=uid();folder=personal/'runs'/run_id;folder.mkdir(parents=True)
    snapshot=folder/source.name;data=source.read_bytes();snapshot.write_bytes(data)
    readable=['/System','/usr','/bin','/sbin','/opt','/Library','/dev','/private/var/db',sys.prefix,personal,shared/'resources',shared/'artifacts',shared/'sources.json',*([shared/'work'] if room['config']['work_mode'] else []),*resources]
    profile=folder/'sandbox.sb';profile.write_text(sandbox_profile(folder,readable))
    control=brain.active[id];seconds=min(max(1,int(a.get('seconds',30))),120,max(1,min(control['deadline'],control.get('member_deadlines',{}).get(member,control['deadline']))-time.monotonic()))
    command=[interpreter,str(snapshot),*args]
    # Resource limits are applied inside the sandbox, before running user code.
    launcher='import os,resource,sys; resource.setrlimit(resource.RLIMIT_CPU,(120,120)); resource.setrlimit(resource.RLIMIT_FSIZE,(10000000,10000000)); resource.setrlimit(resource.RLIMIT_NOFILE,(128,128)); resource.setrlimit(resource.RLIMIT_NPROC,(32,32)); os.execv(sys.argv[1],sys.argv[1:])'
    env={'PATH':'/opt/homebrew/bin:/usr/bin:/bin','HOME':str(folder),'TMPDIR':str(folder),'PYTHONDONTWRITEBYTECODE':'1','PYTHONUNBUFFERED':'1'}
    log=folder/'run.log';metadata={'command':command,'sha256':hashlib.sha256(data).hexdigest(),'script':str(snapshot),'log':str(log),'seconds_limit':seconds,'started_at':stamp()}
    metadata['python_version']=sys.version.split()[0]
    metadata['inputs']=[]
    for arg in args:
        candidate=Path(arg) if Path(arg).is_absolute() else folder/arg
        try:
            candidate=safe_path(candidate,[personal,shared,*resources])
            if candidate.is_file():
                info=candidate.stat();metadata['inputs'].append({'path':str(candidate),'size':info.st_size,'mtime_ns':info.st_mtime_ns,'sha256':hashlib.sha256(candidate.read_bytes()).hexdigest() if info.st_size<=20000000 else None})
        except (ValueError,OSError):pass
    key=brain.entry(id,member,'run',0,'running',metadata);status='failed';start=time.monotonic()
    try:
        with log.open('wb') as output:
            process=subprocess.Popen(['/usr/bin/sandbox-exec','-f',str(profile),sys.executable,'-c',launcher,*command],cwd=folder,env=env,stdout=output,stderr=subprocess.STDOUT,start_new_session=True)
            while process.poll() is None:
                try:check_storage(brain.path(id),personal)
                except ValueError as exc:
                    os.killpg(process.pid,signal.SIGKILL);process.wait();status='storage_limited';metadata['error']=str(exc);break
                if control['stop'].is_set() or time.monotonic()-start>=seconds:
                    os.killpg(process.pid,signal.SIGKILL);process.wait();status='interrupted' if control['stop'].is_set() else 'timed_out';break
                time.sleep(0.1)
            else:status='completed' if process.returncode==0 else 'failed'
            # Kill any lingering children in the run's process group.
            try:os.killpg(process.pid,signal.SIGKILL)
            except ProcessLookupError:pass
            metadata['exit_code']=process.returncode
    except Exception as exc:metadata['error']=str(exc)
    metadata['duration_seconds']=round(time.monotonic()-start,3)
    with log.open(errors='replace') if log.exists() else open(os.devnull) as output:metadata['output']=output.read(20000)
    brain.finish_entry(key,status,metadata)
    brain.report(id)
    (folder/'result.json').write_text(encode({'status':status,**metadata}))
    return {'status':status,**metadata}


def read_public_source(url,offset=0,page=1):
    """Fetch public literature only; local/private hosts and redirects are rejected."""
    import ipaddress,socket,urllib.request
    from html.parser import HTMLParser
    def validate(value):
        parsed=urlsplit(value)
        if parsed.scheme not in ('http','https') or parsed.username or parsed.password:raise ValueError('Only public web literature can be fetched')
        addresses=socket.getaddrinfo(parsed.hostname,parsed.port or (443 if parsed.scheme=='https' else 80),type=socket.SOCK_STREAM)
        if not addresses or any(not ipaddress.ip_address(item[4][0]).is_global for item in addresses):raise ValueError('Private network addresses cannot be fetched')
    class Redirect(urllib.request.HTTPRedirectHandler):
        def redirect_request(self,req,fp,code,msg,headers,newurl):
            validate(newurl);return super().redirect_request(req,fp,code,msg,headers,newurl)
    validate(url)
    request=urllib.request.Request(url,headers={'User-Agent':'ResearchOS/2.1 literature reader'})
    with urllib.request.build_opener(Redirect()).open(request,timeout=15) as response:
        content_type=response.headers.get('Content-Type','');data=response.read(5_000_001)
        if len(data)>5_000_000:raise ValueError('Source exceeds 5 MB; connect a downloaded copy through Papers')
        resolved=response.url
    digest=hashlib.sha256(data).hexdigest()
    if data.startswith(b'%PDF'):
        import pymupdf
        with pymupdf.open(stream=data,filetype='pdf') as pdf:
            if not 1<=int(page)<=len(pdf):raise ValueError('Page outside document')
            text=pdf[int(page)-1].get_text()
    else:
        text=data.decode('utf-8',errors='replace')
        if 'html' in content_type or '<html' in text[:1000].lower():
            class Text(HTMLParser):
                def __init__(self):super().__init__();self.parts=[];self.skip=0
                def handle_starttag(self,tag,attrs):
                    if tag in ('script','style'):self.skip+=1
                def handle_endtag(self,tag):
                    if tag in ('script','style'):self.skip=max(0,self.skip-1)
                def handle_data(self,value):
                    if not self.skip and value.strip():self.parts.append(value.strip())
            parser=Text();parser.feed(text);text='\n'.join(parser.parts)
    return {'url':resolved,'sha256':digest,'text':text[offset:offset+20000],'offset':offset,'total_chars':len(text),'page':page if data.startswith(b'%PDF') else None,'note':'Fetched text; reading acknowledgement must reflect actual use, not just download.'}
