"""English presentation for system-generated messages from older app versions.

Never apply this to user notes, conversations, titles or file paths.
"""
import json,re
from pathlib import Path
MESSAGES=json.loads(Path(__file__).with_name('ui_en.json').read_text())
MESSAGES.update({'刷新仓库入口':'Refresh repositories','刷新数据集入口':'Refresh datasets','撤销逐文件索引':'Remove per-file cache','已移除':'Removed ','条代码和数据文件缓存，仅保留目录入口':' cached file entries. Folder entries preserved.'})
PAIRS=sorted(MESSAGES.items(),key=lambda pair:len(pair[0]),reverse=True)
def system_text(value):
    value=str(value or '')
    if not re.search(r'[\u3400-\u9fff]',value):return value
    for old,new in PAIRS:value=value.replace(old,new)
    return value

def catalog_text(value):
    # Folder titles and paths are user content, including non-English names.
    heading,separator,body=value.partition('\n')
    parts=re.split(r'(`[^`]*`)',body)
    return heading+separator+''.join(part if i%2 else system_text(part) for i,part in enumerate(parts))
