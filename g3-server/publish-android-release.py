"""Publish an already signed Android APK and its detached Certum proof to the cluster."""
import argparse
from contextlib import ExitStack
import getpass
import hashlib
import json
import os
from pathlib import Path
import re
import shlex
import shutil
import socket
import subprocess
from urllib.request import urlopen

SITES = {'opslinx02.g3nx.net': 'opslinx02', 'rust.g3nx.net': 'rustdesk', 'opslinx03.g3nx.net': 'opslinx03'}
ROOT = '/opt/rustdesk-client'
FEED = '/etc/nginx/snippets/opslinx-android-update.conf'
GUARD = '/usr/local/sbin/opslinx-install-android-update-feed.py'
GUARD_SOURCE = Path(__file__).with_name('install-android-update-feed.py')
APK_SIGNER = '3c69fa623753dc13a8ab41bf0cdbe56f018eea2d8f0a961cb8667e91b8fcc6ee'
PIDS = "systemctl show nginx rustdesk-addressbook -p MainPID --value; pgrep -x 'hbbs|hbbr' | sort"
RELOAD = 'nginx -t && systemctl reload nginx'


def command(connection, text):
    with connection.open_session(timeout=15) as channel:
        channel.settimeout(120)
        channel.exec_command(text)
        output = channel.makefile('rb').read().decode(errors='replace').strip()
        errors = channel.makefile_stderr('rb').read().decode(errors='replace').strip()
        if channel.recv_exit_status() != 0:
            raise RuntimeError(errors or output or 'Remote command failed')
        return output


def read(files, path):
    with files.open(path, 'rb') as handle:
        return handle.read()


def write(files, path, data, mode=0o644):
    pending = path + '.opslinx-pending'
    with files.open(pending, 'wb') as handle:
        handle.write(data)
    files.chmod(pending, mode)
    files.posix_rename(pending, path)


def stage_file(connection, files, source):
    path = f'{ROOT}/{source.name}'
    digest = hashlib.sha256(source.read_bytes()).hexdigest()
    try:
        files.lstat(path)
    except FileNotFoundError:
        pending = path + '.opslinx-pending'
        files.put(str(source), pending)
        files.chmod(pending, 0o644)
        if command(connection, 'sha256sum ' + shlex.quote(pending)).split()[0] != digest:
            raise ValueError(f'Upload verification failed: {source.name}')
        files.rename(pending, path)
    quoted = shlex.quote(path)
    if command(connection, f'test ! -L {quoted} && sha256sum {quoted}').split()[0] != digest:
        raise ValueError(f'Conflicting immutable Android file: {source.name}')


def release_input(path, apksigner):
    metadata = json.loads(path.read_text(encoding='utf-8'))
    version = metadata['version']
    build = re.fullmatch(r'\d+\.\d+\.\d+-g3\.\d+\.(\d+)', version)
    if not build or metadata['version_code'] != int(build[1]) + 2000:
        raise ValueError('Invalid Android build version')
    apk = path.with_name(f'g3-OpsLinX-Android-{version}-arm64.apk')
    signature = apk.with_name(apk.name + '.certum.p7s')
    if not 0 < apk.stat().st_size <= 150_000_000 or not 0 < signature.stat().st_size <= 65_536:
        raise ValueError('Invalid APK or Certum signature size')
    content = apk.read_bytes()
    if (metadata['file'], metadata['size'], metadata['sha256'], metadata['signer_sha256']) != (
            apk.name, len(content), hashlib.sha256(content).hexdigest(), APK_SIGNER):
        raise ValueError('APK does not match its signed release metadata')
    tool = shutil.which(apksigner)
    if tool is None:
        raise ValueError('Android SDK apksigner was not found')
    aapt = Path(tool).with_name('aapt.exe' if os.name == 'nt' else 'aapt')
    badging = subprocess.check_output([str(aapt), 'dump', 'badging', str(apk)], text=True, timeout=30)
    identity = f"package: name='net.g3nx.opslinx.lab' versionCode='{metadata['version_code']}' "
    if (not badging.startswith(identity) or "\nnative-code: 'arm64-v8a'" not in badging):
        raise ValueError('APK package name, Android build number or architecture differs')
    report = subprocess.check_output([tool, 'verify', '--verbose', '--print-certs', str(apk)],
                                     text=True, timeout=90)
    certificate = re.findall(r'(?im)^(?:Signer #1|V[0-9]+\.[0-9]+ Signer:?) certificate SHA-256 digest: ([a-f0-9]{64})$', report)
    if (not certificate or set(map(str.lower, certificate)) != {APK_SIGNER}
            or 'Number of signers: 1' not in report
            or 'Verified using v2 scheme (APK Signature Scheme v2): true' not in report):
        raise ValueError('Expected the Android release signing certificate and a verified v2 signature')
    metadata['certum_sha256'] = hashlib.sha256(signature.read_bytes()).hexdigest()
    return metadata, apk, signature


