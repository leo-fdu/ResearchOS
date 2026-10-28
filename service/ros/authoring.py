"""File-backed Markdown, experiment journals and a unified relation graph."""
from __future__ import annotations
import hashlib,json,os,re,shutil,time
from pathlib import Path
from .store import Conflict,stamp,uid,encode

GUIDE='''Workspace authoring: Projects and Ideas have experiment logs. To append one use save_record(kind="note", title=..., body=Markdown analysis, data={"entry_type":"experiment_log","owner_id":PROJECT_OR_IDEA_ID,"attachments":[{"path":ABSOLUTE_RESULT_PATH}]}). List entries with list_records(kind="experiment_log", project_id=OWNER_ID) or read_record(id="researchos://journal/OWNER_ID"). Edit an entry with its id/revision and preserve its data. Attach actual outputs only; never invent results. Files up to 100 MiB are copied to the log, larger files/folders remain explicitly marked references. Existing attachment paths are retained on edits. Images and the first page of PDF figures render inline in experiment logs; clicking opens a larger viewer. Attach important existing charts as files with an optional caption (attachments=[{"path":ABSOLUTE_FIGURE_PATH,"caption":"What the figure shows, including units and limitations"}]) instead of only pasting filesystem paths into the analysis. Preserve attachment captions and order when editing. CSV and TSV attachments render as bounded tables directly in the journal (UTF-8/UTF-16; comma-separated CSV or tab-separated TSV). Users can expand them, treat the first row as headers or data, and copy the preview as a Markdown table. Attach the actual CSV for important numeric results instead of only writing its path. Table previews are not plots; do not claim a graph was generated unless you actually generate one. Other raw data files remain attachments.
For a paper note use save_record(kind="note",title=...,body=...,data={"paper_id":PAPER_ID,"category":"paper"}); it is saved as Markdown in the connected notes/paper folder and automatically linked to the paper. Ordinary notes can use category blog/concepts/paper; preserve existing categories. AGENTS.md and INDEX.md in notes are terminal metadata, not research notes.
All editable Markdown is shared with Typora. For any project/idea/note, file note, repo/dataset description, read_record(id="researchos://markdown/RESOURCE_ID") returns current text, path and hash. To edit file-backed resources through existing tools use save_record(kind="note",title="Markdown edit",body=FULL_NEW_TEXT,data={"operation":"edit_markdown","target_id":RESOURCE_ID,"expected_hash":HASH_FROM_READ}). This edits that resource, not a new note. Re-read on conflict; never overwrite newer user edits. Normal save_record updates for objects synchronize their bound file too. Project/Idea status, title and card summaries remain structured properties; their Markdown file edits the detailed body. Repository/dataset descriptions use their README.md (created only when explicitly editing). Do not recursively index repos or data.
All Projects, Ideas, Brainstorm discussions, papers, notes, repositories and datasets can be linked with link_records using discovered IDs. Use read_record(id="researchos://graph") to inspect the full relation graph, including structural associations. Brainstorm members remain read-only toward research records; these authoring capabilities belong to Research assistant. Preserve source provenance and explicit uncertainty.'''

def init(store):
 with store.db() as db:db.execute('CREATE TABLE IF NOT EXISTS markdown_files(id TEXT PRIMARY KEY,path TEXT UNIQUE,hash TEXT)')

def sha(path):return hashlib.sha256(Path(path).read_bytes()).hexdigest()
def safe(path):
 path=Path(path)
 if any(p.is_symlink() for p in (path,*path.parents) if str(p) not in ('/var','/tmp')):raise ValueError('Refusing to edit a symbolic link')
 return path

def replace(store,path,text,expected=None):
 path=safe(path);path.parent.mkdir(parents=True,exist_ok=True)
 if expected is not None and (not path.exists() or sha(path)!=expected):raise Conflict('Markdown changed in another editor. Refresh before saving.')
 if path.exists():
  backup=store.root/'backups'/'markdown';backup.mkdir(parents=True,exist_ok=True)
  shutil.copy2(path,backup/(uid()+'-'+path.name))
 temp=path.with_name('.'+path.name+'.'+uid()+'.tmp')
 try:temp.write_text(text,encoding='utf-8');temp.replace(path)
 finally:temp.unlink(missing_ok=True)
 return sha(path)

