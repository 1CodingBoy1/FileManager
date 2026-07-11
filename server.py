#!/usr/bin/env python3
"""VPS File Manager Backend - Made By CodingBoyz"""
import os, sys, json, re, shutil, zipfile, tarfile, mimetypes
from http.server import HTTPServer, BaseHTTPRequestHandler
from urllib.parse import urlparse, parse_qs
from datetime import datetime

BASE_DIR = os.path.abspath(os.path.expanduser('~'))
PORT = int(sys.argv[1]) if len(sys.argv) > 1 else 8080
HOST = sys.argv[2] if len(sys.argv) > 2 else '0.0.0.0'
MAX_UPLOAD = 500 * 1024 * 1024

def safe_path(rel):
    if not rel or rel == '/': return BASE_DIR
    full = os.path.realpath(os.path.join(BASE_DIR, rel.lstrip('/')))
    if not full.startswith(BASE_DIR): raise PermissionError("Access denied")
    return full

def file_info(fp, name):
    st = os.lstat(fp)
    is_dir = os.path.isdir(fp)
    low = name.lower()
    is_arc = not is_dir and (low.endswith('.zip') or low.endswith('.tar.gz') or low.endswith('.tgz') or low.endswith('.tar.bz2') or low.endswith('.rar') or low.endswith('.7z'))
    return {'name': name, 'type': 'folder' if is_dir else 'file', 'size': 0 if is_dir else st.st_size, 'modified': datetime.fromtimestamp(st.st_mtime).strftime('%Y-%m-%d %H:%M'), 'is_archive': is_arc}

def parse_multipart(ct, body):
    parts = ct.split('boundary=')
    if len(parts) < 2: return {}, []
    bnd = parts[1].strip().strip('"')
    sections = body.split(('--' + bnd).encode())
    fields, files = {}, []
    for sec in sections:
        if not sec or sec.strip() in (b'--', b'--\r\n'): continue
        if sec.startswith(b'\r\n'): sec = sec[2:]
        if sec.endswith(b'\r\n'): sec = sec[:-2]
        if b'\r\n\r\n' not in sec: continue
        hdr, data = sec.split(b'\r\n\r\n', 1)
        hs = hdr.decode('utf-8', errors='replace')
        nm = re.search(r'name="([^"]*)"', hs)
        fn = re.search(r'filename="([^"]*)"', hs)
        name = nm.group(1) if nm else ''
        filename = fn.group(1) if fn else ''
        if filename: files.append((filename, data, name))
        elif name: fields[name] = data.decode('utf-8', errors='replace')
    return fields, files

