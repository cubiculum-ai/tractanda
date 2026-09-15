#!/usr/bin/env python3
"""Actual OS-password sign-in over HTTP, only in a marked disposable Debian container.

Creates a temporary OS account inside that container. The generated test password is
passed on stdin/HTTP, never printed, saved in project records, or supplied in argv.
No macOS accounts or passwords are accessed by this fixture.
"""
import argparse
import http.client
import importlib.util
import json
import os
from pathlib import Path
import platform
import pwd
import re
import secrets
import subprocess
import tempfile
import time
from urllib.parse import urlsplit, parse_qs
import uuid


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('binary')
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    assert platform.system() == 'Linux' and os.geteuid() == 0 and os.environ.get('TRACTANDA_DISPOSABLE_CONTAINER') == '1', 'Run only in the disposable Linux test container'
    binary = str(Path(args.binary).resolve())
    spec = importlib.util.spec_from_file_location('kanban_fixture', Path(__file__).with_name('verify-kanban.py'))
    fixture = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(fixture)
    username = 'trac_login_test'
    subprocess.run(['groupadd', '--gid', '29110', username], check=True)
    subprocess.run(['useradd', '--uid', '29110', '--gid', username, '--no-create-home', '--shell', '/bin/sh', username], check=True)
    password = secrets.token_urlsafe(32)
    subprocess.run(['chpasswd'], input=f'{username}:{password}\n', text=True, check=True, capture_output=True)
    account = pwd.getpwnam(username)
    user_options = dict(user=account.pw_uid, group=account.pw_gid, extra_groups=[])
    passed = []

    def check(condition, message):
        assert condition, message
        passed.append(message)

    with tempfile.TemporaryDirectory(prefix='trac-login-') as temporary:
        root = Path(temporary)
        os.chmod(root, 0o700)
        os.chown(root, account.pw_uid, account.pw_gid)
        store, socket, session_file = root/'store', root/'s', root/'session.json'
        native = web = None
        with (root/'servers.log').open('w+') as log:
            try:
                native = subprocess.Popen([binary, 'serve', str(store), str(socket)], stdout=log, stderr=log, **user_options)
                fixture.wait_for(socket, native)
                module_spec=importlib.util.spec_from_file_location('categories',Path(__file__).with_name('category-board-fixture.py'))
                categories=importlib.util.module_from_spec(module_spec);module_spec.loader.exec_module(categories)
                def commit(request):
                    result=subprocess.run([binary,'call',str(socket),'TractandaItem/commit',json.dumps(request)],capture_output=True,text=True,check=True,**user_options)
                    return json.loads(result.stdout)
                mapping=categories.create_fixture(commit)
                board_id=mapping['viewItemID']
                web = subprocess.Popen([binary, 'web', str(socket), board_id, '--session-file', str(session_file)], stdout=log, stderr=log, **user_options)
                fixture.wait_for(session_file, web)
                launch = json.loads(session_file.read_text())
                address = urlsplit(launch['url'])
                origin = f'http://{address.netloc}'
                launch_token = parse_qs(address.fragment)['token'][0]

                def request(path, values=None, token=None, headers=None, raw_body=None):
                    connection = http.client.HTTPConnection(address.hostname, address.port, timeout=22)
                    request_headers = {'Origin': origin, 'Content-Type': 'application/json'}
                    if token: request_headers['Authorization'] = 'Bearer '+token
                    request_headers.update(headers or {})
                    body = raw_body if raw_body is not None else json.dumps(values).encode() if values is not None else None
                    connection.request('POST' if body is not None else 'GET', path, body=body, headers=request_headers)
                    response = connection.getresponse()
                    result = (response.status, dict(response.getheaders()), response.read())
                    connection.close()
                    return result

                def api(token):
                    return request('/api', {'using': [fixture.CAPABILITY], 'methodCalls': [['TractandaStore/info', {}, 'test']]}, token=token)

                status, headers, page = request('/')
                check(status == 200 and b'class="needs-login"' in page and b'autocomplete="current-password"' in page, 'Plain URL presents a password sign-in screen')
                check(launch_token.encode() not in page and password.encode() not in page and b'HTTP test first' not in page, 'Anonymous HTML contains no token, password or item data')
                check(request('/login')[0] == 200, 'Login URL also renders the sign-in screen')
                profile = json.loads(request('/auth/session')[2])
                check(profile['username'] == username and profile['isPasswordSignInAvailable'] and not profile['isAuthenticated'], 'Profile identifies the web process OS account without authorizing the browser')
                check(api(None)[0] == 401, 'API access requires a session')
                check(request('/auth/login', {'username': username, 'password': password}, headers={'Origin': 'https://attacker.invalid'})[0] == 403, 'Foreign-origin credential submission is rejected')
                check(request('/auth/login', {'username': username, 'password': password}, headers={'Host': 'attacker.invalid'})[0] == 403, 'Foreign-host sign-in is rejected')
                check(request('/auth/login', {'username': username, 'password': password}, headers={'Sec-Fetch-Site': 'cross-site'})[0] == 403, 'Cross-site sign-in is rejected')
                check(request('/auth/login', raw_body=b'{' + b'x'*17000)[0] == 413, 'Credential request size is bounded')
                check(request('/auth/login', {'username': username, 'password': ''})[0] == 401, 'Empty password is rejected')
                check(request('/auth/login', {'username': 'root', 'password': password})[0] == 401, 'Another OS account cannot become this web session identity')
                check(request('/auth/login', {'username': username, 'password': 'incorrect-test-password'})[0] == 401, 'Actual PAM authentication rejects the wrong password')
                status, headers, body = request('/auth/login', {'username': username, 'password': password})
                check(status == 200, 'Actual unprivileged PAM password and account checks succeed')
                signed_in = json.loads(body)
                token = signed_in['token']
                check(len(token) == 64 and token != launch_token and 'expiresAt' in signed_in, 'Sign-in issues a distinct expiring browser session')
                status, _, body = api(token)
                info = json.loads(body)['methodResponses'][0][1]
                check(status == 200 and info['ownerUID'] == account.pw_uid, 'Password login preserves the kernel-authenticated native OS identity')
                check(json.loads(request('/auth/session', token=token)[2])['isAuthenticated'], 'Issued session is recognized')
                second = json.loads(request('/auth/login', {'username': username, 'password': password})[2])['token']
                delayed_body = json.dumps({'using':[fixture.CAPABILITY], 'methodCalls':[['TractandaStore/info', {}, 'delayed']]}).encode()
                delayed = http.client.HTTPConnection(address.hostname, address.port, timeout=22)
                delayed.putrequest('POST', '/api')
                for key, value in {'Origin':origin, 'Content-Type':'application/json', 'Authorization':'Bearer '+token, 'Content-Length':str(len(delayed_body))}.items():
                    delayed.putheader(key, value)
                delayed.endheaders(delayed_body[:1])
                time.sleep(0.1)
                check(request('/auth/logout', {}, token=token)[0] == 200 and api(token)[0] == 401, 'Sign-out revokes the session at the server')
                delayed.send(delayed_body[1:])
                response = delayed.getresponse()
                check(response.status == 401, 'An upload started before sign-out cannot use its revoked session at dispatch')
                response.read()
                delayed.close()
                check(api(second)[0] == 200, 'Signing out one browser leaves another independent login working')
                check(api(launch_token)[0] == 200, 'Launch links remain compatible')
                check(request('/auth/logout', {}, token=second, headers={'Origin':'https://attacker.invalid'})[0] == 403 and api(second)[0] == 200, 'Foreign-origin sign-out cannot revoke a session')
                subprocess.run(['chage','--expiredate','1',username], check=True)
                check(request('/auth/login', {'username':username,'password':password})[0] == 401, 'A correct password cannot bypass OS account expiry')
                subprocess.run(['chage','--expiredate','-1',username], check=True)
                check(request('/auth/login', {'username':username,'password':password})[0] == 200, 'OS account restoration allows password sign-in again')
                for _ in range(5):
                    check(request('/auth/login', {'username': username, 'password':'incorrect-test-password'})[0] == 401, 'Wrong password remains denied')
                status, headers, _ = request('/auth/login', {'username': username, 'password':password})
                check(status == 429 and headers.get('Retry-After') == '60', 'Repeated failures are rate limited with a retry interval')
                check(api(second)[0] == 200, 'Login throttling does not disable an existing authorized session')
                fixture.stop(web)
                web = subprocess.Popen([binary, 'web', str(socket), board_id, '--port', str(address.port), '--session-file', str(session_file)], stdout=log, stderr=log, **user_options)
                fixture.wait_for(session_file, web)
                check(api(second)[0] == 401, 'Restart invalidates previously issued browser sessions')
                check(request('/auth/login', {'username':username,'password':password})[0] == 200, 'A fresh password login works after restart')
                check(all(password.encode() not in path.read_bytes() for path in store.rglob('*') if path.is_file()), 'OS password is absent from all Tractanda store files')
                log.flush()
                check(password not in (root/'servers.log').read_text(), 'OS password is absent from application logs')
            except Exception:
                log.flush()
                diagnostics = (root/'servers.log').read_text().replace(password, '[redacted]')
                diagnostics = re.sub(r'(token=)[a-f0-9]+', r'\1[redacted]', diagnostics)
                args.output.parent.mkdir(parents=True, exist_ok=True)
                args.output.with_suffix('.failure.json').write_text(json.dumps({'completedChecks':passed, 'serverLog':diagnostics}, indent=2)+'\n')
                raise
            finally:
                fixture.stop(web)
                fixture.stop(native)
    result = {'status':'passed', 'platform':platform.platform(), 'uid':account.pw_uid, 'pamService':'login', 'checks':passed, 'count':len(passed)}
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(result,indent=2)+'\n')
    print(json.dumps(result,indent=2))


if __name__ == '__main__':
    main()