def notes_root(store):
 values=store.rows("SELECT * FROM roots WHERE enabled=1 AND kind='notes' ORDER BY rowid")
 if not values:raise ValueError('Connect a Notes folder before creating a file note')
 if len(values)>1:
  selected=store.setting('notes_write_root','')
  match=next((x for x in values if x['id']==selected),None)
  if not match:raise ValueError('Multiple Notes folders: choose a default notes_write_root in settings')
  return Path(match['path'])
 return Path(values[0]['path'])

def validate_record(store,value,source):
 data=dict(value.get('data',{}));kind=value['kind']
 if kind!='note':return data
 if data.get('entry_type')=='experiment_log':
  owner=store.object(data.get('owner_id',''))
  if not owner or owner['kind'] not in ('project','idea'):raise ValueError('Experiment log requires a Project or Idea')
  value['project_id']=owner['id'] if owner['kind']=='project' else owner['project_id']
  items=data.get('attachments',[])
  if not isinstance(items,list) or len(items)>40:raise ValueError('Choose up to 40 attachments')
  for item in items:
   if not isinstance(item,dict) or not item.get('path'):raise ValueError('Attachment path required')
   if not isinstance(item.get('caption',''),str) or len(item.get('caption',''))>4000:raise ValueError('Attachment caption must be text up to 4000 characters')
   p=Path(item['path']).expanduser().resolve()
   if not p.exists():raise ValueError('Attachment not found: '+str(p))
   if source.startswith('session:') and not p.is_relative_to((store.root/'journals').resolve()):
    store.allowed_path(p)
 elif data.get('paper_id'):
  paper=store.document(data['paper_id'])
  if paper['kind']!='pdf' or not paper['available']:raise ValueError('Choose an available paper')
  data['category']='paper';notes_root(store)
 if data.get('category') and data['category'] not in ('blog','concepts','paper'):raise ValueError('Unknown Notes category')
 return data

def attach_files(store,ident,data):
 if data.get('entry_type')!='experiment_log':return data
 dest=store.root/'journals'/data['owner_id']/ident/'attachments';items=[]
 for item in data.get('attachments',[]):
  path=Path(item['path']).expanduser().resolve()
  if path.is_relative_to(dest):items.append(item);continue
  mode='reference'
  if path.is_file() and path.stat().st_size<=100*1024*1024:
   dest.mkdir(parents=True,exist_ok=True);target=dest/(uid()[:8]+'-'+path.name);shutil.copy2(path,target);mode='copy'
  else:target=path
  items.append({'path':str(target),'name':item.get('name') or path.name,'caption':item.get('caption',''),'mode':mode,'original_path':str(path),'bytes':path.stat().st_size if path.is_file() else None})
 return {**data,'attachments':items}

def object_path(store,obj):
 if obj['kind']=='note' and obj['data'].get('entry_type')=='experiment_log':return store.root/'journals'/obj['data']['owner_id']/obj['id']/'entry.md'
 if obj['kind']=='note' and store.one("SELECT id FROM roots WHERE kind='notes' AND enabled=1 LIMIT 1"):
  category=obj['data'].get('category','concepts');title=re.sub(r'[^\w\u3400-\u9fff .-]+','-',obj['title'])[:90].strip(' .') or 'Note'
  return notes_root(store)/category/(title+'--'+obj['id'][:8]+'.md')
 return store.root/'content'/obj['kind']/(obj['id']+'.md')