class H(BaseHTTPRequestHandler):
    def log_message(self, fmt, *a): pass
    def j(self, d, s=200):
        self.send_response(s); self.send_header('Content-Type', 'application/json'); self.end_headers(); self.wfile.write(json.dumps(d).encode())
    def html(self, c, s=200):
        self.send_response(s); self.send_header('Content-Type', 'text/html; charset=utf-8'); self.end_headers(); self.wfile.write(c.encode())
    def body(self):
        n = int(self.headers.get('Content-Length', 0))
        if n > MAX_UPLOAD: return None
        return self.rfile.read(n) if n > 0 else b''
    def do_GET(self):
        p = urlparse(self.path); q = parse_qs(p.query)
        if p.path in ('/', '/index.html'):
            with open(os.path.join(os.path.dirname(os.path.abspath(__file__)), 'index.html'), 'r', encoding='utf-8') as f: self.html(f.read())
        elif p.path == '/api/info':
            self.j({'success': True, 'base_name': os.path.basename(BASE_DIR), 'base_path': BASE_DIR})
        elif p.path == '/api/list':
            rp = q.get('path', [''])[0]
            try:
                fp = safe_path(rp)
                if not os.path.isdir(fp): return self.j({'success': False, 'message': 'Not a directory'}, 404)
                items = []
                for n in sorted(os.listdir(fp)):
                    if n.startswith('.'): continue
                    try: items.append(file_info(os.path.join(fp, n), n))
                    except: pass
                items.sort(key=lambda x: (0 if x['type'] == 'folder' else 1, x['name'].lower()))
                self.j({'success': True, 'path': rp, 'items': items})
            except PermissionError: self.j({'success': False, 'message': 'Permission denied'}, 403)
            except Exception as e: self.j({'success': False, 'message': str(e)}, 500)
        elif p.path == '/api/download':
            rp = q.get('path', [''])[0]
            try:
                fp = safe_path(rp)
                if not os.path.isfile(fp): return self.j({'success': False, 'message': 'Not found'}, 404)
                mt = mimetypes.guess_type(fp)[0] or 'application/octet-stream'
                self.send_response(200); self.send_header('Content-Type', mt)
                self.send_header('Content-Disposition', 'attachment; filename="' + os.path.basename(fp) + '"')
                self.send_header('Content-Length', str(os.path.getsize(fp))); self.end_headers()
                with open(fp, 'rb') as f: shutil.copyfileobj(f, self.wfile)
            except PermissionError: self.j({'success': False, 'message': 'Permission denied'}, 403)
            except Exception as e: self.j({'success': False, 'message': str(e)}, 500)
        else: self.j({'success': False, 'message': 'Not found'}, 404)
    def do_POST(self):
        p = urlparse(self.path).path
        try:
            if p == '/api/upload':
                ct = self.headers.get('Content-Type', ''); b = self.body()
                if b is None: return self.j({'success': False, 'message': 'File too large (max 500MB)'}, 413)
                flds, fils = parse_multipart(ct, b); fp = safe_path(flds.get('path', ''))
                if not os.path.isdir(fp): return self.j({'success': False, 'message': 'Target not found'}, 404)
                up = []
                for fn, data, _ in fils:
                    with open(os.path.join(fp, fn), 'wb') as f: f.write(data)
                    up.append(fn)
                self.j({'success': True, 'message': f'Uploaded {len(up)} file(s)', 'files': up})
            elif p == '/api/mkdir':
                d = json.loads(self.body() or '{}'); nm = d.get('name', '').strip()
                if not nm: return self.j({'success': False, 'message': 'Name required'}, 400)
                fp = safe_path(d.get('path', '')); os.makedirs(os.path.join(fp, nm))
                self.j({'success': True, 'message': f'Folder "{nm}" created'})
            elif p == '/api/touch':
                d = json.loads(self.body() or '{}'); nm = d.get('name', '').strip()
                if not nm: return self.j({'success': False, 'message': 'Name required'}, 400)
                fp = safe_path(d.get('path', '')); tgt = os.path.join(fp, nm)
                if os.path.exists(tgt): return self.j({'success': False, 'message': 'Already exists'}, 409)
                open(tgt, 'w').close()
                self.j({'success': True, 'message': f'File "{nm}" created'})
            elif p == '/api/rename':
                d = json.loads(self.body() or '{}'); nn = d.get('new_name', '').strip()
                if not nn: return self.j({'success': False, 'message': 'Name required'}, 400)
                fp = safe_path(d.get('path', ''))
                if not os.path.exists(fp): return self.j({'success': False, 'message': 'Not found'}, 404)
                np = os.path.join(os.path.dirname(fp), nn)
                if os.path.exists(np): return self.j({'success': False, 'message': 'Name already exists'}, 409)
                os.rename(fp, np); self.j({'success': True, 'message': 'Renamed'})
            elif p == '/api/delete':
                d = json.loads(self.body() or '{}'); fp = safe_path(d.get('path', ''))
                if not os.path.exists(fp): return self.j({'success': False, 'message': 'Not found'}, 404)
                shutil.rmtree(fp) if os.path.isdir(fp) else os.remove(fp)
                self.j({'success': True, 'message': 'Deleted'})
            elif p == '/api/archive':
                d = json.loads(self.body() or '{}'); fp = safe_path(d.get('path', ''))
                if not os.path.exists(fp): return self.j({'success': False, 'message': 'Not found'}, 404)
                ap = fp + '.zip'
                if os.path.exists(ap): return self.j({'success': False, 'message': 'Archive already exists'}, 409)
                with zipfile.ZipFile(ap, 'w', zipfile.ZIP_DEFLATED) as zf:
                    if os.path.isfile(fp): zf.write(fp, os.path.basename(fp))
                    else:
                        for r, ds, fs in os.walk(fp):
                            for f in fs:
                                x = os.path.join(r, f); zf.write(x, os.path.relpath(x, os.path.dirname(fp)))
                self.j({'success': True, 'message': 'Archived to ' + os.path.basename(ap)})
            elif p == '/api/unzip':
                d = json.loads(self.body() or '{}'); fp = safe_path(d.get('path', ''))
                if not os.path.exists(fp): return self.j({'success': False, 'message': 'Not found'}, 404)
                low = fp.lower(); ed = fp
                for ext in ('.tar.gz', '.tar.bz2', '.tgz', '.zip', '.rar', '.7z'):
                    if low.endswith(ext): ed = fp[:-len(ext)]; break
                else: ed = fp + '_extracted'
                fd = ed; c = 1
                while os.path.exists(fd): fd = f"{ed} ({c})"; c += 1
                os.makedirs(fd)
                if low.endswith('.zip'):
                    with zipfile.ZipFile(fp, 'r') as zf: zf.extractall(fd)
                elif low.endswith(('.tar.gz', '.tgz', '.tar.bz2')):
                    with tarfile.open(fp, 'r:*') as tf:
                        try: tf.extractall(fd, filter='data')
                        except TypeError: tf.extractall(fd)
                else: return self.j({'success': False, 'message': 'Unsupported format'}, 400)
                self.j({'success': True, 'message': 'Extracted to ' + os.path.basename(fd)})
            else: self.j({'success': False, 'message': 'Not found'}, 404)
        except PermissionError: self.j({'success': False, 'message': 'Permission denied'}, 403)
        except FileExistsError: self.j({'success': False, 'message': 'Already exists'}, 409)
        except Exception as e: self.j({'success': False, 'message': str(e)}, 500)

if __name__ == '__main__':
    try: srv = HTTPServer((HOST, PORT), H)
    except OSError: print(f"\n  [!] Cannot bind to {HOST}:{PORT}\n"); sys.exit(1)
    print(f"\n  VPS File Manager — Made By CodingBoyz\n  URL:      http://{HOST}:{PORT}\n  Base Dir: {BASE_DIR}\n  Ctrl+C to stop\n")
    try: srv.serve_forever()
    except KeyboardInterrupt: print("\n  Stopped."); srv.server_close()
