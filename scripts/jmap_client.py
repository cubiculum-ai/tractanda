"""Independent local JMAP fixture client. Discovery never retries a completed request."""
import threading

CAPABILITY = "https://tractanda.ai/ns/jmap/1"
SESSION_METHODS = {"Core/echo", "TractandaSession/get", "TractandaAuth/createSession"}


class DiscoveryContext:
    def __init__(self, exchange, *, arguments_are_wire=False):
        self.exchange = exchange
        self.arguments_are_wire = arguments_are_wire
        self.session = None
        self.lock = threading.RLock()

    def _prepare(self, calls):
        if any(method.startswith("Tractanda") and method not in SESSION_METHODS for method, _, _ in calls):
            if self.session is None:
                reply = self.exchange({"using": ["urn:ietf:params:jmap:core", CAPABILITY],
                    "methodCalls": [["TractandaSession/get", {}, "discovery"]]})
                call = reply["methodResponses"][0]
                assert call[0] == "TractandaSession/get" and call[2] == "discovery", reply
                document = call[1]
                account = document["primaryAccounts"][CAPABILITY]
                assert document["profile"] == "tractanda.local-session.v1"
                assert CAPABILITY in document["accounts"][account]["accountCapabilities"]
                self.session = (account, document["state"])
        prepared = []
        for method, args, call_id in calls:
            args = dict(args)
            if method.startswith("Tractanda") and method not in SESSION_METHODS and "accountId" not in args and "#accountId" not in args:
                args["accountId"] = self.session[0]
            prepared.append([method, args if self.arguments_are_wire else encode_arguments(method, args), call_id])
        return prepared

    def request(self, calls):
        with self.lock:
            prepared = self._prepare(calls)
        reply = self.exchange({"using": ["urn:ietf:params:jmap:core", CAPABILITY], "methodCalls": prepared})
        with self.lock:
            if self.session and reply.get("sessionState", self.session[1]) != self.session[1]:
                self.session = None
        if not self.arguments_are_wire:
            reply = dict(reply)
            reply['methodResponses'] = [[method, decode_result(method, result) if method != 'error' else result, call_id]
                for method, result, call_id in reply.get('methodResponses', [])]
        return reply


def query_arguments(criteria):
    """Explicit fixture convenience builder; the emitted method uses the standard query schema."""
    filter_keys = {'expression', 'text', 'categoryPath', 'excludedCategoryIDs', 'viewID', 'sectionID', 'at', 'timeZone'}
    result = {'filter': {key: value for key, value in criteria.items() if key in filter_keys}, 'calculateTotal': True}
    for key, value in criteria.items():
        if key in filter_keys: continue
        if key == 'sort':
            result[key] = [dict(property='categoryMembership', categoryRootId=entry['categoryRootID'],
                isAscending=entry.get('isAscending', True)) if 'categoryRootID' in entry else entry for entry in value]
        else: result[key] = value
    return result


_ARGUMENT_PATHS = {
    'TractandaItem/commit': [('changes', '*')],
    'TractandaItem/resolveConflict': [('changes', '*')],
    'TractandaSync/acceptReview': [('changes', '*')],
    'TractandaItem/prepareCapture': [('request', 'changes', '*')],
    'TractandaItem/commitCapture': [('request', 'changes', '*'), ('commitRequest', 'changes', '*')],
    'TractandaItem/setSharing': [('permissions',)],
    'TractandaLearning/settings': [('settings',)],
    'TractandaStore/configureAccess': [('configuration',)],
    'TractandaCategory/installTemplate': [('template', 'entries', '*', 'fields', '*')],
    'TractandaPeerPersonal/admin': [('fields', '*')],
}
_RESULT_PATHS = {
    'TractandaItem/prepareCapture': [('request', 'changes', '*'), ('commitRequest', 'changes', '*')],
    'TractandaItem/sharing': [('permissions',)], 'TractandaItem/setSharing': [('permissions',)],
    'TractandaItem/resolve': [('value',)],
    'TractandaItem/get': [('list', '*', 'fields', '*')],
    'TractandaItem/getBounded': [('list', '*', 'fields', '*')],
    'TractandaRevision/get': [('list', '*', 'fields', '*')],
    'TractandaItem/history': [('list', '*', 'fields', '*')],
}


def _tagged(value, to_wire):
    value = dict(value)
    if value['type'] == 'integer':
        raw = value['value']
        if to_wire:
            assert type(raw) is int and -(1 << 63) <= raw < (1 << 63)
            value['value'] = str(raw)
        else:
            assert type(raw) is str and str(int(raw)) == raw and -(1 << 63) <= int(raw) < (1 << 63)
            value['value'] = int(raw)
    elif value['type'] == 'list': value['value'] = [_tagged(child, to_wire) for child in value['value']]
    elif value['type'] == 'object': value['value'] = {key: _tagged(child, to_wire) for key, child in value['value'].items()}
    return value


def _path(value, path, to_wire):
    if value is None: return value
    if not path: return _tagged(value, to_wire)
    name, *rest = path
    if name == '*':
        if isinstance(value, list): return [_path(child, rest, to_wire) for child in value]
        return {key: _path(child, rest, to_wire) for key, child in value.items()}
    return {key: _path(child, rest, to_wire) if key == name else child for key, child in value.items()}


def encode_arguments(method, arguments):
    for path in _ARGUMENT_PATHS.get(method, []): arguments = _path(arguments, path, True)
    return arguments


def decode_result(method, result):
    for path in _RESULT_PATHS.get(method, []): result = _path(result, path, False)
    return result
