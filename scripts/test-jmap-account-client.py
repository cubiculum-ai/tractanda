#!/usr/bin/env python3
import copy
import unittest
from jmap_client import CAPABILITY, DiscoveryContext, encode_arguments, decode_result, query_arguments


class AccountClientTests(unittest.TestCase):
    def test_discovery_cache_explicit_account_metadata_refresh_and_no_replay(self):
        calls = []
        metadata = ['state-1']
        def exchange(envelope):
            calls.extend(copy.deepcopy(envelope['methodCalls']))
            method, args, call_id = envelope['methodCalls'][0]
            if method == 'TractandaSession/get':
                result = {'profile': 'tractanda.local-session.v1', 'state': metadata[0],
                    'primaryAccounts': {CAPABILITY: 'account'},
                    'accounts': {'account': {'accountCapabilities': {CAPABILITY: {}}}}}
            else: result = args
            return {'sessionState': metadata[0], 'methodResponses': [[method, result, call_id]]}
        context = DiscoveryContext(exchange)
        context.request([['TractandaStore/info', {}, 'a']])
        context.request([['TractandaStore/info', {'accountId': 'foreign'}, 'b']])
        context.request([['Core/echo', {'n': 1}, 'e']])
        metadata[0] = 'state-2'
        context.request([['TractandaItem/commit', {'operationID': 'one'}, 'c']])
        context.request([['TractandaStore/info', {}, 'd']])
        self.assertEqual([c[0] for c in calls], ['TractandaSession/get', 'TractandaStore/info', 'TractandaStore/info', 'Core/echo', 'TractandaItem/commit', 'TractandaSession/get', 'TractandaStore/info'])
        self.assertEqual(calls[1][1]['accountId'], 'account')
        self.assertEqual(calls[2][1]['accountId'], 'foreign')
        self.assertNotIn('accountId', calls[3][1])

    def test_declared_integer_slots_preserve_extrema_and_arbitrary_echo(self):
        tagged = {'type': 'object', 'value': {'literal./~': {'type': 'list', 'value': [
            {'type': 'integer', 'value': -(1 << 63)}, {'type': 'integer', 'value': (1 << 63) - 1}]}}}
        request = {'changes': {'nested': tagged}, 'operationID': 'retained'}
        wire = encode_arguments('TractandaItem/commit', request)
        self.assertEqual(wire['changes']['nested']['value']['literal./~']['value'][0]['value'], '-9223372036854775808')
        result = decode_result('TractandaItem/get', {'list': [{'id': 'item', 'fields': {'nested': wire['changes']['nested']}}]})
        self.assertEqual(result['list'][0]['fields']['nested'], tagged)
        self.assertEqual(encode_arguments('Core/echo', request), request)
        plan = {'request': request, 'commitRequest': request}
        wire_plan = encode_arguments('TractandaItem/commitCapture', plan)
        self.assertEqual(decode_result('TractandaItem/prepareCapture', wire_plan), plan)

    def test_query_builder_separates_filter_sort_and_calculate_total(self):
        result = query_arguments({'expression': 'subject == *', 'position': 4,
            'sort': [{'categoryRootID': 'axis', 'isAscending': False}]})
        self.assertEqual(result['filter'], {'expression': 'subject == *'})
        self.assertTrue(result['calculateTotal'])
        self.assertEqual(result['sort'], [{'property': 'categoryMembership', 'categoryRootId': 'axis', 'isAscending': False}])


if __name__ == '__main__': unittest.main()
