cat << 'SERVEREOF' > "$INSTALL_DIR/server.py"
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
    if not rel or rel == '/':
        return BASE_DIR
    full = os.path.realpath(os.path.join(BASE_DIR, rel.lstrip('/')))
    if not full.startswith(BASE_DIR):
        raise PermissionError("Access denied")
    return full


def file_info(fp, name):
    st = os.lstat(fp)
    is_dir = os.path.isdir(fp)
    low = name.lower()
    is_arc = not is_dir and (low.endswith('.zip') or low.endswith('.tar.gz') or
              low.endswith('.tgz') or low.endswith('.tar.bz2') or low.endswith('.rar') or low.endswith('.7z'))
    return {
        'name': name, 'type': 'folder' if is_dir else 'file',
        'size': 0 if is_dir else st.st_size,
        'modified': datetime.fromtimestamp(st.st_mtime).strftime('%Y-%m-%d %H:%M'),
        'is_archive': is_arc
    }


def parse_multipart(ct, body):
    parts = ct.split('boundary=')
    if len(parts) < 2:
        return {}, []
    bnd = parts[1].strip().strip('"')
    sections = body.split(('--' + bnd).encode())
    fields, files = {}, []
    for sec in sections:
        if not sec or sec.strip() in (b'--', b'--\r\n'):
            continue
        if sec.startswith(b'\r\n'): sec = sec[2:]
        if sec.endswith(b'\r\n'): sec = sec[:-2]
        if b'\r\n\r\n' not in sec:
            continue
        hdr, data = sec.split(b'\r\n\r\n', 1)
        hs = hdr.decode('utf-8', errors='replace')
        nm = re.search(r'name="([^"]*)"', hs)
        fn = re.search(r'filename="([^"]*)"', hs)
        name = nm.group(1) if nm else ''
        filename = fn.group(1) if fn else ''
        if filename:
            files.append((filename, data, name))
        elif name:
            fields[name] = data.decode('utf-8', errors='replace')
    return fields, files


