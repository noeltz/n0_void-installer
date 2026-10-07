"""Reproduce and fix a no-op PAM password update in an isolated root.

Run as root on Void: sudo python3 tests/account-password-regression.py
Only temporary account files are modified; host accounts are never changed.
"""
import ctypes
import os
from pathlib import Path
import shutil
import subprocess
import tempfile

if os.geteuid() != 0:
    raise SystemExit('Run as root to let chpasswd and passwd enter the temporary root.')

crypt = ctypes.CDLL('libcrypt.so.1')
crypt.crypt.argtypes = (ctypes.c_char_p, ctypes.c_char_p)
crypt.crypt.restype = ctypes.c_char_p


def run(*args, password_input=None):
    result = subprocess.run(args, input=password_input, text=True,
                            stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                            env={**os.environ, 'LC_ALL': 'C'})
    assert result.returncode == 0, result.stderr
    return result.stdout


with tempfile.TemporaryDirectory(prefix='void-password-regression-') as directory:
    root = Path(directory)
    (root / 'etc/pam.d').mkdir(parents=True)
    (root / 'usr/lib/security').mkdir(parents=True)
    (root / 'etc/passwd').write_text(
        'root:x:0:0:root:/root:/bin/sh\nfixture:x:1000:1000:fixture:/home/fixture:/bin/sh\n')
    (root / 'etc/group').write_text('root:x:0:\nfixture:x:1000:\n')
    (root / 'etc/shadow').write_text('root:!:20000:0:99999:7:::\nfixture:!:20000:0:99999:7:::\n')
    (root / 'etc/shadow').chmod(0o600)
    (root / 'etc/login.defs').write_text('ENCRYPT_METHOD SHA512\n')
    (root / 'etc/pam.d/chpasswd').write_text('password required pam_permit.so\n')
    shutil.copy('/usr/lib/security/pam_permit.so', root / 'usr/lib/security/pam_permit.so')

    run('chpasswd', '-R', directory, password_input='fixture:regression-password\n')
    assert run('passwd', '-R', directory, '-S', 'fixture').split()[1] == 'L'
    print('Reproduced: default chpasswd succeeds while the account remains locked.')

    for account in ('fixture', 'root'):
        password = f'{account}-regression-password'
        run('chpasswd', '-R', directory, '-c', 'SHA512',
            password_input=f'{account}:{password}\n')
        status = run('passwd', '-R', directory, '-S', account).split()
        assert status[:2] == [account, 'P'], 'Account did not become active.'
        stored = next(line.split(':')[1] for line in (root / 'etc/shadow').read_text().splitlines()
                      if line.split(':')[0] == account)
        assert stored.startswith('$6$'), 'Expected a SHA-512 hash.'
        assert crypt.crypt(password.encode(), stored.encode()) == stored.encode(), 'Password mismatch.'
    print('Verified: explicit SHA512 writes matching usable hashes for user and root.')

    # The supplied-hash path must keep working independently of PAM.
    supplied = crypt.crypt(b'hash-regression-password', b'$6$regressionsalt$').decode()
    run('chpasswd', '-R', directory, '-e', password_input=f'fixture:{supplied}\n')
    stored = next(line.split(':')[1] for line in (root / 'etc/shadow').read_text().splitlines()
                  if line.split(':')[0] == 'fixture')
    assert stored == supplied, 'Supplied hash changed.'
    print('Verified: supplied hashes are preserved by chpasswd -e.')