def install_guard(nodes):
    source = GUARD_SOURCE.read_bytes()
    for host, (_, files) in nodes.items():
        try:
            previous = read(files, GUARD)
        except FileNotFoundError:
            previous = None
        if previous != source:
            if previous is not None:
                write(files, GUARD + '.previous', previous, 0o755)
            write(files, GUARD, source, 0o755)
        if read(files, GUARD) != source:
            raise ValueError(f'{host}: Android release guard verification failed')


def publish(nodes, metadata, apk, signature):
    originals = {}
    request = 'printf %s ' + shlex.quote(json.dumps(metadata)) + ' | python3 ' + GUARD
    for host, (connection, files) in nodes.items():
        if command(connection, "nginx -T 2>/dev/null | grep -c '^[[:space:]]*worker_shutdown_timeout' || true") != '0':
            raise RuntimeError(f'{host}: nginx has a worker shutdown timeout')
        originals[host] = (read(files, FEED), files.stat(FEED).st_mode & 0o777, command(connection, PIDS))
        stage_file(connection, files, apk)
        stage_file(connection, files, signature)
    for host, (connection, _) in nodes.items():
        command(connection, f'{request} {SITES[host]} --stage-apk')
        if command(connection, PIDS) != originals[host][2]:
            raise RuntimeError(f'{host}: an existing service process changed during staging')
        print(f'{host}: APK and Certum signature staged and verified', flush=True)
    changed = []
    try:
        for host, (connection, files) in nodes.items():
            if read(files, FEED) != originals[host][0]:
                raise RuntimeError(f'{host}: Android update feed changed during staging')
            changed.append(host)
            command(connection, f'{request} {SITES[host]} --activate-apk')
            if command(connection, PIDS) != originals[host][2]:
                raise RuntimeError(f'{host}: an existing service process changed during activation')
        expected = {key: metadata[key] for key in ('version', 'size', 'sha256')}
        for host in (*nodes, 'linx.g3nx.net'):
            with urlopen(f'https://{host}/client/android/update.json', timeout=20) as response:
                if json.load(response) != expected:
                    raise ValueError(f'{host}: production Android feed returned unexpected metadata')
            with urlopen(f'https://{host}/client/platform/android_arm64', timeout=30) as response:
                package = response.read(metadata['size'] + 1)
                if len(package) != metadata['size'] or hashlib.sha256(package).hexdigest() != metadata['sha256']:
                    raise ValueError(f'{host}: production Android download differs from the verified APK')
            print(f'{host}: production Android feed and APK verified', flush=True)
    except BaseException:
        for host in reversed(changed):
            conn, files = nodes[host]
            previous, mode, _ = originals[host]
            try:
                if read(files, FEED) != previous:
                    write(files, FEED, previous, mode)
                    command(conn, RELOAD)
            except Exception as error:
                print(f'{host}: Android feed rollback failed: {error}', flush=True)
        raise


def main():
    import paramiko

    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('metadata', type=Path, nargs='?')
    parser.add_argument('--install-guard', action='store_true', help='Install just the release guard on all three nodes')
    parser.add_argument('--host-pins', type=Path, required=True, help='JSON map from each hostname to its SSH SHA256 pin')
    parser.add_argument('--apksigner', default='apksigner')
    args = parser.parse_args()
    if bool(args.metadata) == args.install_guard:
        parser.error('provide release metadata or use --install-guard')
    release = release_input(args.metadata, args.apksigner) if args.metadata else None
    pins = json.loads(args.host_pins.read_text(encoding='utf-8'))
    password = getpass.getpass('SSH-Kennwort: ')
    with ExitStack() as stack:
        nodes = {}
        for host in SITES:
            connection = stack.enter_context(paramiko.Transport(socket.create_connection((host, 22), 12)))
            connection.start_client(timeout=12)
            if connection.get_remote_server_key().fingerprint != 'SHA256:' + pins[host]:
                raise ValueError(f'{host}: unexpected SSH host key')
            connection.auth_password('root', password)
            connection.set_keepalive(20)
            files = stack.enter_context(paramiko.SFTPClient.from_transport(connection))
            files.get_channel().settimeout(120)
            nodes[host] = connection, files
        del password
        lock = stack.enter_context(nodes['opslinx02.g3nx.net'][0].open_session(timeout=15))
        lock.settimeout(12)
        lock.exec_command("flock -n /run/lock/opslinx-android-release.lock sh -c 'echo locked; read ignored'")
        if lock.makefile('rb').readline().strip() != b'locked':
            raise RuntimeError('An Android release is already in progress')
        install_guard(nodes)
        if release:
            publish(nodes, *release)
        else:
            print('Android release guard installed on all three nodes.', flush=True)


if __name__ == '__main__':
    main()
