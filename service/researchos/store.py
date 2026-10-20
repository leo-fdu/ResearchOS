from __future__ import annotations

import csv
import hashlib
import io
import json
import math
import re
import sqlite3
import statistics
import subprocess
import uuid
from contextlib import contextmanager
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

KINDS = ('projects', 'datasets', 'hypotheses', 'experiments', 'runs', 'papers', 'notes', 'decisions')
STATUSES = {
    'projects': ['active', 'paused', 'archived'],
    'hypotheses': ['proposed', 'testing', 'supported', 'inconclusive', 'refuted'],
    'experiments': ['planned', 'running', 'completed', 'failed'],
    'runs': ['planned', 'running', 'completed', 'failed'],
    'decisions': ['todo', 'doing', 'done', 'dismissed'],
}
FIELDS = {
    'projects': {'name', 'question', 'description', 'status', 'color', 'repo_path'},
    'datasets': {'project_id', 'name', 'version', 'split', 'description', 'fingerprint', 'path'},
    'hypotheses': {'project_id', 'title', 'rationale', 'prediction', 'criterion', 'status'},
    'experiments': {'project_id', 'hypothesis_id', 'title', 'description', 'status', 'dataset_id', 'split', 'metric', 'direction', 'config', 'git', 'tags'},
    'runs': {'project_id', 'experiment_id', 'seed', 'status', 'metrics', 'history', 'notes', 'artifact_path'},
    'papers': {'project_id', 'hypothesis_id', 'experiment_id', 'title', 'authors', 'year', 'url', 'doi', 'summary', 'evidence_type'},
    'notes': {'project_id', 'hypothesis_id', 'experiment_id', 'title', 'body'},
    'decisions': {'project_id', 'hypothesis_id', 'experiment_id', 'title', 'rationale', 'criterion', 'status', 'priority', 'due_date'},
}
RELATIONS = {'project_id': 'projects', 'hypothesis_id': 'hypotheses', 'experiment_id': 'experiments', 'dataset_id': 'datasets'}


def now() -> str:
    return datetime.now(timezone.utc).isoformat(timespec='milliseconds')


class Problem(Exception):
    def __init__(self, message: str, status: int = 400):
        self.message, self.status = message, status
        super().__init__(message)


def finite(value: Any) -> bool:
    return isinstance(value, (float, int)) and not isinstance(value, bool) and math.isfinite(value)


def clean_metrics(value: Any) -> dict:
    if not isinstance(value, dict) or len(value) > 100:
        raise Problem('Metrics must be a JSON object with at most 100 entries.')
    if any(not isinstance(k, str) or not k.strip() or not finite(v) for k, v in value.items()):
        raise Problem('Metric names must be nonempty and values finite numbers. NaN, Infinity and text are not accepted.')
    return value


class ClosingConnection(sqlite3.Connection):
    """sqlite's transaction context does not close the connection by itself."""
    def __exit__(self, *args):
        try:
            return super().__exit__(*args)
        finally:
            self.close()


