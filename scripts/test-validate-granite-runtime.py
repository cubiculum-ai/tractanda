#!/usr/bin/env python3
"""Black-box validator tests using an owned loopback fake, never real model weights."""
import errno
import json
import os
from pathlib import Path
import signal
import socket
import subprocess
import tempfile
import time
import unittest

ROOT = Path(__file__).resolve().parents[1]
VALIDATOR = ROOT / 'scripts/validate-granite-runtime.sh'
FAKE = r'''#!/usr/bin/env python3
import json, os, sys
from http.server import BaseHTTPRequestHandler, HTTPServer
alias = 'tractanda-granite-embedding-311m-multilingual-r2-vmlx-fp32-44399559'
if sys.argv[1:] == ['--describe']:
    print(json.dumps(dict(alias=alias, dimensions=768, pooling='cls', normalization='l2',
                          maximumInputTokens=32768, maximumBatchTokens=32768, assets=list(range(9)))))
    sys.exit(0)
assert sys.argv[1:4] == ['--model', os.environ['FAKE_MODEL'], '--port']
assert len(sys.argv) == 5 and 1024 <= int(sys.argv[4]) <= 65535
port = int(sys.argv[4])
open(os.environ['FAKE_PID_FILE'], 'w').write(str(os.getpid()))
with open(os.environ['FAKE_PID_LOG'], 'a') as log: log.write(str(os.getpid()) + '\n')
mode = os.environ['FAKE_MODE']
if mode == 'early-exit': sys.exit(7)
if mode == 'port-race' and not os.path.exists(os.environ['FAKE_RACE_PORT']):
    import time, errno
    open(os.environ['FAKE_RACE_PORT'], 'w').write(str(port))
    while not os.path.exists(os.environ['FAKE_RACE_READY']): time.sleep(.01)
    try: HTTPServer(('127.0.0.1', port), BaseHTTPRequestHandler)
    except OSError as error:
        assert error.errno == errno.EADDRINUSE
        print('Embedding listener waiting for 127.0.0.1:%d: address already in use; retrying until the port is free or startup is cancelled.' % port, file=sys.stderr, flush=True)
        while True: time.sleep(1)
    raise AssertionError('Expected deterministic candidate port race')
class Handler(BaseHTTPRequestHandler):
    def log_message(self, *args): pass
    def do_GET(self):
        payload = json.dumps({'pid': os.getpid() + (1 if mode == 'wrong-pid' else 0)}).encode()
        self.send_response(200); self.end_headers(); self.wfile.write(payload)
    def do_POST(self):
        open(os.environ['FAKE_POST_FILE'], 'w').write('started')
        if mode == 'die-inference': os._exit(8)
        if mode == 'hold-inference':
            import time
            while True: time.sleep(1)
        vectors = []
        for i in range(10):
            v = [0] * 768
            v[{0: 0, 3: 0, 1: 1, 4: 1, 2: 2, 5: 2}.get(i, 3)] = 1
            vectors.append({'embedding': v})
        body = json.dumps({'model': alias, 'model_revision': ':weights-bf16:compute-f32:',
                           'data': vectors, 'usage': {}}).encode()
        self.send_response(200); self.end_headers(); self.wfile.write(body)
HTTPServer(('127.0.0.1', port), Handler).serve_forever()
'''


class ValidatorTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        try:
            with socket.socket() as probe:
                probe.bind(('127.0.0.1', 0))
        except OSError as error:
            if error.errno in (errno.EPERM, errno.EACCES):
                raise unittest.SkipTest('Loopback socket creation is denied by the environment.') from error
            raise

    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='granite-validator-test-')
        self.root = Path(self.temp.name)
        self.fake = self.root / 'fake-host'
        self.fake.write_text(FAKE)
        self.fake.chmod(0o755)
        self.pidfile = self.root / 'pid'
        self.postfile = self.root / 'post'
        self.environment = dict(os.environ, TMPDIR=str(self.root), FAKE_MODEL=str(self.root / 'model'),
                                FAKE_PID_FILE=str(self.pidfile), FAKE_POST_FILE=str(self.postfile),
                                FAKE_PID_LOG=str(self.root / 'pids'), FAKE_RACE_PORT=str(self.root / 'race-port'),
                                FAKE_RACE_READY=str(self.root / 'race-ready'))

    def tearDown(self):
        self.temp.cleanup()

    def run_validator(self, mode):
        return subprocess.run(['sh', str(VALIDATOR), str(self.fake), self.environment['FAKE_MODEL']],
                              env=dict(self.environment, FAKE_MODE=mode), text=True,
                              stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=20)

    def assert_retired(self):
        if (self.root / 'pids').exists():
            for pid in (self.root / 'pids').read_text().splitlines():
                with self.assertRaises(ProcessLookupError):
                    os.kill(int(pid), 0)
        self.assertEqual(list(self.root.glob('tractanda-granite-validate.*')), [])

    def test_occupied_old_port_does_not_interfere(self):
        occupied = socket.socket()
        try:
            try:
                occupied.bind(('127.0.0.1', 48731))
                occupied.listen()
            except OSError:
                pass  # Already occupied is equally suitable; never touch that listener.
            result = self.run_validator('success')
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(len(json.loads(result.stdout)['dimensions']), 10)
            if occupied.getsockname()[1] == 48731:
                self.assertEqual(occupied.getsockopt(socket.SOL_SOCKET, socket.SO_ACCEPTCONN), 1)
            self.assert_retired()
        finally:
            occupied.close()

    def test_candidate_race_retires_only_owned_helper_without_contacting_foreign_listener(self):
        from http.server import BaseHTTPRequestHandler, HTTPServer
        import threading
        requests = []
        class Foreign(BaseHTTPRequestHandler):
            def log_message(self, *args): pass
            def do_GET(self): requests.append('GET'); self.send_error(500)
            def do_POST(self): requests.append('POST'); self.send_error(500)
        process = subprocess.Popen(['sh', str(VALIDATOR), str(self.fake), self.environment['FAKE_MODEL']],
                                   env=dict(self.environment, FAKE_MODE='port-race'),
                                   stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        server = None
        try:
            deadline = time.monotonic() + 10
            portfile = self.root / 'race-port'
            while not portfile.exists() and time.monotonic() < deadline:
                if process.poll() is not None: self.fail(process.communicate()[1])
                time.sleep(.01)
            self.assertTrue(portfile.exists())
            server = HTTPServer(('127.0.0.1', int(portfile.read_text())), Foreign)
            thread = threading.Thread(target=server.serve_forever, daemon=True); thread.start()
            (self.root / 'race-ready').touch()
            output, error = process.communicate(timeout=20)
            self.assertEqual(process.returncode, 0, error)
            self.assertIn('port raced', error)
            self.assertEqual(len(json.loads(output)['dimensions']), 10)
            self.assertEqual(requests, [])
            self.assertEqual(len((self.root / 'pids').read_text().splitlines()), 2)
            self.assert_retired()
        finally:
            if process.poll() is None: process.terminate(); process.communicate(timeout=10)
            if server is not None: server.shutdown(); server.server_close()

    def test_wrong_pid_and_host_death_fail_and_clean_up(self):
        for mode in ('wrong-pid', 'early-exit', 'die-inference'):
            with self.subTest(mode=mode):
                self.pidfile.unlink(missing_ok=True)
                self.postfile.unlink(missing_ok=True)
                result = self.run_validator(mode)
                self.assertNotEqual(result.returncode, 0)
                if mode == 'wrong-pid':
                    self.assertIn('PID differs', result.stderr)
                    self.assertFalse(self.postfile.exists(), 'A foreign health PID must never receive inference.')
                self.assert_retired()

    def test_cancel_reaps_owned_host_and_request(self):
        process = subprocess.Popen(['sh', str(VALIDATOR), str(self.fake), self.environment['FAKE_MODEL']],
                                   env=dict(self.environment, FAKE_MODE='hold-inference'),
                                   stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        try:
            deadline = time.monotonic() + 15
            while not self.postfile.exists() and time.monotonic() < deadline:
                if process.poll() is not None: self.fail(process.communicate()[1])
                time.sleep(.05)
            self.assertTrue(self.postfile.exists())
            process.send_signal(signal.SIGTERM)
            process.communicate(timeout=10)
            self.assertNotEqual(process.returncode, 0)
            self.assert_retired()
        finally:
            if process.poll() is None:
                process.kill()
                process.communicate()


if __name__ == '__main__':
    unittest.main()
