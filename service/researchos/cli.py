"""Command-line ingestion for local training scripts; no HTTP service required."""
import argparse
import json
import os
import sys
from pathlib import Path
from .store import Store, Problem


def main():
    parser=argparse.ArgumentParser(description='Research OS local data tools')
    default=Path.home()/'Library/Application Support/Research OS' if sys.platform=='darwin' else Path.home()/'.local/share/researchos'
    parser.add_argument('--data-dir',type=Path,default=Path(os.environ.get('RESEARCHOS_DATA_DIR',default)))
    sub=parser.add_subparsers(dest='command',required=True)
    ls=sub.add_parser('experiments',help='List experiment IDs and evaluation context')
    ls.add_argument('--project',help='Filter by project ID')
    log=sub.add_parser('log-run',help='Record one seed result from a training script')
    log.add_argument('--experiment',required=True)
    log.add_argument('--seed',type=int,required=True)
    log.add_argument('--status',choices=['planned','running','completed','failed'],default='completed')
    log.add_argument('--metrics',default='{}',help='JSON object, or @path/to/metrics.json')
    log.add_argument('--history',help='JSON file with step/metrics history')
    log.add_argument('--notes',default='')
    log.add_argument('--artifact-path',default='')
    log.add_argument('--update',action='store_true',help='Explicitly update an existing seed')
    csv=sub.add_parser('import-csv',help='Preview a CSV; add --commit to save all valid rows')
    csv.add_argument('--experiment',required=True);csv.add_argument('file',type=Path);csv.add_argument('--commit',action='store_true')
    export=sub.add_parser('export',help='Export the workspace as portable JSON')
    export.add_argument('file',type=Path)
    args=parser.parse_args()
    try:
        store=Store(args.data_dir)
        if args.command=='experiments':
            result=[{'id':e['id'],'title':e['title'],'project_id':e['project_id'],'metric':e['metric'],'dataset_id':e['dataset_id'],'split':e['split']} for e in store.state()['experiments'] if not args.project or e['project_id']==args.project]
        elif args.command=='log-run':
            state=store.state();exp=next((e for e in state['experiments'] if e['id']==args.experiment),None)
            if not exp:raise Problem('Experiment not found. Run the experiments command to list valid IDs.')
            metrics=json.loads(Path(args.metrics[1:]).read_text() if args.metrics.startswith('@') else args.metrics)
            history=json.loads(Path(args.history).read_text()) if args.history else []
            old=next((r for r in state['runs'] if r['experiment_id']==args.experiment and r['seed']==args.seed),None)
            if old and not args.update:raise Problem('Seed already exists. Use --update explicitly to replace its result.')
            data=dict(old or {},project_id=exp['project_id'],experiment_id=exp['id'],seed=args.seed,status=args.status,metrics=metrics,notes=args.notes,artifact_path=args.artifact_path)
            if args.history or not old:data['history']=history
            result=store.put('runs',data,old['id'] if old else None)
        elif args.command=='import-csv':
            result=store.import_csv(args.experiment,args.file.read_text(encoding='utf-8-sig'),args.commit)
        else:
            with args.file.open('x',encoding='utf-8') as f:json.dump(store.export(),f,ensure_ascii=False,indent=2)
            result={'exported':str(args.file.resolve())}
        print(json.dumps(result,ensure_ascii=False,indent=2))
        return 0
    except (Problem,ValueError,OSError) as exc:
        print(str(exc),file=sys.stderr);return 1

if __name__=='__main__':raise SystemExit(main())
