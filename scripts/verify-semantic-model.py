#!/usr/bin/env python3
"""End-to-end Swift/Vec1 check against a real, already-running local model.

Does not download models, configure a live store, or measure general model quality.
"""
import argparse
import importlib.util
import json
from pathlib import Path
import tempfile

spec=importlib.util.spec_from_file_location('semantic_checks',Path(__file__).with_name('verify-semantic.py'))
checks=importlib.util.module_from_spec(spec)
spec.loader.exec_module(checks)


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('binary',type=Path)
    parser.add_argument('configuration',type=Path)
    parser.add_argument('--output',type=Path,required=True)
    args=parser.parse_args()
    config=json.loads(args.configuration.read_text())
    wire=checks.wire
    with tempfile.TemporaryDirectory(prefix='tractanda-real-model-',dir='/tmp') as tmp:
        root=Path(tmp)
        with wire.server(str(args.binary.resolve()),root/'store',root/'s') as client:
            notes=[]
            for index,(subject,body) in enumerate([
                ('Chess club call','Call Fred about the chess tournament on Saturday.'),
                ('Vegetable garden','Tomato seedlings need watering and compost.'),
                ('Invoice payment','Pay the electricity bill by the end of the month.'),
            ]):
                notes.append(client.commit(wire.intent('create',f'model-note-{index}',class_id='Item',changes={
                    'subject':wire.text(subject),'body':wire.text(body)}))['revision'])
            manifest=wire.manifest(root/'store')
            client.call('TractandaSemantic/configure',{'configuration':config})
            status=checks.ready(client)
            assert status['indexedItems']==3,status
            results=[]
            for query in ('Who should I telephone about the chess tournament?', 'Wen soll ich wegen des Schachturniers anrufen?'):
                result=checks.search(client,text=query,limit=3)
                checks.validate_passages(client,result)
                assert not result['partialCoverage'] and len(result['results'])==3,result
                assert result['results'][0]['itemID']==wire.item_id(notes[0]),result
                results.append({'query':query,'results':result})
            assert wire.manifest(root/'store')==manifest
            report={'status':'passed','indexedItems':3,'canonicalFilesUnchanged':True,
                'profileID':status['profileID'],'model':status['model'],'queries':results,
                'scope':'Three synthetic texts; integration check, not a model quality benchmark'}
    args.output.parent.mkdir(parents=True,exist_ok=True)
    args.output.write_text(json.dumps(report,indent=2,ensure_ascii=False)+'\n')
    print(json.dumps({k:v for k,v in report.items() if k!='queries'}))


if __name__=='__main__': main()
