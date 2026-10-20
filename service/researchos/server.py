from __future__ import annotations

import argparse
import json
import mimetypes
import os
import secrets
import sys
import threading
import traceback
import webbrowser
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import urlsplit

from .store import KINDS, Problem, Store, compare, git_snapshot

ROOT = Path(__file__).resolve().parent.parent
MAX_BODY = 20 * 1024 * 1024


class Server(ThreadingHTTPServer):
    daemon_threads = True
    allow_reuse_address = True

    def __init__(self, port, store):
        self.store = store
        self.token = secrets.token_urlsafe(32)
        super().__init__(('127.0.0.1', port), Handler)
        self.origin = f'http://127.0.0.1:{self.server_port}'


class Handler(BaseHTTPRequestHandler):
    server_version = 'ResearchOS/1.0'

    def log_message(self, fmt, *args):
        # No bodies, configuration values or credentials are written to logs.
        super().log_message(fmt, *args)

    def send(self, value, status=200, mime='application/json; charset=utf-8', filename=None):
        body = json.dumps(value, ensure_ascii=False, allow_nan=False).encode() if mime.startswith('application/json') else value
        self.send_response(status)
        self.send_header('Content-Type', mime)
        self.send_header('Content-Length', str(len(body)))
        self.send_header('Cache-Control', 'no-store')
        self.send_header('X-Content-Type-Options', 'nosniff')
        self.send_header('X-Frame-Options', 'DENY')
        self.send_header('Referrer-Policy', 'no-referrer')
        self.send_header('Content-Security-Policy', "default-src 'self'; script-src 'self'; style-src 'self' 'unsafe-inline'; img-src 'self' data:; connect-src 'self'; frame-ancestors 'none'; base-uri 'none'; form-action 'self'")
        if filename:
            self.send_header('Content-Disposition', f'attachment; filename="{filename}"')
        self.end_headers()
        try:
            self.wfile.write(body)
        except (BrokenPipeError, ConnectionResetError):
            pass

    def guard(self, api=False):
        if self.headers.get('Host') not in (f'127.0.0.1:{self.server.server_port}', f'localhost:{self.server.server_port}'):
            raise Problem('Only local access is allowed.', 403)
        origin = self.headers.get('Origin')
        allowed = {self.server.origin, f'http://localhost:{self.server.server_port}'}
        if origin and origin not in allowed:
            raise Problem('Untrusted request origin.', 403)
        if self.headers.get('Sec-Fetch-Site') == 'cross-site':
            raise Problem('Cross-site access is not allowed.', 403)
        if api and not secrets.compare_digest(self.headers.get('X-ResearchOS-Token', ''), self.server.token):
            raise Problem('Session expired. Refresh the page.', 403)

    def body(self):
        if not self.headers.get('Content-Type', '').startswith('application/json'):
            raise Problem('Request must contain JSON.', 415)
        try:
            size = int(self.headers.get('Content-Length', '0'))
            if not 0 < size <= MAX_BODY:
                raise Problem('Request is empty or exceeds 20 MB.', 413)
            def invalid(value):
                raise ValueError('non-finite JSON')
            value = json.loads(self.rfile.read(size), parse_constant=invalid)
            if not isinstance(value, dict):
                raise ValueError('not an object')
            return value
        except (ValueError, UnicodeDecodeError):
            raise Problem('JSON Invalid format.')

    def route(self):
        path = urlsplit(self.path).path
        api = path.startswith('/api/')
        self.guard(api)
        store = self.server.store
        if self.command == 'GET':
            if path == '/health':
                return self.send({'app': 'researchos', 'version': '1.0.0'})
            if path == '/api/state':
                return self.send(store.state())
            if path == '/api/snapshots':
                return self.send({'snapshots': store.snapshots()})
            if path == '/api/export':
                return self.send(store.export(), filename='researchos-backup.json')
            if not api:
                assets = {'/': 'index.html', '/app.js': 'app.js', '/style.css': 'style.css', '/favicon.svg': 'favicon.svg'}
                if path not in assets:
                    raise Problem('Page not found.', 404)
                file = ROOT / 'web' / assets[path]
                content = file.read_bytes()
                if path == '/':
                    content = content.replace(b'__SESSION_TOKEN__', self.server.token.encode())
                mime = mimetypes.guess_type(file.name)[0] or 'application/octet-stream'
                return self.send(content, mime=mime+'; charset=utf-8')
        elif self.command in ('POST', 'PUT', 'DELETE'):
            data = self.body()
            if path == '/api/compare' and self.command == 'POST':
                return self.send(compare(store.state(), data.get('ids')))
            if path == '/api/git' and self.command == 'POST':
                return self.send(git_snapshot(data.get('path')))
            if path == '/api/import-csv' and self.command == 'POST':
                return self.send(store.import_csv(data.get('experiment_id'), data.get('content'), data.get('commit') is True))
            if path == '/api/backup' and self.command == 'POST':
                return self.send({'path': store.backup()})
            if path == '/api/recover-snapshot' and self.command == 'POST':
                if data.get('confirmation') not in ('RESTORE', '恢复'):
                    raise Problem('Confirm workspace restore.')
                store.recover_snapshot(data.get('name'))
                return self.send({'ok': True})
            if path == '/api/restore' and self.command == 'POST':
                if data.get('confirmation') not in ('RESTORE', '恢复'):
                    raise Problem('Type RESTORE to replace the workspace.')
                store.restore(data.get('document'))
                return self.send({'ok': True})
            if path == '/api/demo' and self.command == 'POST':
                store.restore(json.loads((ROOT / 'examples' / 'demo.json').read_text()), replace=False)
                return self.send({'ok': True})
            parts = path.strip('/').split('/')
            if len(parts) in (2, 3) and parts[0] == 'api' and parts[1] in KINDS:
                kind = parts[1]
                if self.command == 'POST' and len(parts) == 2:
                    return self.send(store.put(kind, data), 201)
                if self.command == 'PUT' and len(parts) == 3:
                    return self.send(store.put(kind, data, parts[2]))
                if self.command == 'DELETE' and len(parts) == 3:
                    store.delete(kind, parts[2], data.get('revision'))
                    return self.send({'ok': True})
        raise Problem('Endpoint not found.', 404)

    def dispatch(self):
        try:
            self.route()
        except Problem as exc:
            self.send({'error': exc.message}, exc.status)
        except Exception:
            traceback.print_exc()
            self.send({'error': 'Action incomplete. Data was not saved. Check the local service log.'}, 500)

    do_GET = do_POST = do_PUT = do_DELETE = dispatch


