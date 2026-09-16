#!/usr/bin/env python3
"""Real user service manager, connection-profile and client checks in disposable stores.

macOS uses a temporary user launchd job and removes it. Linux runs as a disposable
non-root account with a working systemd user manager. No existing services are changed.
"""
import argparse
import http.client
import importlib.util
import json
import os
from pathlib import Path
import platform
import re
import shutil
import signal
import subprocess
import tempfile
import time
import uuid


def module(name, file):
    spec = importlib.util.spec_from_file_location(name, Path(__file__).with_name(file))
    result = importlib.util.module_from_spec(spec); spec.loader.exec_module(result)
    return result


wire = module('native', 'verify-ipc.py')
tui = module('terminal_fixture', 'verify-tui.py')
mcp = module('mcp_fixture', 'verify-mcp.py')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('binary', type=Path)
    parser.add_argument('tui', type=Path)
    parser.add_argument('mcp', type=Path)
    parser.add_argument('--output', type=Path, required=True)
    options = parser.parse_args()
    original_binary, terminal_binary, mcp_binary = [str(p.resolve()) for p in (options.binary, options.tui, options.mcp)]
    checks = []
    with tempfile.TemporaryDirectory(prefix='trac-service-', dir='/tmp') as path:
        root = Path(path); name = 'check-' + uuid.uuid4().hex[:8]; endpoint = root/'s'
        # Stage a copy of the executable and its sibling bundles.  After preparation this staged
        # source is made unavailable, proving the installed daemon reads its own copied bundles.
        source = root/'staged-source'; source.mkdir(mode=0o700)
        fixture_binary = source/'tractanda'; shutil.copy2(original_binary, fixture_binary)
        copied_bundles = []
        for bundle in ('Tractanda_TractandaWeb.bundle', 'Tractanda_TractandaWeb.resources',
                       'swift-nio_NIOPosix.bundle', 'swift-nio_NIOPosix.resources'):
            original = Path(original_binary).parent/bundle
            if original.exists():
                shutil.copytree(original, source/bundle); copied_bundles.append(bundle)
        binary = str(fixture_binary)
        environment = {**os.environ, 'TRACTANDA_CONFIG':str(root/'config/connections.json'),
            'TRACTANDA_STATE_DIRECTORY':str(root/'services')}
        environment.pop('TRACTANDA_SERVER_USER', None)
        if platform.system() == 'Darwin': environment['TRACTANDA_SERVICE_DIRECTORY'] = str(root/'units')
        else: environment.pop('TRACTANDA_SERVICE_DIRECTORY', None)

        def command(*args, succeeds=True, extra_environment=None):
            result = subprocess.run([binary, *args], env={**environment, **(extra_environment or {})},
                capture_output=True, text=True, timeout=40)
            assert (result.returncode == 0) == succeeds, (args,result.returncode,result.stdout,result.stderr)
            return json.loads(result.stdout) if succeeds else result.stderr

        def ready():
            deadline = time.monotonic()+15
            while time.monotonic()<deadline:
                result = subprocess.run([binary,'--no-start','info'],env=environment,capture_output=True,text=True,timeout=20)
                if result.returncode == 0: return json.loads(result.stdout)
                time.sleep(.1)
            raise AssertionError(('Server did not become ready',result.stderr))

        def start_through_profile():
            result = subprocess.run([binary, 'info'], env=environment, capture_output=True, text=True, timeout=20)
            assert result.returncode == 0 or 'serviceStarting' in result.stderr, result.stderr

        def pid():
            status = command('service','status',name)['status']
            match = re.search(r'(?:pid = |MainPID=)(\d+)',status)
            assert match, status
            return int(match[1])

        def shared_endpoints(record):
            log = Path(record['logPath']); deadline = time.monotonic()+15
            while time.monotonic() < deadline:
                if log.exists():
                    for line in reversed(log.read_text(errors='replace').splitlines()):
                        try: value = json.loads(line)
                        except json.JSONDecodeError: continue
                        if value.get('socketPath') == str(endpoint) and value.get('httpURL'):
                            return value
                time.sleep(.1)
            raise AssertionError('Managed daemon did not write shared endpoints')

        command('init',str(root/'store'))
        command('connections','add','manual',str(endpoint),'--default')
        assert 'connectionFailed' in command('info',succeeds=False)
        for invalid in (
            ('--shared', '--shared'), ('--http-port', '1'), ('--shared', '--http-port', '1', '--no-http'),
            ('--shared', '--view', 'bad', '--project-root', 'bad'),
            ('--shared', '--project-root', 'bad', '--status-root', 'bad', '--project-root', 'also-bad'),
        ):
            command('service', 'prepare', 'invalid', str(root/'store'), *invalid, succeeds=False)
        view_id, project_root, status_root, project_id = [str(uuid.uuid4()) for _ in range(4)]
        board_name = 'board-' + uuid.uuid4().hex[:8]
        board = command(
            'service', 'prepare', board_name, str(root/'store'), '--shared', '--no-http',
            '--project-root', project_root, '--status-root', status_root, '--project', project_id)
        assert board['nativeProgramArguments'][-6:] == [
            '--project-root', project_root, '--status-root', status_root, '--project', project_id]
        command('service', 'uninstall', board_name)
        view_name = 'view-' + uuid.uuid4().hex[:8]
        view = command('service', 'prepare', view_name, str(root/'store'), '--shared', '--view', view_id)
        assert view['nativeProgramArguments'][-4:] == ['--http-port', '48728', '--view', view_id]
        command('service', 'uninstall', view_name)
        record = command('service','prepare',name,str(root/'store'),'--socket',str(endpoint),
                         '--shared','--http-port','0')
        assert not endpoint.exists()
        assert Path(record['definitionPath']).exists()
        assert record['nativeProgramArguments'] == [
            record['binaryPath'], 'daemon', str(root/'store'), str(endpoint), '--managed', '--http-port', '0']
        for bundle in copied_bundles:
            installed = Path(record['binaryPath']).parent/bundle
            assert installed.is_dir(), installed
        web_bundle = Path(record['binaryPath']).parent/'Tractanda_TractandaWeb.bundle'
        if web_bundle.exists():
            assert b'user guide' in (web_bundle/'Contents/Resources/Resources/Manual.html').read_bytes().lower()
        for bundle in copied_bundles:
            (source/bundle).rename(source/(bundle + '.source-unavailable'))
        activated = False
        try:
            command('service','activate',name,'--default'); activated = True
            info = ready(); assert info['ownerUID'] == os.getuid()
            endpoints = shared_endpoints(record)
            port = int(endpoints['httpURL'].rsplit(':', 1)[1])
            connection = http.client.HTTPConnection('127.0.0.1', port, timeout=10)
            connection.request('GET', '/manual'); response = connection.getresponse(); manual = response.read(); connection.close()
            assert response.status == 200 and b'user guide' in manual.lower()
            assert command('--profile',name,'info')['state'] == info['state']
            assert 'forbidden' in command('info',succeeds=False,extra_environment={'TRACTANDA_SERVER_USER':'root'})
            checks.append('Prepared a shared daemon with explicit daemon arguments, copied full sibling resource bundles, and started it after the staged source bundles were unavailable; native info and HTTP manual work')

            created = command('--default','create','Item','Profile-selected note','profile-capture','Body')
            item = created['revision']; identity = wire.item_id(item)
            session = tui.Terminal(terminal_binary,endpoint,root/'recovery/pending.json',arguments=[],environment=environment)
            try:
                session.wait('Profile-selected note'); session.send('e'); session.wait('Edit item')
                session.send(' edited'); session.resize(120,35); session.send(b'\x13'); session.wait('Saved one revision')
                session.close()
            finally:
                if session.process.poll() is None: session.close(signal.SIGTERM)
            assert wire.Client(endpoint).get(identity)['fields']['subject']['value'] == 'Profile-selected note edited'
            # A pending edit from the earlier explicit-socket client used nil for
            # its same-user daemon identity. A named profile must still recover it.
            pending = {'socket':str(endpoint),'serviceUser':None,'request':wire.intent(
                'create','profile-capture',class_id='Item',
                changes={'subject':wire.text('Profile-selected note'),'body':wire.text('Body')})}
            recovery = root/'recovery/pending.json'
            recovery.write_text(json.dumps(pending)); recovery.chmod(0o600)
            session = tui.Terminal(terminal_binary,endpoint,recovery,arguments=[],environment=environment)
            try:
                session.wait('Recovered unconfirmed edit'); session.send('r'); session.wait('Recovered saved edit')
                session.close()
            finally:
                if session.process.poll() is None: session.close(signal.SIGTERM)
            assert not recovery.exists()
            assert wire.Client(endpoint).call('TractandaItem/history',{'itemID':identity})['total'] == 2
            agent = mcp.MCPClient(mcp_binary,endpoint,arguments=[],env=environment)
            try:
                agent.initialize(); result = agent.tool('tractanda_info')
                assert result['ownerUID'] == os.getuid()
            finally: agent.close()
            checks.append('TUI and MCP launch without socket arguments; TUI edits through the default profile, preserves resizing and recovers an old explicit-socket pending request without duplicating its revision')

            old_pid = pid(); command('service','stop',name)
            deadline = time.monotonic()+10
            while endpoint.exists():
                assert time.monotonic()<deadline; time.sleep(.05)
            assert 'connectionFailed' in command('--no-start','info',succeeds=False)
            start_through_profile(); ready(); assert pid() != old_pid
            assert wire.item_id(wire.Client(endpoint).get(identity)) == identity
            checks.append('Explicit no-start reports a stopped server; normal default connection asks the service manager to start it; IDs and revisions survive')

            old_pid = pid(); os.kill(old_pid,signal.SIGKILL)
            deadline = time.monotonic()+20
            while True:
                try:
                    if pid() != old_pid and ready()['ownerUID'] == os.getuid(): break
                except (AssertionError,subprocess.TimeoutExpired): pass
                assert time.monotonic()<deadline; time.sleep(.2)
            assert wire.Client(endpoint).call('TractandaItem/history',{'itemID':identity})['total'] == 2
            assert 'storeBusy' in command('serve',str(root/'store'),str(root/'other'),'--managed',succeeds=False)
            checks.append('OS manager restarts a killed daemon; managed startup reclaims only its dead socket; canonical history remains intact and a second writer is rejected')

            command('service','uninstall',name); activated = False
            profiles = command('connections','list')['profiles']; assert name not in profiles and 'manual' in profiles
            assert list((root/'store/items').rglob('*.tractanda'))
            assert not Path(record['definitionPath']).exists()
            checks.append('Uninstall removes the service registration and its profile while preserving unrelated connections and every canonical revision')
        finally:
            if activated:
                command('service','uninstall',name)
    report={'status':'passed','platform':platform.platform(),'uid':os.getuid(),'checks':checks}
    options.output.parent.mkdir(parents=True,exist_ok=True)
    options.output.write_text(json.dumps(report,indent=2)+'\n')
    print(json.dumps(report,indent=2))


if __name__=='__main__': main()