def push_object(store,obj,db):
 if obj['kind'] not in ('project','idea','note','plan','task'):return
 ident=obj['id'];binding=store.one('SELECT * FROM markdown_files WHERE id=?',(ident,))
 if not binding and obj['kind']!='note':return
 path=safe(binding['path']) if binding else safe(object_path(store,obj))
 expected=binding['hash'] if binding else None
 # Preserve the filename when changing a note's folder; never move a user's file silently outside Notes.
 target=path
 if binding and obj['kind']=='note' and obj['data'].get('entry_type')!='experiment_log':
  root=notes_root(store) if store.one("SELECT id FROM roots WHERE kind='notes' AND enabled=1 LIMIT 1") else None
  if root and path.is_relative_to(root) and len(path.relative_to(root).parts)==2:
   target=safe(root/obj['data'].get('category','concepts')/path.name)
 if target!=path and target.exists():raise Conflict('A note already exists at the destination')
 unchanged=binding and path.is_file() and sha(path)==expected and path.read_text(encoding='utf-8')==obj['body']
 value=expected if unchanged else replace(store,path,obj['body'],expected)
 if target!=path:
  target.parent.mkdir(parents=True,exist_ok=True);path.rename(target);path=target
 db.execute('INSERT OR REPLACE INTO markdown_files VALUES(?,?,?)',(ident,str(path),value))
 if obj['kind']=='note':
  for key,relation in [('paper_id','note_for'),('owner_id','experiment_log')]:
   if obj['data'].get(key):db.execute('INSERT OR IGNORE INTO edges VALUES(?,?,?,?,?)',(uid(),ident,obj['data'][key],relation,''))

def sync(store,ident=None):
 with store.lock:
  rows=store.rows('SELECT * FROM markdown_files'+(' WHERE id=?' if ident else ''),(ident,) if ident else ())
  for item in rows:
   path=Path(item['path'])
   try:safe(path)
   except ValueError:continue
   if not path.is_file():continue
   document=store.one('SELECT root_id,available FROM documents WHERE id=?',(item['id'],))
   if document and (not document['available'] or not store.one('SELECT id FROM roots WHERE id=? AND enabled=1',(document['root_id'],))):continue
   if path.stat().st_size>2_000_000:continue
   current=sha(path)
   if current==item['hash']:continue
   try:text=path.read_text(encoding='utf-8')
   except (OSError,UnicodeDecodeError):continue
   obj=store.object(item['id'])
   with store.db() as db:
    if obj:
     if len(text)>500_000:continue
     updated={**obj,'body':text,'revision':obj['revision']+1,'updated_at':stamp()}
     db.execute('UPDATE objects SET body=?,revision=?,updated_at=? WHERE id=?',(text,updated['revision'],updated['updated_at'],obj['id']))
     db.execute('INSERT INTO audit(object_id,action,before,after,source,at) VALUES(?,?,?,?,?,?)',(obj['id'],'update',encode(obj),encode(updated),'external-markdown',stamp()))
     title=obj['title']
    else:
     d=store.one('SELECT * FROM documents WHERE id=?',(item['id'],))
     if not d:continue
     title=d['title'];db.execute('UPDATE documents SET body=?,hash=?,mtime=?,size=? WHERE id=?',(text,current,path.stat().st_mtime_ns,path.stat().st_size,item['id']))
    db.execute('DELETE FROM search_index WHERE id=?',(item['id'],));db.execute('INSERT INTO search_index VALUES(?,?,?)',(item['id'],title,text))
    db.execute('UPDATE markdown_files SET hash=? WHERE id=?',(current,item['id']))

def markdown(store,ident):
 with store.lock:
  sync(store,ident);bound=store.one('SELECT * FROM markdown_files WHERE id=?',(ident,))
  if not bound:
   obj=store.object(ident)
   if obj:
    if obj['kind'] not in ('project','idea','note','plan','task'):raise ValueError('This resource is not editable Markdown')
    path=object_path(store,obj);text=obj['body']
   else:
    d=store.document(ident)
    if not d['available']:raise ValueError('Resource is unavailable')
    path=store.allowed_path(d['path']);text=d['body']
    if d['kind'] in ('repo_catalog','data_catalog'):
     path=next((path/name for name in ('README.md','readme.md','Readme.md') if (path/name).is_file()),path/'README.md')
     text='# '+d['title']+'\n\n'
    elif path.suffix.lower() not in ('.md','.markdown','.txt'):raise ValueError('This resource is not Markdown or text')
   safe(path)
   if not path.exists():replace(store,path,text)
   value=sha(path)
   with store.db() as db:db.execute('INSERT OR REPLACE INTO markdown_files VALUES(?,?,?)',(ident,str(path),''))
   sync(store,ident)
   bound={'path':str(path),'hash':value}
  path=safe(bound['path'])
  if not store.object(ident):
   d=store.document(ident)
   if not d['available']:raise ValueError('Resource is unavailable')
   store.allowed_path(path)
  if not path.is_file():raise ValueError('Markdown file was moved or removed; restore it before editing')
  return {'id':ident,'path':str(path),'hash':sha(path),'text':path.read_text(encoding='utf-8'),'offset_unit':'characters'}