class Store:
    def __init__(self, directory: Path):
        self.directory = Path(directory).resolve()
        self.directory.mkdir(parents=True, exist_ok=True)
        self.path = self.directory / 'researchos.sqlite3'
        with self.connect() as db:
            db.executescript('''
                PRAGMA journal_mode=WAL;
                CREATE TABLE IF NOT EXISTS records (
                    id TEXT PRIMARY KEY, kind TEXT NOT NULL, project_id TEXT,
                    payload TEXT NOT NULL, revision INTEGER NOT NULL,
                    created_at TEXT NOT NULL, updated_at TEXT NOT NULL
                );
                CREATE INDEX IF NOT EXISTS records_kind ON records(kind);
                CREATE INDEX IF NOT EXISTS records_project ON records(project_id);
                CREATE TABLE IF NOT EXISTS activity (
                    id INTEGER PRIMARY KEY AUTOINCREMENT, action TEXT NOT NULL,
                    kind TEXT NOT NULL, record_id TEXT NOT NULL, title TEXT NOT NULL,
                    project_id TEXT, at TEXT NOT NULL
                );
                CREATE TABLE IF NOT EXISTS meta (key TEXT PRIMARY KEY, value TEXT NOT NULL);
                INSERT OR IGNORE INTO meta VALUES ('schema_version', '1');
            ''')
            if db.execute("SELECT value FROM meta WHERE key='schema_version'").fetchone()[0] != '1':
                raise Problem('Database version unsupported. Use a newer version of Research OS.')

    def connect(self) -> sqlite3.Connection:
        db = sqlite3.connect(self.path, timeout=15, factory=ClosingConnection)
        db.row_factory = sqlite3.Row
        db.execute('PRAGMA busy_timeout=15000')
        return db

    @contextmanager
    def transaction(self):
        db = self.connect()
        try:
            db.execute('BEGIN IMMEDIATE')
            yield db
            db.commit()
        except Exception:
            db.rollback()
            raise
        finally:
            db.close()

    @staticmethod
    def decode(row):
        if row is None:
            return None
        return dict(json.loads(row['payload']), id=row['id'], revision=row['revision'], created_at=row['created_at'], updated_at=row['updated_at'])

    def get(self, db, kind, rid):
        item = self.decode(db.execute('SELECT * FROM records WHERE kind=? AND id=?', (kind, rid)).fetchone())
        if item is None:
            raise Problem('Record no longer exists. Refresh the workspace.', 404)
        return item

    def state(self):
        with self.connect() as db:
            data = {kind: [] for kind in KINDS}
            for row in db.execute('SELECT * FROM records ORDER BY created_at DESC, id'):
                data[row['kind']].append(self.decode(row))
            data['activity'] = [dict(row) for row in db.execute('SELECT * FROM activity ORDER BY id DESC LIMIT 80')]
            data['meta'] = {'schema_version': 1, 'data_directory': str(self.directory), 'version': '1.0.0'}
            return data

    def validate(self, db, kind, raw, rid=None):
        if kind not in KINDS or not isinstance(raw, dict):
            raise Problem('Invalid record type.')
        unknown = set(raw) - FIELDS[kind] - {'id', 'revision', 'created_at', 'updated_at', 'config_hash'}
        if unknown:
            raise Problem('Unsupported fields: ' + ', '.join(sorted(unknown)))
        item = {key: raw[key] for key in FIELDS[kind] if key in raw}
        special = {'seed', 'metrics', 'history', 'config', 'git', 'tags'}
        for key, value in item.items():
            if key not in special:
                if not isinstance(value, str):
                    raise Problem(f'{key} must be text.')
                if len(value) > 100_000:
                    raise Problem('Each text field is limited to 100,000 characters.')
                item[key] = value.strip()
        if kind != 'runs' and not item.get('name' if kind in ('projects', 'datasets') else 'title'):
            raise Problem('Enter a name or title.')
        if kind in STATUSES:
            item.setdefault('status', STATUSES[kind][0])
            if item['status'] not in STATUSES[kind]:
                raise Problem('Invalid status.')
        if kind != 'projects' and not item.get('project_id'):
            raise Problem('Choose a project.')
        for key, target in RELATIONS.items():
            if item.get(key):
                linked = self.get(db, target, item[key])
                if key != 'project_id' and linked.get('project_id') != item['project_id']:
                    raise Problem('Linked records must belong to the same project.')
        if kind == 'projects':
            item.setdefault('color', '#d76743')
            if item['color'] not in ['#d76743', '#497d70', '#6674ad', '#aa8550', '#a86e91']:
                raise Problem('Choose a valid project color.')
        if kind == 'datasets':
            if not item.get('version'):
                raise Problem('Enter a dataset version (e.g. v1 or content hash).')
            if rid:
                existing = self.get(db, kind, rid)
                used = any(json.loads(r[0]).get('dataset_id') == rid for r in db.execute("SELECT payload FROM records WHERE kind='experiments'"))
                if used and any(item.get(k, '') != existing.get(k, '') for k in ('name', 'version', 'split', 'fingerprint')):
                    raise Problem('This dataset version is already used by experiments. Create a new version to change its identity.')
        if kind == 'experiments':
            if not item.get('dataset_id') or not item.get('split') or not item.get('metric'):
                raise Problem('Specify the dataset version, evaluation split and primary metric.')
            item.setdefault('direction', 'min')
            if item['direction'] not in ('min', 'max'):
                raise Problem('Metric direction must be min or max.')
            item.setdefault('config', {})
            if not isinstance(item['config'], dict):
                raise Problem('Experiment configuration must be a JSON object.')
            item['config_hash'] = hashlib.sha256(json.dumps(item['config'], sort_keys=True, ensure_ascii=False, allow_nan=False).encode()).hexdigest()
            item.setdefault('git', {})
            if not isinstance(item['git'], dict) or any(not isinstance(v, (str, bool)) for v in item['git'].values()):
                raise Problem('Git Invalid snapshot format.')
            item.setdefault('tags', [])
            if not isinstance(item['tags'], list) or any(not isinstance(t, str) for t in item['tags']):
                raise Problem('Tags must be a list of strings.')
            if rid:
                existing = self.get(db, kind, rid)
                used = any(json.loads(r[0]).get('experiment_id') == rid for r in db.execute("SELECT payload FROM records WHERE kind='runs'"))
                if used and any(item.get(k) != existing.get(k) for k in ('dataset_id', 'split', 'metric', 'direction', 'config', 'git')):
                    raise Problem('Runs already exist. Configuration, Git, data version and metric definitions are frozen. Duplicate the experiment.')
        if kind == 'runs':
            if not item.get('experiment_id'):
                raise Problem('Choose an experiment.')
            exp = self.get(db, 'experiments', item['experiment_id'])
            if not isinstance(item.get('seed'), int) or isinstance(item['seed'], bool) or not 0 <= item['seed'] <= 2**32 - 1:
                raise Problem('Seed must be an integer from 0 to 4294967295.')
            for row in db.execute("SELECT id, payload FROM records WHERE kind='runs'"):
                other = json.loads(row['payload'])
                if row['id'] != rid and other['experiment_id'] == item['experiment_id'] and other['seed'] == item['seed']:
                    raise Problem(f"This experiment already has seed {item['seed']}, Edit the existing record.", 409)
            item['metrics'] = clean_metrics(item.get('metrics', {}))
            if item['status'] == 'completed' and exp['metric'] not in item['metrics']:
                raise Problem(f"Completed runs require the primary metric {exp['metric']}.")
            item.setdefault('history', [])
            if not isinstance(item['history'], list) or len(item['history']) > 10_000:
                raise Problem('Learning curves must be an array with at most 10,000 points.')
            prev = -math.inf
            for point in item['history']:
                if not isinstance(point, dict) or not finite(point.get('step')) or point['step'] <= prev:
                    raise Problem('Curve steps must be finite numbers in strictly increasing order.')
                clean_metrics(point.get('metrics'))
                prev = point['step']
        if kind == 'papers':
            if item.get('url') and not item['url'].startswith(('https://', 'http://')):
                raise Problem('Paper URLs must start with https:// or http:// .')
            item.setdefault('evidence_type', 'context')
            if item['evidence_type'] not in ('context', 'supports', 'contradicts', 'method'):
                raise Problem('Invalid evidence type.')
        if kind == 'decisions':
            item.setdefault('priority', 'medium')
            if item['priority'] not in ('high', 'medium', 'low'):
                raise Problem('Invalid priority.')
            if item.get('due_date'):
                try:
                    datetime.strptime(item['due_date'], '%Y-%m-%d')
                except ValueError:
                    raise Problem('Date format must be YYYY-MM-DD.')
        json.dumps(item, allow_nan=False)
        return item

    def put(self, kind, raw, rid=None, db=None, audit=True):
        if db is None:
            with self.transaction() as db:
                return self.put(kind, raw, rid, db, audit)
        existing = self.get(db, kind, rid) if rid else None
        if existing and raw.get('revision') != existing['revision']:
            raise Problem('Record updated in another window. Refresh and retry to avoid overwriting changes.', 409)
        if existing and raw.get('project_id') != existing.get('project_id'):
            raise Problem('Records cannot move between projects. Create a copy instead.')
        item = self.validate(db, kind, raw, rid)
        uid, stamp = rid or uuid.uuid4().hex, now()
        rev, created = (existing['revision'] + 1, existing['created_at']) if existing else (1, stamp)
        db.execute('INSERT INTO records VALUES (?, ?, ?, ?, ?, ?, ?) ON CONFLICT(id) DO UPDATE SET payload=excluded.payload, revision=excluded.revision, updated_at=excluded.updated_at', (uid, kind, item.get('project_id'), json.dumps(item, ensure_ascii=False), rev, created, stamp))
        if audit:
            self.log(db, 'updated' if existing else 'created', kind, uid, item)
        return dict(item, id=uid, revision=rev, created_at=created, updated_at=stamp)

    def log(self, db, action, kind, rid, item):
        title = item.get('name') or item.get('title') or f"Seed {item.get('seed', '')}"
        db.execute('INSERT INTO activity(action, kind, record_id, title, project_id, at) VALUES (?, ?, ?, ?, ?, ?)', (action, kind, rid, title, item.get('project_id', rid), now()))

    def delete(self, kind, rid, revision):
        self.backup('before-delete')
        with self.transaction() as db:
            item = self.get(db, kind, rid)
            if revision != item['revision']:
                raise Problem('Record updated. Refresh before deleting.', 409)
            refs = []
            for row in db.execute('SELECT id, kind, payload FROM records WHERE id<>?', (rid,)):
                payload = json.loads(row['payload'])
                if any(payload.get(k) == rid for k in RELATIONS):
                    refs.append(row['kind'])
            if refs:
                raise Problem(f'There are {len(refs)} linked records remain. Unlink or remove child records first, or archive the project.', 409)
            db.execute('DELETE FROM records WHERE id=?', (rid,))
            self.log(db, 'deleted', kind, rid, item)

    def backup(self, reason='manual'):
        folder = self.directory / 'backups'
        folder.mkdir(exist_ok=True)
        path = folder / f"{datetime.now().strftime('%Y%m%d-%H%M%S-%f')}-{reason}.sqlite3"
        with self.connect() as src, sqlite3.connect(path, factory=ClosingConnection) as dst:
            src.backup(dst)
        for old in sorted(folder.glob('*.sqlite3'))[:-20]:
            old.unlink()
        return str(path)

    def snapshots(self):
        folder = self.directory / 'backups'
        return [{'name': p.name, 'bytes': p.stat().st_size, 'modified': datetime.fromtimestamp(p.stat().st_mtime, timezone.utc).isoformat()} for p in sorted(folder.glob('*.sqlite3'), reverse=True)]

    def recover_snapshot(self, name):
        if not isinstance(name, str) or name not in {x['name'] for x in self.snapshots()}:
            raise Problem('Snapshot no longer exists.', 404)
        path = self.directory / 'backups' / name
        data = {kind: [] for kind in KINDS}
        with sqlite3.connect(path.as_uri() + '?mode=ro', uri=True, factory=ClosingConnection) as db:
            db.row_factory = sqlite3.Row
            for row in db.execute('SELECT * FROM records ORDER BY created_at, id'):
                data[row['kind']].append(self.decode(row))
        self.restore({'format': 'researchos', 'version': 1, 'data': data})

    def export(self):
        state = self.state()
        return {'format': 'researchos', 'version': 1, 'exported_at': now(), 'data': {k: state[k] for k in KINDS}}

    def restore(self, document, replace=True):
        if not isinstance(document, dict) or document.get('format') != 'researchos' or document.get('version') != 1:
            raise Problem('Choose a Research OS v1 JSON backup.')
        data = document.get('data')
        if not isinstance(data, dict) or set(data) != set(KINDS):
            raise Problem('Backup is missing required tables.')
        if any(not isinstance(data[k], list) for k in KINDS) or sum(map(len, data.values())) > 50_000:
            raise Problem('Backup records are invalid or exceed 50,000 entries.')
        self.backup('before-restore')
        with self.transaction() as db:
            if not replace and db.execute('SELECT count(*) FROM records').fetchone()[0]:
                raise Problem('Demo data requires an empty workspace. Export existing data first.')
            generation = max(int(datetime.now(timezone.utc).timestamp() * 1000), db.execute('SELECT coalesce(max(revision), 0) FROM records').fetchone()[0] + 1)
            db.execute('DELETE FROM records')
            db.execute('DELETE FROM activity')
            ids = set()
            for kind in KINDS:
                for raw in data[kind]:
                    if not isinstance(raw, dict) or not isinstance(raw.get('id'), str) or not re.fullmatch(r'[A-Za-z0-9][A-Za-z0-9_-]{0,127}', raw['id']) or raw['id'] in ids:
                        raise Problem('Backup contains duplicate or missing record ID.')
                    ids.add(raw['id'])
                    item = self.validate(db, kind, raw)
                    stamp = now()
                    # A new revision generation prevents stale clients from overwriting restored data.
                    db.execute('INSERT INTO records VALUES (?, ?, ?, ?, ?, ?, ?)', (raw['id'], kind, item.get('project_id'), json.dumps(item, ensure_ascii=False), generation, raw.get('created_at', stamp), stamp))
            self.log(db, 'restored', 'projects', '', {'name': 'Workspace restored'})

    def import_csv(self, experiment_id, content, commit=False):
        if not isinstance(content, str) or len(content) > 4_000_000:
            raise Problem('CSV At most 4 MB.')
        with self.transaction() as db:
            exp = self.get(db, 'experiments', experiment_id)
            reader = csv.DictReader(io.StringIO(content.lstrip('\ufeff')))
            if not reader.fieldnames or 'seed' not in reader.fieldnames:
                raise Problem('CSV A seed column is required. Other numeric columns become metrics. Optional columns: status、notes.')
            if len(reader.fieldnames) != len(set(reader.fieldnames)):
                raise Problem('CSV contains duplicate column names.')
            rows, errors, seen = [], [], set()
            for line, row in enumerate(reader, 2):
                if line > 5001:
                    raise Problem('Import at most 5,000 rows at a time.')
                try:
                    if None in row or any(v is None for v in row.values()):
                        raise Problem('Column count does not match the header.')
                    metrics = {k: float(v) for k, v in row.items() if k not in ('seed', 'status', 'notes') and v.strip()}
                    item = dict(project_id=exp['project_id'], experiment_id=experiment_id, seed=int(row['seed']), status=row.get('status') or 'completed', metrics=metrics, notes=row.get('notes', ''))
                    item = self.validate(db, 'runs', item)
                    if item['seed'] in seen:
                        raise Problem('CSV contains duplicate seeds.')
                    seen.add(item['seed'])
                    rows.append(item)
                except (Problem, ValueError) as exc:
                    errors.append({'line': line, 'message': str(exc)})
            if not rows and not errors:
                raise Problem('CSV contains no data rows.')
            if commit:
                if errors:
                    raise Problem('Nothing imported. Fix all invalid rows first.')
                for item in rows:
                    self.put('runs', item, db=db)
            return {'count': len(rows), 'rows': rows[:20], 'errors': errors, 'committed': commit and not errors}