def main():
    parser = argparse.ArgumentParser(description='Research OS — local research workspace')
    parser.add_argument('--port', type=int, default=4317, help='Local port; 0 selects a free port')
    default = Path.home() / 'Library' / 'Application Support' / 'Research OS' if sys.platform == 'darwin' else Path.home() / '.local/share/researchos'
    parser.add_argument('--data-dir', type=Path, default=Path(os.environ.get('RESEARCHOS_DATA_DIR', default)))
    parser.add_argument('--open', action='store_true', help='Open the app in your browser')
    parser.add_argument('--demo', action='store_true', help='Seed an empty workspace with labeled example data')
    parser.add_argument('--url-file', type=Path, help='Write bound URL for the macOS launcher')
    args = parser.parse_args()
    store = Store(args.data_dir)
    if args.demo and not store.state()['projects']:
        store.restore(json.loads((ROOT / 'examples/demo.json').read_text()), replace=False)
    if store.state()['projects']:
        store.backup('startup')
    try:
        server = Server(args.port, store)
    except OSError as exc:
        print(f'Could not start: {exc}.Use --port 0 to choose a port automatically.', file=sys.stderr)
        return 1
    if args.url_file:
        args.url_file.write_text(server.origin)
    print(f'Research OS is ready: {server.origin}\nData: {store.directory}', flush=True)
    if args.open:
        threading.Timer(0.5, lambda: webbrowser.open(server.origin)).start()
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        print('\nResearch OS stopped. Your data is saved.')
    finally:
        server.server_close()
        if args.url_file:
            args.url_file.unlink(missing_ok=True)
    return 0
