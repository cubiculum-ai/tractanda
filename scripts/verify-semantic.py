#!/usr/bin/env python3
"""Semantic transport/lifecycle regression with an explicitly synthetic local provider.

Uses disposable stores only. This validates the native API, CLI and MCP contract,
not embedding-model quality (which has its own frozen, real-model evaluation).
"""
import argparse
from collections import Counter
import hashlib
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import importlib.util
import json
from pathlib import Path
import shutil
import subprocess
import tempfile
import threading
import time


def module(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    result = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(result)
    return result


wire = module('semantic_wire', Path(__file__).with_name('verify-ipc.py'))
mcp = module('semantic_mcp', Path(__file__).with_name('verify-mcp.py'))


class Provider:
    def __init__(self):
        self.gate = threading.Event()
        self.entered = threading.Event()
        self.lock = threading.Lock()
        self.counts = Counter()
        self.failure = False
        self.vector_for = self.hashed_vector
        owner = self

        class Handler(BaseHTTPRequestHandler):
            def log_message(self, *_):
                pass

            def do_POST(self):
                assert self.path == '/v1/embeddings'
                request = json.loads(self.rfile.read(int(self.headers['Content-Length'])))
                inputs = request['input']
                with owner.lock:
                    owner.counts.update(inputs)
                owner.entered.set()
                owner.gate.wait(25)
                if owner.failure:
                    self.send_error(503)
                    return
                entries = []
                for index, text in enumerate(inputs):
                    vector = owner.vector_for(text)
                    entries.append({'index':index,'embedding':vector})
                data = json.dumps({'model':request['model'],'data':entries}).encode()
                self.send_response(200)
                self.send_header('Content-Type','application/json')
                self.send_header('Content-Length',str(len(data)))
                self.end_headers()
                try:
                    self.wfile.write(data)
                except (BrokenPipeError, ConnectionResetError):
                    pass

        self.server = ThreadingHTTPServer(('127.0.0.1',0), Handler)
        self.server.daemon_threads = True
        self.thread = threading.Thread(target=self.server.serve_forever,daemon=True)

    @staticmethod
    def hashed_vector(text):
        digest = hashlib.sha256(text.encode()).digest()
        return [1 + digest[i] / 255 for i in range(3)]

    @property
    def endpoint(self):
        return f'http://127.0.0.1:{self.server.server_port}/v1/embeddings'

    def __enter__(self):
        self.thread.start()
        return self

    def __exit__(self, *_):
        self.gate.set()
        self.server.shutdown()
        self.server.server_close()
        self.thread.join(timeout=3)

    def total(self):
        with self.lock:
            return sum(self.counts.values())


def wait_for(call, predicate, timeout=20):
    deadline=time.monotonic()+timeout
    while True:
        result=call()
        if predicate(result): return result
        assert time.monotonic()<deadline, result
        time.sleep(.05)


def ready(client):
    return wait_for(lambda:client.call('TractandaSemantic/status'),lambda s:s['coverage']=='complete')


def results(client, query):
    return wait_for(lambda:client.call('TractandaSemantic/results',{'queryID':query['queryID']}),
                    lambda s:s['state']!='pending')


def search(client, **arguments):
    return results(client,client.call('TractandaSemantic/search',arguments))


def validate_passages(client, result):
    assert result['state']=='ready',result
    identities=set()
    for hit in result['results']:
        assert hit['itemID'] not in identities
        identities.add(hit['itemID'])
        revision=client.get(hit['itemID'])
        assert wire.revision_id(revision)==hit['revisionID']
        fields=revision['fields']
        source='\n\n'.join(key+':\n'+fields[key]['value'] for key in ['subject','body'] if fields.get(key,wire.text(''))['value'].strip()).encode()
        assert source[hit['byteStart']:hit['byteEnd']].decode()==hit['passage']
        assert -1.001<=hit['similarity']<=1.001


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('binary',type=Path)
    parser.add_argument('adapter',type=Path)
    parser.add_argument('--output',required=True,type=Path)
    args=parser.parse_args()
    binary=str(args.binary.resolve())
    adapter=str(args.adapter.resolve())
    checks=[]
    with tempfile.TemporaryDirectory(prefix='tractanda-semantic-',dir='/tmp') as temporary, Provider() as provider:
        root=Path(temporary)
        store,path=root/'store',root/'s'
        config={'formatVersion':2,'configurationID':'fixture-config-1','operationID':'configure-fixture-1',
            'endpoint':provider.endpoint,'model':'synthetic-contract-v1','modelRevision':'sha256:test-only',
            'dimensions':3,'documentPrefix':'passage: ','queryPrefix':'query: ',
            'chunkBytes':384,'overlapBytes':64,'pooling':'mean','normalization':'l2',
            'inputEncoding':'item-text-utf8-v2'}
        with wire.server(binary,store,path) as client:
            assert client.call('TractandaSemantic/status')['enabled'] is False
            note=client.commit(wire.intent('create','first',class_id='NoteItem',changes={
                'subject':wire.text('Schach und Kalender'),'body':wire.text('Frédéric ☃ discusses the chess club. '*30)}))['revision']
            before=wire.manifest(store)
            configured=client.call('TractandaSemantic/configure',{'configuration':config})
            assert configured['configurationID']==config['configurationID']
            assert provider.entered.wait(3),'Background provider did not start'
            start=time.monotonic()
            empty=client.commit(wire.intent('create','empty-body',class_id='NoteItem',changes={
                'subject':wire.text('Only a subject')}))['revision']
            elapsed=time.monotonic()-start
            assert elapsed<2,'Commit waited for held embedding request'
            assert client.call('TractandaSemantic/status')['coverage']=='partial'
            provider.gate.set()
            assert ready(client)['indexedItems']==2
            assert client.call('TractandaSemantic/configure',{'configuration':config})['configurationID']==config['configurationID']
            assert all(wire.manifest(store)[key]==value for key,value in before.items())
            checks.append('Disabled by default; held inference does not block commits; asynchronous coverage and exact configure replay')

            initial=search(client,text='chess club',limit=2)
            assert len(initial['results'])==2 and not initial['partialCoverage']
            validate_passages(client,initial)
            filtered=search(client,text='subject',expression='subject == "Only a subject"',limit=1)
            assert [h['itemID'] for h in filtered['results']]==[wire.item_id(empty)]
            validate_passages(client,filtered)
            malformed=client.batch([['TractandaSemantic/search',{'text':'x','expression':'garbage ??'},'bad']])[0]
            assert malformed[0]=='error'
            checks.append('Current UTF-8 source passages, one result per item, empty-body safety and deterministic native filters')

            count=provider.total()
            revised=client.commit(wire.intent('revise','metadata',wire.item_id(note),wire.revision_id(note),
                changes={'privateFixtureField':{'type':'integer','value':7}}))['revision']
            ready(client)
            time.sleep(.6)
            assert provider.total()==count,'Metadata-only edit recomputed embeddings'
            reranked=results(client,{'queryID':initial['queryID']})
            validate_passages(client,reranked)
            assert next(h for h in reranked['results'] if h['itemID']==wire.item_id(note))['revisionID']==wire.revision_id(revised)
            checks.append('Metadata revisions relabel vectors and previously submitted queries return current revisions')

            provider.entered.clear()
            provider.gate.clear()
            changed=client.commit(wire.intent('revise','change',wire.item_id(note),wire.revision_id(revised),
                changes={'body':wire.text('Replacement content after an edit.')}))['revision']
            assert provider.entered.wait(3)
            stale=results(client,{'queryID':initial['queryID']})
            assert wire.item_id(note) not in [h['itemID'] for h in stale['results']]
            assert stale['partialCoverage']
            client.commit(wire.intent('revise','delete',wire.item_id(note),wire.revision_id(changed),
                changes={'isDeleted':{'type':'boolean','value':True}}))
            provider.gate.set()
            assert ready(client)['indexableItems']==1
            assert wire.item_id(note) not in [h['itemID'] for h in results(client,{'queryID':initial['queryID']})['results']]
            checks.append('Content changes suppress stale vectors; deleted items cannot publish or return late work')

            command=json.loads(subprocess.check_output([binary,'semantic-search',str(path),'Only a subject'],timeout=20))
            validate_passages(client,command)
            assert command['results'][0]['itemID']==wire.item_id(empty)
            with mcp.MCPClient(adapter,path) as agent:
                agent.initialize()
                names={t['name'] for t in agent.request('tools/list')['tools']}
                assert {'tractanda_semantic_status','tractanda_semantic_search','tractanda_semantic_results'}<=names
                assert agent.tool('tractanda_semantic_status')==client.call('TractandaSemantic/status')
                query=agent.tool('tractanda_semantic_search',{'text':'Only a subject','limit':1})
                result=wait_for(lambda:agent.tool('tractanda_semantic_results',{'queryID':query['queryID']}),lambda r:r['state']!='pending')
                validate_passages(client,result)
            checks.append('Shipped CLI polling and real MCP stdio discovery/status/search/results use the native service')

            canonical=wire.manifest(store)
            fts=client.call('TractandaItem/query',{'text':'Only'})['ids']
            reset={'expectedConfigurationID':config['configurationID'],'operationID':'reset-fixture'}
            client.call('TractandaSemantic/reset',reset)
            ready(client)
            count=provider.total()
            client.call('TractandaSemantic/reset',reset)
            ready(client)
            assert provider.total()==count,'Replaying a reset discarded newly rebuilt data'
            assert wire.manifest(store)==canonical
            assert client.call('TractandaItem/query',{'text':'Only'})['ids']==fts
            checks.append('Reset exact replay preserves rebuilt data, canonical bytes and FTS results')

        # Delete the disposable vector index, retain operational configuration and canonical files.
        for suffix in ('','-wal','-shm'):
            (store/'index'/('semantic.sqlite'+suffix)).unlink(missing_ok=True)
        with wire.server(binary,store,path) as client:
            assert ready(client)['indexedItems']==1
            validate_passages(client,search(client,text='Only a subject'))
            assert wire.manifest(store)==canonical
        (store/'index/semantic.sqlite').write_bytes(b'intentionally corrupt disposable index')
        with wire.server(binary,store,path) as client:
            assert ready(client)['indexedItems']==1
            assert list((store/'index').glob('semantic.quarantine.*.sqlite'))
            assert wire.manifest(store)==canonical
            assert client.call('TractandaItem/query',{'text':'Only'})['ids']==fts
        checks.append('Restart after index loss and actual SQLite corruption reconstructs vectors without canonical/FTS changes')

    report={'status':'passed','provider':'synthetic local HTTP contract fixture, not a quality benchmark',
        'checks':checks,'nonblockingCommitSeconds':elapsed,'binarySHA256':hashlib.sha256(Path(binary).read_bytes()).hexdigest(),
        'adapterSHA256':hashlib.sha256(Path(adapter).read_bytes()).hexdigest()}
    args.output.parent.mkdir(parents=True,exist_ok=True)
    args.output.write_text(json.dumps(report,indent=2)+'\n')
    print(json.dumps(report))


if __name__=='__main__':
    main()
