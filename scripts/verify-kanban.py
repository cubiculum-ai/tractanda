#!/usr/bin/env python3
"""Independent CLI and real HTTP verification, using only disposable item stores."""
import argparse
import importlib.util
import copy
import contextlib
import http.client
import json
import re
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import time
from urllib.parse import urlsplit, parse_qs
import uuid

CAPABILITY = 'https://tractanda.ai/ns/local-prototype/2'



def stop(process):
    if process is None or process.poll() is not None:
        return
    process.terminate()
    try:
        process.wait(timeout=25)
    except subprocess.TimeoutExpired:
        process.kill()
        process.wait(timeout=5)


def wait_for(path, process):
    deadline = time.monotonic() + 20
    while not path.exists():
        if process.poll() is not None:
            raise RuntimeError(f'Server stopped with status {process.returncode}')
        if time.monotonic() > deadline:
            raise TimeoutError(f'Server did not create {path.name}')
        time.sleep(0.03)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('binary')
    parser.add_argument('--export')
    parser.add_argument('--import-from')
    options = parser.parse_args()
    binary = str(Path(options.binary).resolve())
    passed = []

    def check(condition, label):
        if not condition:
            raise AssertionError(label)
        passed.append(label)

    with tempfile.TemporaryDirectory(prefix='tractanda-kanban-') as directory:
        root = Path(directory)
        store = root / 'store'
        socket = Path('/tmp') / f'tk-{uuid.uuid4().hex[:18]}.sock'
        session_file = root / 'web-session.json'
        native = web = None

        def cli(*arguments):
            result = subprocess.run([binary, *map(str, arguments)], capture_output=True, text=True, timeout=25)
            if result.returncode:
                raise RuntimeError(result.stderr)
            return json.loads(result.stdout)

        with (root / 'servers.log').open('w') as log:
            try:
                if options.import_from:
                    source = Path(options.import_from)
                    store.mkdir(mode=0o700)
                    shutil.copytree(source / 'items', store / 'items')
                    manifest = json.loads((source / 'manifest.json').read_text())
                    fixture = manifest['fixture']
                native = subprocess.Popen([binary,'serve',str(store),str(socket)], stdout=log, stderr=log)
                wait_for(socket,native)
                if not options.import_from:
                    spec=importlib.util.spec_from_file_location('category_fixture',Path(__file__).with_name('category-board-fixture.py'))
                    module=importlib.util.module_from_spec(spec);spec.loader.exec_module(module)
                    fixture=module.create_fixture(lambda request:cli('call',socket,'TractandaItem/commit',json.dumps(request)))
                board_id = fixture['viewItemID']
                first_id = fixture['itemIDs']['TEST-1']
                initial = cli('kanban',socket,board_id)
                check(len(initial['tasks']) == 2, 'CLI reads both tasks through the saved view')
                if options.import_from:
                    check(initial['tasks'] == manifest['snapshot']['tasks'], 'Transferred canonical board preserves tasks, identities, order and references')
                cli('export-kanban',socket,board_id,root/'snapshot.html')
                check('HTTP test' in (root/'snapshot.html').read_text(), 'CLI exports an HTML snapshot from canonical items')
                web = subprocess.Popen([binary,'web',str(socket),board_id,'--session-file',str(session_file)],stdout=log,stderr=log)
                wait_for(session_file,web)
                session = json.loads(session_file.read_text())
                address = urlsplit(session['url'])
                token = parse_qs(address.fragment)['token'][0]
                origin = f'http://{address.netloc}'
                check(session_file.stat().st_mode & 0o077 == 0, 'Session capability file is private')

                def send_http_request(method='POST', path='/api', body=b'{}', overrides=None, authenticate=True):
                    connection = http.client.HTTPConnection(address.hostname,address.port,timeout=22)
                    headers = {'Content-Type':'application/json','Origin':origin}
                    if authenticate:
                        headers['Authorization'] = f'Bearer {token}'
                    headers.update(overrides or {})
                    connection.request(method,path,body=body,headers=headers)
                    response = connection.getresponse()
                    status, response_headers, contents = response.status,dict(response.getheaders()),response.read()
                    connection.close()
                    return status,response_headers,contents

                def envelope(method, arguments):
                    return json.dumps(dict(using=[CAPABILITY],methodCalls=[[method,arguments,'test']])).encode()

                def method_result(method, arguments):
                    status,_,contents = send_http_request(body=envelope(method,arguments))
                    check(status == 200, f'HTTP delivers {method}')
                    return json.loads(contents)['methodResponses'][0]

                status,headers,contents = send_http_request('GET','/',None,authenticate=False)
                check(status == 200 and b'@@' not in contents, 'Public shell is rendered without template markers')
                check(token.encode() not in contents and b'HTTP test first' not in contents, 'Public shell contains neither session token nor item data')
                check("frame-ancestors 'none'" in headers['Content-Security-Policy'], 'Browser shell includes its CSP')
                nonce = re.search(r"'nonce-([0-9a-f]{64})'", headers['Content-Security-Policy'])
                check(nonce is not None and nonce.group(1) != token and nonce.group(1).encode() in contents,
                      'CSP uses an independent random capability rather than a provenance UUID')
                check(send_http_request(authenticate=False)[0] == 401, 'Unauthenticated native API is denied')
                check(send_http_request(overrides={'Authorization':'Bearer wrong'})[0] == 401, 'Invalid bearer capability is denied')
                check(send_http_request(overrides={'Host':'attacker.invalid'})[0] == 403, 'Foreign Host is denied')
                check(send_http_request(overrides={'Origin':'https://attacker.invalid'})[0] == 403, 'Foreign Origin is denied')
                check(send_http_request(overrides={'Sec-Fetch-Site':'cross-site'})[0] == 403, 'Cross-site fetch is denied')
                check(send_http_request('OPTIONS')[0] == 405, 'Cross-origin preflight is not enabled')
                check(send_http_request(overrides={'Content-Type':'text/plain'})[0] == 415, 'Non-JSON mutation content type is denied')
                check(send_http_request('GET','/../../README.md',None)[0] == 404, 'Arbitrary filesystem paths are not served')
                connection = http.client.HTTPConnection(address.hostname,address.port,timeout=5)
                connection.putrequest('POST','/api')
                connection.putheader('Authorization',f'Bearer {token}')
                connection.putheader('Content-Type','application/json')
                connection.putheader('Content-Length',str(8*1024*1024+1))
                connection.endheaders()
                check(connection.getresponse().status == 413, 'Oversized declared body is rejected before upload')
                connection.close()
                check(json.loads(send_http_request(body=b'{bad')[2])['code'] == 'invalidRequest', 'Malformed native JSON is diagnosed')
                check(method_result('Unsupported/method',{})[1]['type'] == 'unknownMethod', 'Native method errors retain their envelope')

                revision = cli('get',socket,first_id)['list'][0]
                base_id = revision['fields']['revisionID']['value']
                request = dict(action='revise',itemID=first_id,expectedRevisionID=base_id,
                               operationID='http-'+uuid.uuid4().hex,unset=[],changes={'categoryOverrides':{'type':'object','value':{**copy.deepcopy(revision['fields']['categoryOverrides']['value']),fixture['columns']['ready']:{'type':'text','value':'exclude'},fixture['columns']['doing']:{'type':'text','value':'include'}}}})
                # Receive only headers, then discard the body: the client has no commit result.
                connection = http.client.HTTPConnection(address.hostname,address.port,timeout=22)
                connection.request('POST','/api',body=envelope('TractandaItem/commit',request),headers={
                    'Content-Type':'application/json','Authorization':f'Bearer {token}','Origin':origin})
                check(connection.getresponse().status == 200, 'First edit reaches the real native service')
                connection.close()
                replay = method_result('TractandaItem/commit',request)[1]
                check(replay['replayed'] and replay['revision']['fields']['categoryOverrides']['value'][fixture['columns']['doing']]['value'] == 'include', 'Lost-response retry confirms the same committed revision')
                stale = dict(request,operationID='stale-'+uuid.uuid4().hex)
                check(method_result('TractandaItem/commit',stale)[1]['type'] == 'revisionConflict', 'Concurrent stale edit is rejected')
                spoofed = dict(request,operationID='actor-'+uuid.uuid4().hex,
                               expectedRevisionID=replay['revision']['fields']['revisionID']['value'],
                               changes={'actor':{'type':'text','value':'uid:0'}})
                check(method_result('TractandaItem/commit',spoofed)[1]['type'] == 'invalidArguments', 'HTTP caller cannot choose canonical actor')
                check(cli('get',socket,first_id)['list'][0]['fields']['categoryOverrides']['value'][fixture['columns']['doing']]['value'] == 'include', 'HTTP edit is visible through the independent CLI')
                before = cli('kanban',socket,board_id)
                method_result('TractandaStore/rebuild',{})
                after = cli('kanban',socket,board_id)
                check(before['tasks'] == after['tasks'], 'Rebuild preserves current tasks, IDs, references and order')
                check(after['viewRevisionID'] == initial['viewRevisionID'], 'Task edits do not revise the board item')
                check(all('status' not in cli('get',socket,id)['list'][0]['fields'] for id in fixture['itemIDs'].values()), 'Workflow membership does not create scalar status fields')
                check(cli('get',socket,first_id)['list'][0]['fields']['classID']['value']=='EmailMessageItem', 'Board operations preserve an email item class')
                check(cli('get',socket,first_id)['list'][0]['fields']['foreignMetadata']['value']['retain']['value'], 'Category moves preserve unknown metadata')

                stop(web);web=None
                stop(native);native=None
                shutil.rmtree(store/'index')
                native = subprocess.Popen([binary,'serve',str(store),str(socket)],stdout=log,stderr=log)
                wait_for(socket,native)
                recovered = cli('kanban',socket,board_id)
                check(recovered['tasks'] == after['tasks'], 'Restart without the database reconstructs the complete board')
                if options.export:
                    destination = Path(options.export)
                    destination.mkdir(parents=True,exist_ok=True)
                    stop(native);native=None
                    shutil.copytree(store/'items',destination/'items')
                    (destination/'manifest.json').write_text(json.dumps(dict(fixture=fixture,snapshot=recovered),indent=2))
            except Exception:
                log.flush()
                print((root/'servers.log').read_text())
                raise
            finally:
                stop(web);stop(native)
                with contextlib.suppress(FileNotFoundError):socket.unlink()
    print(json.dumps(dict(passed=passed,checks=len(passed),platform=os.uname().sysname),indent=2))


if __name__ == '__main__':
    main()