def summarize(values):
    return {'n': len(values), 'mean': statistics.mean(values) if values else None, 'sd': statistics.stdev(values) if len(values) > 1 else None, 'min': min(values) if values else None, 'max': max(values) if values else None}


def t_critical(df):
    table = [0, 12.706, 4.303, 3.182, 2.776, 2.571, 2.447, 2.365, 2.306, 2.262, 2.228, 2.201, 2.179, 2.160, 2.145, 2.131, 2.120, 2.110, 2.101, 2.093, 2.086, 2.080, 2.074, 2.069, 2.064, 2.060, 2.056, 2.052, 2.048, 2.045, 2.042]
    if df <= 30:
        return table[df]
    # Expansion of the 97.5th percentile, accurate for df > 30.
    z = 1.95996398454
    return z + (z**3 + z)/(4*df) + (5*z**5 + 16*z**3 + 3*z)/(96*df**2) + (3*z**7 + 19*z**5 + 17*z**3 - 15*z)/(384*df**3)


def compare(state, ids):
    if not isinstance(ids, list) or not 2 <= len(ids) <= 6 or not all(isinstance(i, str) for i in ids) or len(set(ids)) != len(ids):
        raise Problem('Choose 2 to 6 distinct experiments.')
    lookup = {e['id']: e for e in state['experiments']}
    if any(i not in lookup for i in ids):
        raise Problem('A selected experiment no longer exists.')
    experiments = [lookup[i] for i in ids]
    baseline = experiments[0]
    fields = ('project_id', 'dataset_id', 'split', 'metric', 'direction')
    if any(any(e[k] != baseline[k] for k in fields) for e in experiments):
        raise Problem('Experiments are not comparable. Project, dataset version, split, primary metric and direction must match exactly.')
    results = []
    base_runs = {r['seed']: r['metrics'][baseline['metric']] for r in state['runs'] if r['experiment_id'] == baseline['id'] and r['status'] == 'completed'}
    for e in experiments:
        all_runs = [r for r in state['runs'] if r['experiment_id'] == e['id']]
        runs = {r['seed']: r['metrics'][e['metric']] for r in all_runs if r['status'] == 'completed'}
        seeds = sorted(set(base_runs) & set(runs))
        diffs = [runs[s] - base_runs[s] for s in seeds]
        paired = summarize(diffs)
        paired['seeds'] = seeds
        paired['ci95'] = None
        if len(diffs) >= 2:
            half = t_critical(len(diffs)-1) * paired['sd'] / math.sqrt(len(diffs))
            paired['ci95'] = [paired['mean']-half, paired['mean']+half]
        results.append({'experiment': e, 'summary': summarize(list(runs.values())), 'values': [{'seed': s, 'value': runs[s]} for s in sorted(runs)], 'paired': paired, 'excluded': len(all_runs)-len(runs)})
    return {'metric': baseline['metric'], 'direction': baseline['direction'], 'results': results, 'method': 'Sample standard deviation (ddof=1); Paired difference = Current experiment − baseline.95% CI Student t intervals use paired differences, assuming independent seeds and approximately normal differences. Few seeds produce unstable intervals. Only completed runs are included; failed and missing runs are not imputed.'}


def git_snapshot(path):
    if not isinstance(path, str) or not path.strip():
        raise Problem('Set the local Git repository path first.')
    repo = Path(path).expanduser().resolve()
    if not repo.is_dir():
        raise Problem('Repository folder not found.')
    def git(*args):
        try:
            result = subprocess.run(['git', '-C', str(repo), *args], text=True, capture_output=True, timeout=12, check=False)
        except (FileNotFoundError, subprocess.TimeoutExpired):
            raise Problem('Git is unavailable or timed out.')
        if result.returncode:
            raise Problem('Cannot read Git repository. Check its path and state.')
        return result.stdout.strip()
    return {'commit': git('rev-parse', 'HEAD'), 'branch': git('rev-parse', '--abbrev-ref', 'HEAD'), 'dirty': bool(git('status', '--porcelain', '--untracked-files=normal')), 'captured_at': now(), 'path': str(repo)}
