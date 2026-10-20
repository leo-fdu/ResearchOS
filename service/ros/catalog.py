"""Small resource summaries: one per known resource, never a recursive file scan."""
import json,re,html
from datetime import datetime,timezone
from pathlib import Path
from .store import stamp

README_NAMES=('README.md','README','README.txt','README.rst','readme.md','readme.txt','Readme.md')

def excerpt(text,limit=300,paper=False):
    if paper:
        match=re.search(r'\babstract\b\s*[:\n—-]?\s*(.{60,5000}?)(?=\n\s*(?:1[.\s]+)?introduction\b|\bkeywords\b|\Z)',text,re.I|re.S)
        if match:text=match.group(1)
    text=html.unescape(re.sub(r'<[^>]+>',' ',text))
    text=re.sub(r':[a-z_]+:', '', text)
    text=re.sub(r'<!--.*?-->',' ',text,flags=re.S)
    text=re.sub(r'```.*?```',' ',text,flags=re.S)
    text=re.sub(r'\$\$.*?\$\$|\\\[.*?\\\]',' ',text,flags=re.S)
    text=re.sub(r'\$([^$]+)\$', '[formula]', text)
    text=text.replace('**','').replace('`','')
    text=re.sub(r'!\[[^\]]*\]\([^)]*\)',' ',text)
    text=re.sub(r'\[([^\]]+)\]\([^)]*\)',r'\1',text)
    lines=[re.sub(r'^\s*[#>*-]+\s*','',s).strip() for s in text.splitlines()]
    lines=[s for s in lines if len(s)>25 and not s.startswith(('http','[!','---','|','source_sha256:','source_pdf:'))]
    value=re.sub(r'\s+',' ',' '.join(lines)).strip()
    return value[:limit].rstrip()+('…' if len(value)>limit else '')

def build(store):
    records=store.rows("SELECT d.*,r.kind root_kind FROM documents d JOIN roots r ON r.id=d.root_id WHERE d.available=1 AND r.enabled=1 AND (d.kind IN ('pdf','repo_catalog','data_catalog') OR r.kind='notes') ORDER BY r.kind,d.title COLLATE NOCASE")
    if len(records)>2000:raise ValueError('More than 2,000 resource entries. Narrow the library before creating a summary catalog.')
    entries=[]
    for row in records:
        path=Path(row['path']);source='Existing reading cache';text=row['body'];readme=''
        modified=path.stat().st_mtime_ns if path.exists() else row['mtime']
        if row['kind'].endswith('_catalog'):
            readme_path=next((path/name for name in README_NAMES if (path/name).is_file() and not (path/name).is_symlink()),None)
            if readme_path:
                store.allowed_path(readme_path)
                with readme_path.open(encoding='utf-8',errors='replace') as f:text=f.read(16000)
                readme=str(readme_path);source='README excerpt (first 16,000 characters)'
            else:text='';source='Folder metadata only; no README'
        summary=excerpt(text,paper=row['kind']=='pdf')
        if path.name.upper()=='AGENTS.MD':summary='Local notes-library workflow instructions. Consult the original file when working in this folder.'
        elif path.name.upper()=='INDEX.MD':summary='Existing notes-library overview and navigation index.'
        if not summary:summary='No root README. Purpose and progress are not documented in this index.' if row['kind'].endswith('_catalog') and not readme else 'No readable description yet. Open the source or add a note.'
        entries.append({'id':row['id'],'kind':row['root_kind'],'title':row['title'],'path':row['path'],'modified_ns':modified,'summary':summary,'source':source,'readme':readme,'pages':row['pages']})
    now=stamp()
    with store.db() as db:
        db.executemany('INSERT OR REPLACE INTO resource_summaries(id,summary,source,readme,updated_at) VALUES(?,?,?,?,?)',[(x['id'],x['summary'],x['source'],x['readme'],now) for x in entries])
        db.executemany('UPDATE documents SET mtime=? WHERE id=?',[(x['modified_ns'],x['id']) for x in entries if x['kind'] in ('repo','data')])
    folder=store.root/'catalog';folder.mkdir(exist_ok=True)
    counts={kind:sum(x['kind']==kind for x in entries) for kind in ('repo','papers','data','notes')}
    result={'generated_at':now,'scope':'Known papers and notes; one entry per repository or dataset. No recursive scanning. Summaries are excerpts, not inferred facts.','counts':counts,'entries':entries}
    (folder/'resources.json').write_text(json.dumps(result,ensure_ascii=False,indent=2))
    lines=['# Research resource index','',result['scope'],'',f'Updated: {now}','']
    for kind in counts:
        lines += [f'## {kind} ({counts[kind]})','']
        for x in entries:
            if x['kind']!=kind:continue
            lines += [f"### {x['title']}",f"- Path: `{x['path']}`",f"- Source: {x['source']}",f"- Modified: {datetime.fromtimestamp(x['modified_ns']/1e9,timezone.utc).isoformat()}",f"- Summary: {x['summary']}",'']
            if x['readme']:lines += [f"README: `{x['readme']}`",'']
    (folder/'resources.md').write_text('\n'.join(lines))
    return {'counts':counts,'entries':len(entries),'path':str(folder/'resources.md'),'scope':'No recursive scanning'}
