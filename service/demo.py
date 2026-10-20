"""Create an explicitly synthetic, isolated workspace; never touch the real one."""
import argparse
from pathlib import Path
from ros.store import Workspace
from ros.library import Library
from researchos.store import Store
p=argparse.ArgumentParser();p.add_argument('--data-dir',required=True);args=p.parse_args()
root=Path(args.data_dir).expanduser().resolve()
if (root/'workspace.sqlite3').exists():raise SystemExit('拒绝覆盖已有工作区；请选择新的演示目录')
w=Workspace(root)
project=w.put({'kind':'project','title':'示例 · 多肽表示对齐','body':'这是合成演示项目，不代表用户的研究进展。比较不同表示在严格划分上的行为。'})
idea=w.put({'kind':'idea','title':'示例 · 接触门控是否真正有效？','body':'假设：界面接触信息改善跨受体泛化。需要 matched seeds、长度和接触数对照；尚无实测结果。','project_id':project['id']})
plan=w.put({'kind':'plan','title':'示例 · 最小可证伪实验','body':'## 问题\n接触门控的提升是否来自接触数捷径？\n\n## 对照\n1. 基线与门控使用相同数据、划分和 seed。\n2. 打乱接触标签，测试快捷特征。\n\n## 验收\n报告配对差值和置信区间；预先明确主指标与失败标准。\n\n## 未知\n样本量和算力预算待确定。','project_id':project['id']})
for order,title in enumerate(['冻结数据划分与 Git commit','实施基线、门控及打乱对照','汇总逐 seed 结果与失败运行'],1):
 w.put({'kind':'task','title':'示例 · '+title,'body':'完成后保存输入、配置、输出位置和证据。','project_id':project['id'],'status':'todo','data':{'parent_id':plan['id'],'order':order,'source':'synthetic demo'}})
w.link(idea['id'],plan['id'],'developed_into')
notes=root/'demo-notes';notes.mkdir();(notes/'实验记录模板.md').write_text('# 实验记录\n\n- 日期：待填\n- 假设：待填\n- Git commit：待填\n- 数据版本：待填\n- 观察结果：待填\n- 推断与下一步：待填\n')
source=w.root_add(notes,'notes',project['id']);Library(w).scan(source);Store(root/'experiments')
print('合成演示数据已建立：',root)
