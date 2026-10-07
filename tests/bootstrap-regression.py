import functools, http.server, os, pathlib, subprocess, tempfile, threading
with tempfile.TemporaryDirectory(prefix='void-bootstrap-') as tmp:
    p = pathlib.Path(tmp)
    repo = p / 'repo'
    repo.mkdir()
    payload = p / 'payload'
    payload.mkdir()
    (payload / 'fixture').write_text('bootstrap regression fixture\n')
    def run(args, **kw):
        return subprocess.run(args, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, **kw)
    r = run(['xbps-create', '-A', 'x86_64', '-n', 'base-system-1.0_1', '-s', 'Regression fixture', str(payload)], cwd=repo)
    assert r.returncode == 0, r.stdout
    r = run(['xbps-rindex', '-a', str(next(repo.glob('*.xbps')))])
    assert r.returncode == 0, r.stdout
    key = p / 'key.pem'
    r = run(['openssl', 'genrsa', '-out', str(key), '2048'])
    assert r.returncode == 0, r.stdout
    r = run(['xbps-rindex', '--privkey', str(key), '--signedby', 'Regression test', '-s', str(repo)])
    assert r.returncode == 0, r.stdout
    class Quiet(http.server.SimpleHTTPRequestHandler):
        def log_message(self, *args):
            pass
    server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), functools.partial(Quiet, directory=str(repo)))
    threading.Thread(target=server.serve_forever, daemon=True).start()
    root = p / 'target'
    root.mkdir()
    conf = p / 'conf'
    conf.mkdir()
    url = f'http://127.0.0.1:{server.server_port}'
    args = ['xbps-install', '-C', str(conf), '-i', '-r', str(root), '-R', url]
    env = {**os.environ, 'XBPS_ARCH': 'x86_64'}
    old = run(args + ['-n', '-y', '-S', 'base-system'], env=env)
    assert old.returncode != 0 and 'not found in repository pool' in old.stdout, old.stdout
    print('Original -n -S command reproduces base-system not found.')
    sync = run(args + ['-S', '-y'], env=env, input='y\n')
    assert sync.returncode == 0, sync.stdout
    fixed = run(args + ['-n', '-y', 'base-system'], env=env)
    assert fixed.returncode == 0 and 'base-system-1.0_1 install' in fixed.stdout, fixed.stdout
    assert not (root / 'fixture').exists()
    print('Separate sync + dry-run resolves base-system without installing it.')
    missing = run(args + ['-n', '-y', 'does-not-exist'], env=env)
    assert missing.returncode != 0, missing.stdout
    print('Missing packages still fail validation.')
    server.shutdown()