class H(BaseHTTPRequestHandler):
    def log_message(self, fmt, *a):
        pass

    def j(self, d, s=200):
        self.send_response(s)
        self.send_header('Content-Type', 'application/json')
        self.end_headers()
        self.wfile.write(json.dumps(d).encode())

    def html(self, c, s=200):
        self.send_response(s)
        self.send_header('Content-Type', 'text/html; charset=utf-8')
        self.end_headers()
        self.wfile.write(c.encode())

    def body(self):
        n = int(self.headers.get('Content-Length', 0))
        if n > MAX_UPLOAD:
            return None
        return self.rfile.read(n) if n > 0 else b''

    def do_GET(self):
        p = urlparse(self.path)
        q = parse_qs(p.query)
        if p.path in ('/', '/index.html'):
            with open(os.path.join(os.path.dirname(os.path.abspath(__file__)), 'index.html'), 'r', encoding='utf-8') as f:
                self.html(f.read())
        elif p.path == '/api/info':
            self.j({'success': True, 'base_name': os.path.basename(BASE_DIR), 'base_path': BASE_DIR})
        elif p.path == '/api/list':
            rp = q.get('path', [''])[0]
            try:
                fp = safe_path(rp)
                if not os.path.isdir(fp):
                    return self.j({'success': False, 'message': 'Not a directory'}, 404)
                items = []
                for n in sorted(os.listdir(fp)):
                    if n.startswith('.'):
                        continue
                    try:
                        items.append(file_info(os.path.join(fp, n), n))
                    except:
                        pass
                items.sort(key=lambda x: (0 if x['type'] == 'folder' else 1, x['name'].lower()))
                self.j({'success': True, 'path': rp, 'items': items})
            except PermissionError:
                self.j({'success': False, 'message': 'Permission denied'}, 403)
            except Exception as e:
                self.j({'success': False, 'message': str(e)}, 500)
        elif p.path == '/api/download':
            rp = q.get('path', [''])[0]
            try:
                fp = safe_path(rp)
                if not os.path.isfile(fp):
                    return self.j({'success': False, 'message': 'Not found'}, 404)
                mt = mimetypes.guess_type(fp)[0] or 'application/octet-stream'
                self.send_response(200)
                self.send_header('Content-Type', mt)
                self.send_header('Content-Disposition', 'attachment; filename="' + os.path.basename(fp) + '"')
                self.send_header('Content-Length', str(os.path.getsize(fp)))
                self.end_headers()
                with open(fp, 'rb') as f:
                    shutil.copyfileobj(f, self.wfile)
            except PermissionError:
                self.j({'success': False, 'message': 'Permission denied'}, 403)
            except Exception as e:
                self.j({'success': False, 'message': str(e)}, 500)
        else:
            self.j({'success': False, 'message': 'Not found'}, 404)

    def do_POST(self):
        p = urlparse(self.path).path
        try:
            if p == '/api/upload':
                ct = self.headers.get('Content-Type', '')
                b = self.body()
                if b is None:
                    return self.j({'success': False, 'message': 'File too large (max 500MB)'}, 413)
                flds, fils = parse_multipart(ct, b)
                fp = safe_path(flds.get('path', ''))
                if not os.path.isdir(fp):
                    return self.j({'success': False, 'message': 'Target not found'}, 404)
                up = []
                for fn, data, _ in fils:
                    with open(os.path.join(fp, fn), 'wb') as f:
                        f.write(data)
                    up.append(fn)
                self.j({'success': True, 'message': f'Uploaded {len(up)} file(s)', 'files': up})

            elif p == '/api/mkdir':
                d = json.loads(self.body() or '{}')
                nm = d.get('name', '').strip()
                if not nm:
                    return self.j({'success': False, 'message': 'Name required'}, 400)
                fp = safe_path(d.get('path', ''))
                os.makedirs(os.path.join(fp, nm))
                self.j({'success': True, 'message': f'Folder "{nm}" created'})

            elif p == '/api/touch':
                d = json.loads(self.body() or '{}')
                nm = d.get('name', '').strip()
                if not nm:
                    return self.j({'success': False, 'message': 'Name required'}, 400)
                fp = safe_path(d.get('path', ''))
                tgt = os.path.join(fp, nm)
                if os.path.exists(tgt):
                    return self.j({'success': False, 'message': 'Already exists'}, 409)
                open(tgt, 'w').close()
                self.j({'success': True, 'message': f'File "{nm}" created'})

            elif p == '/api/rename':
                d = json.loads(self.body() or '{}')
                nn = d.get('new_name', '').strip()
                if not nn:
                    return self.j({'success': False, 'message': 'Name required'}, 400)
                fp = safe_path(d.get('path', ''))
                if not os.path.exists(fp):
                    return self.j({'success': False, 'message': 'Not found'}, 404)
                np = os.path.join(os.path.dirname(fp), nn)
                if os.path.exists(np):
                    return self.j({'success': False, 'message': 'Name already exists'}, 409)
                os.rename(fp, np)
                self.j({'success': True, 'message': 'Renamed'})

            elif p == '/api/delete':
                d = json.loads(self.body() or '{}')
                fp = safe_path(d.get('path', ''))
                if not os.path.exists(fp):
                    return self.j({'success': False, 'message': 'Not found'}, 404)
                shutil.rmtree(fp) if os.path.isdir(fp) else os.remove(fp)
                self.j({'success': True, 'message': 'Deleted'})

            elif p == '/api/archive':
                d = json.loads(self.body() or '{}')
                fp = safe_path(d.get('path', ''))
                if not os.path.exists(fp):
                    return self.j({'success': False, 'message': 'Not found'}, 404)
                ap = fp + '.zip'
                if os.path.exists(ap):
                    return self.j({'success': False, 'message': 'Archive already exists'}, 409)
                with zipfile.ZipFile(ap, 'w', zipfile.ZIP_DEFLATED) as zf:
                    if os.path.isfile(fp):
                        zf.write(fp, os.path.basename(fp))
                    else:
                        for r, ds, fs in os.walk(fp):
                            for f in fs:
                                x = os.path.join(r, f)
                                zf.write(x, os.path.relpath(x, os.path.dirname(fp)))
                self.j({'success': True, 'message': 'Archived to ' + os.path.basename(ap)})

            elif p == '/api/unzip':
                d = json.loads(self.body() or '{}')
                fp = safe_path(d.get('path', ''))
                if not os.path.exists(fp):
                    return self.j({'success': False, 'message': 'Not found'}, 404)
                low = fp.lower()
                ed = fp
                for ext in ('.tar.gz', '.tar.bz2', '.tgz', '.zip', '.rar', '.7z'):
                    if low.endswith(ext):
                        ed = fp[:-len(ext)]
                        break
                else:
                    ed = fp + '_extracted'
                fd = ed
                c = 1
                while os.path.exists(fd):
                    fd = f"{ed} ({c})"; c += 1
                os.makedirs(fd)
                if low.endswith('.zip'):
                    with zipfile.ZipFile(fp, 'r') as zf:
                        zf.extractall(fd)
                elif low.endswith(('.tar.gz', '.tgz', '.tar.bz2')):
                    with tarfile.open(fp, 'r:*') as tf:
                        try:
                            tf.extractall(fd, filter='data')
                        except TypeError:
                            tf.extractall(fd)
                else:
                    return self.j({'success': False, 'message': 'Unsupported format'}, 400)
                self.j({'success': True, 'message': 'Extracted to ' + os.path.basename(fd)})
            else:
                self.j({'success': False, 'message': 'Not found'}, 404)
        except PermissionError:
            self.j({'success': False, 'message': 'Permission denied'}, 403)
        except FileExistsError:
            self.j({'success': False, 'message': 'Already exists'}, 409)
        except Exception as e:
            self.j({'success': False, 'message': str(e)}, 500)


if __name__ == '__main__':
    try:
        srv = HTTPServer((HOST, PORT), H)
    except OSError:
        print(f"\n  [!] Cannot bind to {HOST}:{PORT} — port may be in use.\n")
        sys.exit(1)
    print(f"\n  VPS File Manager — Made By CodingBoyz")
    print(f"  URL:        http://{HOST}:{PORT}")
    print(f"  Base Dir:   {BASE_DIR}")
    print(f"  Press Ctrl+C to stop\n")
    try:
        srv.serve_forever()
    except KeyboardInterrupt:
        print("\n  Stopped.")
        srv.server_close()
