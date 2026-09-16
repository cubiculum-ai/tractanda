#!/usr/bin/env python3
"""Independent learning API/CLI checks, including canonical-only transfer and retry recovery."""
import argparse
import importlib.util
import json
import pathlib
import shutil
import subprocess
import tempfile

spec = importlib.util.spec_from_file_location('ipc', pathlib.Path(__file__).with_name('verify-ipc.py'))
ipc = importlib.util.module_from_spec(spec)
spec.loader.exec_module(ipc)


def check(condition, message):
    assert condition, message
    print('PASS:', message, flush=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('binary')
    parser.add_argument('--export', type=pathlib.Path)
    parser.add_argument('--import-from', dest='import_from', type=pathlib.Path)
    args = parser.parse_args()
    binary = str(pathlib.Path(args.binary).resolve())
    with tempfile.TemporaryDirectory(prefix='tl-') as temporary:
        root = pathlib.Path(temporary)
        store, socket = root/'store', root/'server.sock'
        if args.import_from:
            store.mkdir(mode=0o700)
            shutil.copytree(args.import_from/'items', store/'items')
            manifest = json.loads((args.import_from/'manifest.json').read_text())
        with ipc.server(binary, store, socket) as client:
            def call(name, **arguments):
                return client.call('TractandaLearning/'+name, arguments)

            def cli(*arguments):
                return json.loads(subprocess.check_output([binary, arguments[0], str(socket), *map(str, arguments[1:])]))

            def create(text, label=None):
                fields = {'subject': ipc.text(text)}
                if label:
                    fields['categoryOverrides'] = {'type':'object','value':{category:ipc.text(label)}}
                return client.commit(ipc.intent('create', 'create-'+text, class_id='Item', changes=fields))['revision']

            if not args.import_from:
                category_revision = client.commit(ipc.intent('create', 'category', class_id='Item', changes={
                    'subject':ipc.text('Chess'),
                    'selection':{'type':'object','value':{'language':ipc.text('tractanda.spotlight.v0'),
                                                          'expression':ipc.text('subject == "no matching example"')}}
                }))['revision']
                category = ipc.item_id(category_revision)
                for words in ['chess board players','chess players tournament']:
                    create(words, 'include')
                for words in ['garden soil flowers','garden soil vegetables']:
                    create(words, 'exclude')
                candidate = create('chess tournament board')
                later = create('chess players')
                before = client.call('TractandaStore/info')['state']
                check(cli('learning-status',category)['status'] == 'untrained', 'Untrained state is explicit')
                check(cli('suggest',category)['list'] == [], 'Suggest does not train implicitly')
                model = cli('learn',category)
                check(model['status'] == 'ready', 'CLI trains a category through the server')
                check((model['positiveExamples'],model['negativeExamples'],model['unknownItems']) == (2,2,2), 'Unassigned items remain unknown')
                check(client.call('TractandaStore/info')['state'] == before, 'Training does not revise canonical state')
                check(cli('learn',category)['modelID'] == model['modelID'], 'Repeated unchanged training preserves model identity')
                suggestions = cli('suggest',category)
                check({s['itemID'] for s in suggestions['list']} == {ipc.item_id(candidate),ipc.item_id(later)}, 'Suggestions contain unknown matching items only')
                check(len(cli('suggest-categories',ipc.item_id(candidate),category)['list']) == 1, 'CLI supports item-to-category suggestions')
                check(call('suggest',categoryID=category,expression='subject == "chess players"')['total'] == 1, 'Candidate expressions use the same portable query grammar')
                state = suggestions['learning']['queryState']
                check(len(call('suggest',categoryID=category,position=1,limit=1,ifInState=state)['list']) == 1, 'Bounded suggestion pagination is available')
                cli('learning-reset',category)
                error = client.batch([['TractandaLearning/suggest',{'categoryID':category,'ifInState':state},'page']])[0]
                check(error[0] == 'error' and error[1]['type'] == 'stateMismatch', 'Model reset invalidates pagination even without an item edit')
                model = cli('learn',category)
                request = dict(itemID=ipc.item_id(candidate),categoryID=category,
                               expectedRevisionID=ipc.revision_id(candidate),operationID='accept-suggestion',
                               action='accept',modelID=model['modelID'])
                accepted = call('feedback',**request)['revision']
                check(accepted['fields']['categoryOverrides']['value'][category] == ipc.text('include'), 'Acceptance uses the existing versioned manual assignment')
                check(call('status',categoryID=category)['status'] == 'staleModel', 'Feedback invalidates an affected training model')
                check(call('feedback',**request)['replayed'], 'Lost-response retry returns the existing feedback receipt')
                different = dict(request,action='negative')
                error = client.batch([['TractandaLearning/feedback',different,'mismatch']])[0]
                check(error[0] == 'error' and error[1]['type'] == 'operationMismatch', 'A reused operation ID cannot change feedback')
                check(len(client.call('TractandaItem/history',{'itemID':ipc.item_id(candidate)})['list']) == 2, 'Feedback retries publish one revision')
                settings = {'type':'object','value':{'profile':ipc.text('tractanda.category-learning.v1'),
                                                   'threshold':{'type':'real','value':0.2}}}
                settings_request = dict(categoryID=category,expectedRevisionID=ipc.revision_id(category_revision),
                                        operationID='settings',settings=settings)
                result = cli('learning-settings',category,ipc.revision_id(category_revision),'settings',json.dumps(settings))
                check(call('settings',**settings_request)['replayed'], 'Settings edits retain retry semantics')
                check(result['revision']['fields']['learningSettings']['value']['threshold']['value'] == 0.2, 'Settings are canonical typed properties')
                invalid_settings = dict(settings_request,operationID='unknown-setting',settings={'type':'object','value':{'profile':ipc.text('unknown')}})
                error = client.batch([['TractandaLearning/settings',invalid_settings,'invalid']])[0]
                check(error[0] == 'error' and error[1]['type'] == 'invalidLearningSettings', 'Unknown settings profiles are rejected')
                model = cli('learn',category)
                suggestion = cli('suggest',category)['list'][0]
                check(suggestion['itemID'] == ipc.item_id(later), 'Accepted items disappear from suggestions')
                manifest = dict(categoryID=category,candidateID=ipc.item_id(later),accepted=accepted,
                                feedbackRequest=request,settingsRequest=settings_request,score=suggestion['score'])
            else:
                category = manifest['categoryID']
                check(client.get(ipc.item_id(manifest['accepted'])) == manifest['accepted'], 'Canonical-only transfer preserves the accepted revision')
                check(cli('learning-status',category)['status'] == 'untrained', 'A canonical-only copy needs training, not a copied database or model')
                check(call('feedback',**manifest['feedbackRequest'])['replayed'], 'Feedback receipt is recovered from files on the other platform')
                check(call('settings',**manifest['settingsRequest'])['replayed'], 'Settings receipt is recovered from files on the other platform')
                model = cli('learn',category)
                check((model['positiveExamples'],model['negativeExamples']) == (3,2), 'Relearning uses recovered assignments and exclusions')
                suggestion = cli('suggest',category)['list'][0]
                check(suggestion['itemID'] == manifest['candidateID'], 'Rebuilt model suggests the same remaining item')
                check(abs(suggestion['score'] - manifest['score']) < 1e-9, 'Category text tokenization and scores agree across the transfer')
            check(call('reset',categoryID=category)['status'] == 'untrained', 'Per-category reset discards derived learning')
            check(client.get(ipc.item_id(manifest['accepted'])) == manifest['accepted'], 'Reset leaves feedback and manual assignments intact')
            client.call('TractandaStore/rebuild')
            check(cli('learn',category)['status'] == 'ready', 'Rebuilt index can train again from canonical files')
        if args.export:
            args.export.mkdir(parents=True,exist_ok=True)
            shutil.copytree(store/'items',args.export/'items')
            (args.export/'manifest.json').write_text(json.dumps(manifest,indent=2)+'\n')
        print('PASS: learning workflow and canonical recovery',flush=True)


if __name__ == '__main__':
    main()
