#!/usr/bin/env python3
"""Create an ordinary project category and optional status-tagged note.

No saved Kanban view is created. Use --project-root and --status-root to target
existing category dimensions. Omit both for shared synthetic example dimensions.
All changes use the public native API and exact-retry operation identifiers.
"""
import argparse
import hashlib
import json
import subprocess


def tagged(kind, value):
    return {'type': kind, 'value': value}


def text(value):
    return tagged('text', value)


def reference(identity):
    return tagged('reference', {'itemID': identity})


def identity(revision):
    return revision['fields']['itemID']['value']


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('socket', help='Socket of the running server to modify')
    parser.add_argument('name', help='Readable project name')
    parser.add_argument('--binary', default='tractanda', help='Path to the built CLI')
    parser.add_argument('--key', help='Stable idempotency key; defaults to root/name')
    parser.add_argument('--project-root', help='Existing parent category for the new project')
    parser.add_argument('--status-root', help='Existing status category with status children')
    parser.add_argument('--empty', action='store_true', help='Omit the example note')
    args = parser.parse_args()
    name = args.name.strip()
    if not name:
        parser.error('Project name must not be empty.')
    if bool(args.project_root) != bool(args.status_root):
        parser.error('Supply both --project-root and --status-root, or neither.')

    def call(method, arguments):
        result = subprocess.run([args.binary, 'call', args.socket, method],
                                input=json.dumps(arguments), text=True,
                                capture_output=True, check=True)
        return json.loads(result.stdout)

    def commit(action, operation, fields, **extra):
        return call('TractandaItem/commit', {
            'action': action, 'operationID': operation,
            'changes': fields, 'unset': [], **extra,
        })['revision']

    selection = tagged('object', {'language': text('tractanda.spotlight.v0'),
                                   'expression': text('itemID == ""')})

    def category(operation, title, parents=(), order=0):
        return commit('create', operation, {
            'subject': text(title), 'selection': selection,
            'categoryParents': tagged('list', [reference(i) for i in parents]),
            'categoryOrder': tagged('integer', order),
        }, classID='Item')

    if args.project_root:
        roots = call('TractandaItem/get', {'ids': [args.project_root, args.status_root]})
        found = {identity(r): r for r in roots['list']}
        if any(i not in found or 'selection' not in found[i]['fields'] or
               found[i]['fields'].get('isDeleted', {}).get('value', False)
               for i in [args.project_root, args.status_root]):
            parser.error('Both roots must be readable current categories.')
        project_root, status_root = args.project_root, args.status_root
        categories, position = {}, 0
        while True:
            page = call('TractandaItem/query', {'expression': 'selection == *',
                                               'position': position, 'limit': 64})
            if page['ids']:
                values = call('TractandaItem/get', {'ids': page['ids']})['list']
                categories.update({identity(r): r for r in values})
            position += len(page['ids'])
            if position >= page['total']:
                break
            if not page['ids']:
                parser.error('The category catalog changed; retry setup.')
        children = {}
        for i, r in categories.items():
            for p in r['fields'].get('categoryParents', {}).get('value', []):
                children.setdefault(p['value']['itemID'], set()).add(i)
        descendants, pending = set(), list(children.get(status_root, ()))
        while pending:
            i = pending.pop()
            if i in descendants or i == status_root:
                continue
            descendants.add(i)
            pending.extend(children.get(i, ()))
        columns = sorted((i for i in descendants if not children.get(i)), key=lambda i: (
            categories[i]['fields'].get('categoryOrder', {}).get('value', 0),
            categories[i]['fields'].get('subject', {}).get('value', ''), i))
        if not columns:
            parser.error('The status root needs at least one readable status child.')
        default = found[status_root]['fields'].get('defaultCategory', {}).get('value', {}).get('itemID')
        default = default if default in columns else columns[0]
    else:
        # Shared by repeated invocations on this store; operation replay preserves
        # later manual edits. These are example data, not built-in system categories.
        project_root = identity(category('example-categories-v1-projects', 'Projects'))
        status = category('example-categories-v1-status', 'Status')
        status_root = identity(status)
        columns = [identity(category(f'example-categories-v1-status-{order}', title,
                                     [status_root], order))
                   for order, title in enumerate(['Backlog', 'In progress', 'Done'])]
        default = columns[0]
        commit('revise', 'example-categories-v1-status-defaults', {
            'defaultCategory': reference(default),
            'completionCategory': reference(columns[-1]),
        }, itemID=status_root, expectedRevisionID=status['fields']['revisionID']['value'])

    key = hashlib.sha256((args.key or (project_root + '/' + name)).encode('utf-8')).hexdigest()
    prefix = 'example-project-v2-' + key
    project_id = identity(category(prefix + '-project', name, [project_root]))
    if not args.empty:
        commit('create', prefix + '-note', {
            'subject': text('Try ' + name),
            'body': text('An ordinary item associated with this project and a status category.'),
            'categoryOverrides': tagged('object', {
                project_id: text('include'), default: text('include'),
            }),
        }, classID='Item')
    print(json.dumps({'projectID': project_id, 'projectRootID': project_root,
                     'statusRootID': status_root, 'columnIDs': columns, 'name': name}, indent=2))


if __name__ == '__main__':
    main()