SERVEREOF

echo "  [+] Writing index.html ..."
cat << 'HTMLEOF' > "$INSTALL_DIR/index.html"
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width,initial-scale=1,maximum-scale=1,user-scalable=no">
<title>VPS File Manager</title>
<link rel="stylesheet" href="https://cdnjs.cloudflare.com/ajax/libs/font-awesome/6.5.0/css/all.min.css">
<style>
*,*::before,*::after{box-sizing:border-box;margin:0;padding:0}
:root{--yellow:#FFD600;--yellow-dk:#E6C000;--yellow-lt:#FFF176;--yellow-bg:#FFF9C4;--white:#FFF;--black:#1A1A1A;--g100:#F5F5F5;--g200:#E8E8E8;--g300:#D0D0D0;--g500:#888;--g700:#555;--red:#D32F2F;--red-lt:#FFEBEE;--green:#2E7D32;--green-lt:#E8F5E9}
html,body{height:100%;overflow:hidden}
body{font-family:'Segoe UI',Tahoma,Geneva,Verdana,sans-serif;background:var(--g100);color:var(--black);display:flex;flex-direction:column;user-select:none;-webkit-user-select:none;-webkit-tap-highlight-color:transparent}
.hdr{background:var(--yellow);padding:10px 16px;display:flex;align-items:center;justify-content:space-between;min-height:44px;box-shadow:0 1px 3px rgba(0,0,0,.12);z-index:100;flex-shrink:0}
.hdr .brand{font-weight:700;font-size:15px;display:flex;align-items:center;gap:8px}
.hdr .brand i{font-size:18px}
.hdr .credit{font-weight:600;font-size:12px;opacity:.85}
.tbar{background:var(--white);padding:6px 10px;display:flex;align-items:center;gap:5px;border-bottom:1px solid var(--g200);flex-shrink:0;overflow-x:auto;-webkit-overflow-scrolling:touch;scrollbar-width:none}
.tbar::-webkit-scrollbar{display:none}
.tb{display:inline-flex;align-items:center;gap:5px;padding:7px 12px;border:1px solid var(--g300);background:var(--white);color:var(--black);font-size:13px;font-weight:500;border-radius:5px;cursor:pointer;transition:all .15s;white-space:nowrap;flex-shrink:0;font-family:inherit}
.tb:hover{background:var(--yellow-lt);border-color:var(--yellow-dk)}
.tb:active{transform:scale(.96)}
.tb i{font-size:14px;color:var(--g700)}
.tb.y{background:var(--yellow);border-color:var(--yellow-dk);font-weight:600}
.tb.y:hover{background:var(--yellow-dk)}
.tsep{width:1px;height:24px;background:var(--g300);flex-shrink:0}
.tbar-r{margin-left:auto;display:flex;align-items:center;gap:6px;font-size:12px;color:var(--g500);white-space:nowrap;flex-shrink:0;padding-left:8px}
.bc{background:var(--white);padding:7px 14px;display:flex;align-items:center;gap:3px;border-bottom:1px solid var(--g200);font-size:13px;overflow-x:auto;-webkit-overflow-scrolling:touch;scrollbar-width:none;flex-shrink:0}
.bc::-webkit-scrollbar{display:none}
.cr{color:var(--g700);cursor:pointer;padding:3px 7px;border-radius:3px;white-space:nowrap;transition:background .15s}
.cr:hover{background:var(--yellow-bg)}
.cr.on{color:var(--black);font-weight:600}
.cs{color:var(--g300);font-size:10px;flex-shrink:0}
.fbody{flex:1;display:flex;flex-direction:column;overflow:hidden;background:var(--white);min-height:0}
.chdr{display:grid;grid-template-columns:44px 38px 1fr 100px 90px 90px;align-items:center;padding:5px 10px;background:var(--g100);border-bottom:1px solid var(--g200);font-size:11px;font-weight:700;color:var(--g700);text-transform:uppercase;letter-spacing:.4px;flex-shrink:0}
.chdr>div{cursor:pointer;display:flex;align-items:center;gap:4px}
.chdr>div:hover{color:var(--black)}
.flist{flex:1;overflow-y:auto;overflow-x:hidden;-webkit-overflow-scrolling:touch}
.flist::-webkit-scrollbar{width:7px}
.flist::-webkit-scrollbar-track{background:var(--g100)}
.flist::-webkit-scrollbar-thumb{background:var(--g300);border-radius:4px}
.frow{display:grid;grid-template-columns:44px 38px 1fr 100px 90px 90px;align-items:center;padding:0 10px;border-bottom:1px solid var(--g100);font-size:13px;cursor:default;transition:background .1s;min-height:42px}
.frow:hover{background:var(--yellow-bg)}
.frow.sel{background:#FFF3B0}
.frow .dc,.frow .ic{display:flex;align-items:center;justify-content:center}
.frow .nc{font-weight:500;overflow:hidden;text-overflow:ellipsis;white-space:nowrap;padding-right:8px}
.frow .sc,.frow .tc,.frow .dtc{color:var(--g700);font-size:12px;overflow:hidden;text-overflow:ellipsis;white-space:nowrap}
.db{width:34px;height:34px;border:none;background:0 0;border-radius:6px;cursor:pointer;display:flex;align-items:center;justify-content:center;color:var(--g500);font-size:16px;transition:all .15s}
.db:hover,.db:active{background:var(--yellow);color:var(--black)}
.ifolder{color:#F9A825}.ifile{color:var(--g500)}.izip{color:#7B1FA2}.iimg{color:#E91E63}.icode{color:#1565C0}.itxt{color:#616161}.ipdf{color:#D32F2F}
.cmenu{position:fixed;background:var(--white);border:1px solid var(--g300);border-radius:8px;box-shadow:0 6px 24px rgba(0,0,0,.16);z-index:9999;min-width:190px;padding:4px 0;display:none;animation:cmIn .12s ease}
@keyframes cmIn{from{opacity:0;transform:scale(.95)}to{opacity:1;transform:scale(1)}}
.ci{display:flex;align-items:center;gap:10px;padding:10px 16px;font-size:13px;cursor:pointer;transition:background .1s}
.ci:hover{background:var(--yellow-lt)}
.ci i{width:16px;text-align:center;color:var(--g700);font-size:13px}
.ci.dg{color:var(--red)}.ci.dg i{color:var(--red)}.ci.dg:hover{background:var(--red-lt)}
.csep{height:1px;background:var(--g200);margin:3px 0}
.sbar{background:var(--g100);border-top:1px solid var(--g200);padding:5px 14px;font-size:11px;color:var(--g700);display:flex;align-items:center;gap:14px;flex-shrink:0;overflow:hidden}
.sdot{width:7px;height:7px;background:var(--green);border-radius:50%;display:inline-block;margin-right:4px;flex-shrink:0}
.mov{position:fixed;inset:0;background:rgba(0,0,0,.38);z-index:10000;display:none;align-items:center;justify-content:center;animation:mfIn .15s ease;padding:16px}
.mov.show{display:flex}
@keyframes mfIn{from{opacity:0}to{opacity:1}}
.mbox{background:var(--white);border-radius:10px;box-shadow:0 12px 48px rgba(0,0,0,.22);width:100%;max-width:420px;animation:msIn .2s ease}
@keyframes msIn{from{opacity:0;transform:translateY(-14px)}to{opacity:1;transform:translateY(0)}}
.mhd{background:var(--yellow);padding:12px 18px;border-radius:10px 10px 0 0;font-weight:700;font-size:14px;display:flex;align-items:center;gap:8px}
.mbd{padding:20px 18px}
.mbd label{display:block;font-size:11px;font-weight:700;margin-bottom:6px;color:var(--g700);text-transform:uppercase;letter-spacing:.4px}
.mbd input[type=text]{width:100%;padding:10px 12px;border:1.5px solid var(--g300);border-radius:5px;font-size:15px;font-family:inherit;outline:0;transition:border-color .15s;-webkit-appearance:none}
.mbd input[type=text]:focus{border-color:var(--yellow-dk);box-shadow:0 0 0 3px var(--yellow-bg)}
.mft{padding:12px 18px;display:flex;justify-content:flex-end;gap:8px;border-top:1px solid var(--g200)}
.mb{padding:8px 22px;border:1px solid var(--g300);border-radius:5px;font-size:13px;font-weight:500;cursor:pointer;background:var(--white);color:var(--black);transition:all .15s;font-family:inherit}
.mb:hover{background:var(--g100)}
.mb.pm{background:var(--yellow);border-color:var(--yellow-dk);font-weight:600}
.mb.pm:hover{background:var(--yellow-dk)}
.mb.dm{background:var(--red);border-color:var(--red);color:var(--white);font-weight:600}
.mb.dm:hover{background:#B71C1C}
.tc{position:fixed;bottom:16px;right:16px;left:16px;z-index:99999;display:flex;flex-direction:column;gap:8px;pointer-events:none}
@media(min-width:480px){.tc{left:auto;right:20px;bottom:20px;max-width:340px}}
.tt{background:var(--black);color:var(--white);padding:11px 18px;border-radius:8px;font-size:13px;font-weight:500;box-shadow:0 4px 16px rgba(0,0,0,.25);display:flex;align-items:center;gap:9px;animation:tIn .25s ease,tOut .25s ease 2.5s forwards;pointer-events:auto}
.tt.ok{border-left:4px solid var(--green)}.tt.er{border-left:4px solid var(--red)}.tt.in{border-left:4px solid var(--yellow)}
@keyframes tIn{from{opacity:0;transform:translateX(30px)}to{opacity:1;transform:translateX(0)}}
@keyframes tOut{from{opacity:1}to{opacity:0;transform:translateY(8px)}}
.ldov{position:fixed;inset:0;background:rgba(255,255,255,.72);z-index:50000;display:none;align-items:center;justify-content:center}
.ldov.show{display:flex}
.ldsp{width:38px;height:38px;border:3.5px solid var(--g200);border-top-color:var(--yellow);border-radius:50%;animation:sp .7s linear infinite}
@keyframes sp{to{transform:rotate(360deg)}}
.empty{display:flex;flex-direction:column;align-items:center;justify-content:center;padding:60px 20px;color:var(--g500)}
.empty i{font-size:48px;margin-bottom:12px;color:var(--g300)}
.empty p{font-size:14px}
#fileUploadInput{display:none}
@media(max-width:768px){
.chdr,.frow{grid-template-columns:48px 36px 1fr}
.sc,.tc,.dtc,.chdr>div:nth-child(n+4){display:none!important}
.frow{min-height:50px}
.db{width:42px;height:42px;font-size:18px}
.tb{padding:8px 10px;font-size:13px}
.tb span.lbl{display:none}
.tbar-r span.lbl{display:none}
.hdr{padding:10px 12px}
.hdr .credit{font-size:11px}
.mbox{max-width:100%;border-radius:12px}
.cmenu{top:auto!important;bottom:0!important;left:0!important;right:0!important;width:100%!important;border-radius:14px 14px 0 0;max-height:55vh;overflow-y:auto;box-shadow:0 -4px 24px rgba(0,0,0,.18)}
.cmenu::before{content:'';display:block;width:36px;height:4px;background:var(--g300);border-radius:2px;margin:8px auto 4px}
.ci{padding:13px 18px;font-size:14px;gap:12px}
.ci i{width:18px;font-size:15px}
.sbar{padding:4px 10px;font-size:10px;gap:8px}
.bc{padding:6px 10px;font-size:12px}
.mbd input[type=text]{font-size:16px}
}
@media(max-width:380px){.hdr .brand{font-size:13px}.hdr .credit{font-size:10px}}
</style>
</head>
<body>
<div class="hdr"><div class="brand"><i class="fas fa-server"></i> VPS File Manager</div><div class="credit">Made By CodingBoyz</div></div>
<div class="tbar">
<button class="tb" onclick="goBack()" title="Back"><i class="fas fa-arrow-left"></i><span class="lbl">Back</span></button>
<button class="tb" onclick="goForward()" title="Forward"><i class="fas fa-arrow-right"></i><span class="lbl">Forward</span></button>
<button class="tb" onclick="doRefresh()" title="Refresh"><i class="fas fa-rotate-right"></i><span class="lbl">Refresh</span></button>
<div class="tsep"></div>
<button class="tb y" onclick="triggerUpload()" title="Upload"><i class="fas fa-cloud-arrow-up"></i><span class="lbl">Upload</span></button>
<button class="tb" onclick="showModal('mNF')" title="New Folder"><i class="fas fa-folder-plus"></i><span class="lbl">New Folder</span></button>
<button class="tb" onclick="showModal('mNf')" title="New File"><i class="fas fa-file-circle-plus"></i><span class="lbl">New File</span></button>
<div class="tbar-r"><span id="iCnt">0 items</span></div>
</div>
<input type="file" id="fileUploadInput" multiple onchange="handleUpload(event)">
<div class="bc" id="bc"></div>
<div class="fbody">
<div class="chdr"><div></div><div></div><div onclick="doSort('name')">Name <i class="fas fa-sort"></i></div><div onclick="doSort('size')">Size <i class="fas fa-sort"></i></div><div onclick="doSort('type')">Type <i class="fas fa-sort"></i></div><div onclick="doSort('date')">Modified <i class="fas fa-sort"></i></div></div>
<div class="flist" id="fl"></div>
</div>
<div class="sbar"><span><span class="sdot"></span>Connected</span><span id="sPath">/</span><span id="sSize" style="margin-left:auto"></span></div>
<div class="cmenu" id="cm">
<div class="ci" onclick="cAct('open')"><i class="fas fa-folder-open"></i> Open</div>
<div class="csep"></div>
<div class="ci" onclick="cAct('rename')"><i class="fas fa-pen"></i> Rename</div>
<div class="ci" onclick="cAct('export')"><i class="fas fa-download"></i> Export</div>
<div class="ci" id="cmArc" onclick="cAct('archive')"><i class="fas fa-file-zipper"></i> Archive (.zip)</div>
<div class="ci" id="cmUnz" onclick="cAct('unzip')" style="display:none"><i class="fas fa-box-open"></i> Unzip</div>
<div class="csep"></div>
<div class="ci dg" onclick="cAct('delete')"><i class="fas fa-trash"></i> Delete</div>
</div>
<div class="ldov" id="ldov"><div class="ldsp"></div></div>
<div class="mov" id="mNF"><div class="mbox"><div class="mhd"><i class="fas fa-folder-plus"></i> New Folder</div><div class="mbd"><label>Folder Name</label><input type="text" id="iNF" placeholder="Enter folder name..." autocomplete="off" onkeydown="if(event.key==='Enter')doMkDir()"></div><div class="mft"><button class="mb" onclick="hideModal('mNF')">Cancel</button><button class="mb pm" onclick="doMkDir()">Create</button></div></div></div>
<div class="mov" id="mNf"><div class="mbox"><div class="mhd"><i class="fas fa-file-circle-plus"></i> New File</div><div class="mbd"><label>File Name</label><input type="text" id="iNf" placeholder="e.g. config.txt" autocomplete="off" onkeydown="if(event.key==='Enter')doTouch()"></div><div class="mft"><button class="mb" onclick="hideModal('mNf')">Cancel</button><button class="mb pm" onclick="doTouch()">Create</button></div></div></div>
<div class="mov" id="mRen"><div class="mbox"><div class="mhd"><i class="fas fa-pen"></i> Rename</div><div class="mbd"><label>New Name</label><input type="text" id="iRen" autocomplete="off" onkeydown="if(event.key==='Enter')doRename()"></div><div class="mft"><button class="mb" onclick="hideModal('mRen')">Cancel</button><button class="mb pm" onclick="doRename()">Rename</button></div></div></div>
<div class="mov" id="mDel"><div class="mbox"><div class="mhd"><i class="fas fa-trash"></i> Confirm Delete</div><div class="mbd"><p id="delMsg" style="font-size:14px;line-height:1.6"></p></div><div class="mft"><button class="mb" onclick="hideModal('mDel')">Cancel</button><button class="mb dm" onclick="doDelete()">Delete</button></div></div></div>
<div class="tc" id="tc"></div>
<script>
let curPath='',hist=[''],hIdx=0,selPath=null,ctxTgt=null,sortF='name',sortA=true,baseName='home',loading=false,items=[];
const $=id=>document.getElementById(id);
async function init(){try{const r=await fetch('/api/info');const d=await r.json();if(d.success)baseName=d.base_name;}catch(e){}await loadDir('');}
async function api(url,opts){const r=await fetch(url,opts);return await r.json();}
async function loadDir(path){if(loading)return;loading=true;$('ldov').classList.add('show');try{const d=await api('/api/list?path='+encodeURIComponent(path));if(d.success){curPath=d.path;items=d.items||[];renderBC();renderList();updateStatus();if(hist[hIdx]!==curPath){hist=hist.slice(0,hIdx+1);hist.push(curPath);hIdx=hist.length-1;}}else{toast(d.message||'Failed to load','er');}}catch(e){toast('Connection error','er');}finally{loading=false;$('ldov').classList.remove('show');}}
function renderBC(){const parts=curPath?curPath.split('/').filter(Boolean):[];let h='<span class="cr '+(parts.length===0?'on':'')+'" onclick="navTo(\'\')">'+baseName+'</span>';let p='';parts.forEach((s,i)=>{p+='/'+s;const last=i===parts.length-1;h+='<span class="cs"><i class="fas fa-chevron-right"></i></span>';h+='<span class="cr '+(last?'on':'')+'" onclick="navTo(\''+p+'\')">'+s+'</span>';});$('bc').innerHTML=h;}
function renderList(){const sorted=[...items];sorted.sort((a,b)=>{const af=a.type==='folder'?0:1,bf=b.type==='folder'?0:1;if(af!==bf)return af-bf;let va,vb;switch(sortF){case'name':va=a.name.toLowerCase();vb=b.name.toLowerCase();break;case'size':va=a.size||0;vb=b.size||0;break;case'type':va=getType(a);vb=getType(b);break;case'date':va=a.modified||'';vb=b.modified||'';break;default:va=a.name.toLowerCase();vb=b.name.toLowerCase();}if(va<vb)return sortA?-1:1;if(va>vb)return sortA?1:-1;return 0;});if(!sorted.length){$('fl').innerHTML='<div class="empty"><i class="fas fa-folder-open"></i><p>This folder is empty</p></div>';$('iCnt').textContent='0 items';return;}let h='';sorted.forEach(it=>{const rp=curPath?curPath+'/'+it.name:it.name;const ic=getIcon(it);const sz=it.type==='folder'?'--':fmtSz(it.size||0);const tp=getType(it);const dt=it.modified||'--';const isF=it.type==='folder';const isA=it.is_archive;h+=`<div class="frow" data-rp="${rp}" data-nm="${esc(it.name)}" data-f="${isF}" data-a="${isA}" ondblclick="dblClick(this)" onclick="clk(this)">`;h+=`<div class="dc"><button class="db" onclick="event.stopPropagation();showCM(event,'${esc(rp)}',${isF},${isA})"><i class="fas fa-ellipsis-vertical"></i></button></div>`;h+=`<div class="ic">${ic}</div>`;h+=`<div class="nc">${esc(it.name)}</div>`;h+=`<div class="sc">${sz}</div>`;h+=`<div class="tc">${tp}</div>`;h+=`<div class="dtc">${dt}</div></div>`;});$('fl').innerHTML=h;$('iCnt').textContent=sorted.length+' item'+(sorted.length!==1?'s':'');}
function updateStatus(){$('sPath').textContent=curPath?'/'+curPath:'/'+baseName;const t=items.reduce((s,i)=>s+(i.size||0),0);$('sSize').textContent=fmtSz(t)+' in this folder';}
function navTo(p){loadDir(p);}
function goBack(){if(hIdx>0){hIdx--;loadDir(hist[hIdx]);}}
function goForward(){if(hIdx<hist.length-1){hIdx++;loadDir(hist[hIdx]);}}
function doRefresh(){loadDir(curPath);toast('Refreshed','in');}
function clk(row){document.querySelectorAll('.frow.sel').forEach(r=>r.classList.remove('sel'));row.classList.add('sel');selPath=row.dataset.rp;}
function dblClick(row){const isF=row.dataset.f==='true';if(isF)loadDir(row.dataset.rp);else window.open('/api/download?path='+encodeURIComponent(row.dataset.rp),'_blank');}
function doSort(f){if(sortF===f)sortA=!sortA;else{sortF=f;sortA=true;}renderList();}
function showCM(e,rp,isF,isA){ctxTgt={rp,isF,isA};const m=$('cm');$('cmArc').style.display='flex';$('cmUnz').style.display=(isA&&!isF)?'flex':'none';m.style.display='block';requestAnimationFrame(()=>{const r=m.getBoundingClientRect();let x=e.clientX,y=e.clientY;if(window.innerWidth<=768){x=0;y=window.innerHeight-r.height;}else{if(x+r.width>window.innerWidth)x=window.innerWidth-r.width-6;if(y+r.height>window.innerHeight)y=window.innerHeight-r.height-6;}m.style.left=x+'px';m.style.top=y+'px';});}
function hideCM(){$('cm').style.display='none';ctxTgt=null;}
document.addEventListener('click',e=>{if(!e.target.closest('.cmenu')&&!e.target.closest('.db'))hideCM();});
async function cAct(act){if(!ctxTgt)return;const{rp,isF,isA}=ctxTgt;hideCM();const nm=rp.split('/').pop();switch(act){case'open':if(isF)loadDir(rp);else window.open('/api/download?path='+encodeURIComponent(rp),'_blank');break;case'rename':showRename(nm,rp);break;case'export':window.location.href='/api/download?path='+encodeURIComponent(rp);toast('Exporting: '+nm,'ok');break;case'archive':await doArchive(rp,nm);break;case'unzip':await doUnzip(rp,nm);break;case'delete':showDel(nm,rp);break;}}
function triggerUpload(){$('fileUploadInput').click();}
async function handleUpload(e){const files=e.target.files;if(!files.length)return;const fd=new FormData();fd.append('path',curPath);Array.from(files).forEach(f=>fd.append('file',f));$('ldov').classList.add('show');try{const d=await api('/api/upload',{method:'POST',body:fd});if(d.success){toast(d.message,'ok');loadDir(curPath);}else toast(d.message,'er');}catch(e){toast('Upload failed','er');}finally{$('ldov').classList.remove('show');e.target.value='';}}
function showModal(id){$(id).classList.add('show');setTimeout(()=>{const inp=$(id).querySelector('input');if(inp){inp.value='';inp.focus();}},120);}
function hideModal(id){$(id).classList.remove('show');}
document.querySelectorAll('.mov').forEach(o=>o.addEventListener('click',e=>{if(e.target===o)o.classList.remove('show');}));
async function doMkDir(){const nm=$('iNF').value.trim();if(!nm){toast('Enter a folder name','er');return;}try{const d=await api('/api/mkdir',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({path:curPath,name:nm})});if(d.success){hideModal('mNF');toast(d.message,'ok');loadDir(curPath);}else toast(d.message,'er');}catch(e){toast('Failed','er');}}
async function doTouch(){const nm=$('iNf').value.trim();if(!nm){toast('Enter a file name','er');return;}try{const d=await api('/api/touch',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({path:curPath,name:nm})});if(d.success){hideModal('mNf');toast(d.message,'ok');loadDir(curPath);}else toast(d.message,'er');}catch(e){toast('Failed','er');}}
let renPath=nul
function showRename(nm,rp){renPath=rp;$('iRen').value=nm;showModal('mRen');setTimeout(()=>{const i=$('iRen');i.focus();const d=nm.lastIndexOf('.');if(d>0)i.setSelectionRange(0,d);else i.select();},140);}
async function doRename(){const nn=$('iRen').value.trim();if(!nn){toast('Enter a name','er');return;}if(!renPath)return;try{const d=await api('/api/rename',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({path:renPath,new_name:nn})});if(d.success){hideModal('mRen');renPath=null;toast(d.message,'ok');loadDir(curPath);}else toast(d.message,'er');}catch(e){toast('Failed','er');}}
let delPath=null;
function showDel(nm,rp){delPath=rp;$('delMsg').innerHTML='Are you sure you want to delete <strong>'+esc(nm)+'</strong>?';showModal('mDel');}
async function doDelete(){if(!delPath)return;try{const d=await api('/api/delete',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({path:delPath})});if(d.success){hideModal('mDel');delPath=null;selPath=null;toast(d.message,'ok');loadDir(curPath);}else toast(d.message,'er');}catch(e){toast('Failed','er');}}
async function doArchive(rp,nm){$('ldov').classList.add('show');try{const d=await api('/api/archive',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({path:rp})});if(d.success){toast(d.message,'ok');loadDir(curPath);}else toast(d.message,'er');}catch(e){toast('Archive failed','er');}finally{$('ldov').classList.remove('show');}}
async function doUnzip(rp,nm){$('ldov').classList.add('show');try{const d=await api('/api/unzip',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({path:rp})});if(d.success){toast(d.message,'ok');loadDir(curPath);}else toast(d.message,'er');}catch(e){toast('Unzip failed','er');}finally{$('ldov').classList.remove('show');}}
function getExt(n){const i=n.lastIndexOf('.');return i>0?n.substring(i+1).toLowerCase():'';}
function getType(it){if(it.type==='folder')return'Folder';if(it.is_archive)return'Archive';const e=getExt(it.name);if(it.name.endsWith('.tar.gz')||it.name.endsWith('.tar.bz2'))return'Archive';const m={txt:'Text',md:'Markdown',log:'Log',html:'HTML',css:'CSS',js:'JavaScript',json:'JSON',py:'Python',sh:'Shell',yaml:'YAML',yml:'YAML',xml:'XML',sql:'SQL',php:'PHP',png:'Image',jpg:'Image',jpeg:'Image',gif:'Image',svg:'Image',webp:'Image',pdf:'PDF',csv:'CSV',env:'Config',conf:'Config',ini:'Config'};return m[e]||'File';}
function getIcon(it){if(it.type==='folder')return'<i class="fas fa-folder ifolder"></i>';const e=getExt(it.name);if(it.is_archive||it.name.endsWith('.tar.gz')||it.name.endsWith('.tar.bz2')||['zip','tar','gz','rar','7z','bz2'].includes(e))return'<i class="fas fa-file-zipper izip"></i>';const m={png:'fa-file-image iimg',jpg:'fa-file-image iimg',jpeg:'fa-file-image iimg',gif:'fa-file-image iimg',svg:'fa-file-image iimg',webp:'fa-file-image iimg',html:'fa-file-code icode',css:'fa-file-code icode',js:'fa-file-code icode',json:'fa-file-code icode',py:'fa-file-code icode',sh:'fa-file-code icode',yaml:'fa-file-code icode',yml:'fa-file-code icode',xml:'fa-file-code icode',sql:'fa-file-code icode',php:'fa-file-code icode',md:'fa-file-lines itxt',txt:'fa-file-lines itxt',log:'fa-file-lines itxt',env:'fa-file-lines itxt',conf:'fa-file-lines itxt',pdf:'fa-file-pdf ipdf',csv:'fa-file-csv ifile'};const c=m[e];return c?`<i class="fas ${c}"></i>`:'<i class="fas fa-file ifile"></i>';}
function fmtSz(b){if(!b)return'0 B';const u=['B','KB','MB','GB','TB'];const i=Math.floor(Math.log(b)/Math.log(1024));return(b/Math.pow(1024,i)).toFixed(i>0?1:0)+' '+u[i];}
function esc(s){return s.replace(/&/g,'&amp;').replace(/</g,'&lt;').replace(/>/g,'&gt;').replace(/"/g,'&quot;').replace(/'/g,'&#39;');}
function toast(msg,type='in'){const t=document.createElement('div');t.className='tt '+type;const icons={ok:'fa-check-circle',er:'fa-exclamation-circle','in':'fa-info-circle'};t.innerHTML=`<i class="fas ${icons[type]||icons.in}"></i> ${esc(msg)}`;$('tc').appendChild(t);setTimeout(()=>{if(t.parentNode)t.remove();},3000);}
document.addEventListener('keydown',e=>{if(document.querySelector('.mov.show'))return;if(e.key==='Delete'&&selPath){const nm=selPath.split('/').pop();showDel(nm,selPath);}if(e.key==='F2'&&selPath){e.preventDefault();const nm=selPath.split('/').pop();showRename(nm,selPath);}if(e.key==='Escape')hideCM();if(e.key==='Backspace'&&document.activeElement.tagName!=='INPUT'){e.preventDefault();goBack();}});
init();
</script>
</body>
</html>
HTMLEOF
echo "  [+] Writing start script ..."
cat << 'STARTOFEOF' > "$BIN_PATH"
#!/bin/bash
INSTALL_DIR="/opt/vps-file-manager"
if [ ! -d "$INSTALL_DIR" ]; then
    echo "  [!] VPS File Manager not installed. Run install.sh first."
    exit 1
fi
if ! command -v python3 &> /dev/null; then
    echo "  [!] Python3 is required but not found."
    exit 1
fi
cd "$INSTALL_DIR"
exec python3 server.py "\${1:-8080}" "\${2:-0.0.0.0}"
STARTEOF

chmod +x "$BIN_PATH"
chmod +x "$INSTALL_DIR/server.py"

echo ""
echo "  [✓] Installation complete!"
echo ""
echo "  Usage:"
echo "    vps-fm              # Start on port 8080"
echo "    vps-fm 3000         # Start on port 3000"
echo "    vps-fm 8080 0.0.0.0 # Start on port 8080, all interfaces"
echo ""
echo "  Then open http://<your-vps-ip>:8080 in your browser."
echo ""
exit 0