def save_markdown(store,ident,text,expected):
 if not isinstance(text,str) or len(text)>500_000:raise ValueError('Markdown content is too large')
 with store.lock:
  current=markdown(store,ident)
  if expected!=current['hash']:raise Conflict('Markdown changed. Read it again before saving.')
  replace(store,current['path'],text,expected);sync(store,ident)
  return markdown(store,ident)

def journals(store,owner):
 target=store.object(owner)
 if not target or target['kind'] not in ('project','idea'):raise ValueError('Project or Idea not found')
 sync(store)
 values=[store.object(x['id']) for x in store.rows("SELECT id FROM objects WHERE kind='note' AND json_extract(data,'$.entry_type')='experiment_log' AND json_extract(data,'$.owner_id')=? ORDER BY created_at DESC",(owner,))]
 return values

def graph(store):
 sync(store);nodes={};edges=[]
 for o in store.state(sync_files=False)['objects']:
  if o['kind'] not in ('project','idea','note'):continue
  nodes[o['id']]={'id':o['id'],'title':o['title'],'kind':o['kind'],'project_id':o['project_id'],'uri':'researchos://object/'+o['id']}
  for key,relation in [('project_id','belongs_to')]:
   if o[key]:edges.append({'source':o['id'],'target':o[key],'relation':relation})
 for d in store.rows("SELECT d.*,r.project_id FROM documents d JOIN roots r ON r.id=d.root_id WHERE d.available=1 AND r.enabled=1"):
  kind={'pdf':'paper','repo_catalog':'repo','data_catalog':'data','notes':'note'}.get(d['kind'])
  if not kind:continue
  nodes[d['id']]={'id':d['id'],'title':d['title'],'kind':kind,'project_id':d['project_id'],'path':d['path'],'uri':'researchos://document/'+d['id']}
  if d['project_id']:edges.append({'source':d['id'],'target':d['project_id'],'relation':'belongs_to'})
 if store.one("SELECT name FROM sqlite_master WHERE name='brainstorm_rooms'"):
  for row in store.rows('SELECT payload FROM brainstorm_rooms'):
   r=json.loads(row['payload'])
   if r.get('deleted_at'):continue
   nodes[r['id']]={'id':r['id'],'title':r['topic'],'kind':'brainstorm','project_id':r.get('project_id',''),'uri':'researchos://brainstorm/'+r['id']}
   for key in ['project_id','idea_id']:
    if r.get(key):edges.append({'source':r['id'],'target':r[key],'relation':'discusses'})
 root_docs={}
 for d in store.rows('SELECT id,root_id FROM documents WHERE available=1'):
  if d['id'] in nodes:root_docs.setdefault(d['root_id'],[]).append(d['id'])
 for edge in store.rows('SELECT source,target,relation,detail FROM edges'):
  for source in root_docs.get(edge['source'],[edge['source']]):
   for target in root_docs.get(edge['target'],[edge['target']]):edges.append({**edge,'source':source,'target':target})
 unique={}
 for e in edges:
  if e['source'] in nodes and e['target'] in nodes:unique[(e['source'],e['target'],e['relation'])]=e
 return {'nodes':list(nodes.values()),'edges':list(unique.values())}


def restore_objects(store):
 """An explicit database restore restores authored bodies; source documents remain on disk."""
 init(store)
 for item in store.rows('SELECT m.* FROM markdown_files m JOIN objects o ON o.id=m.id'):
  obj=store.object(item['id']);path=safe(item['path'])
  if path.is_file() and path.read_text(encoding='utf-8')==obj['body']:value=sha(path)
  else:value=replace(store,path,obj['body'])
  with store.db() as db:db.execute('UPDATE markdown_files SET hash=? WHERE id=?',(value,obj['id']))
