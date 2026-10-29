#!/usr/bin/env python3
"""Exercise the actual shell wrapper's parser and process-exit gates with tiny logs."""
import argparse
import os
from pathlib import Path
import re
import subprocess
import tempfile
import unittest

ROOT=Path(__file__).resolve().parents[1]
TEXT=(ROOT/'scripts/test.sh').read_text()
START=TEXT.index('run_tests() (')
END=TEXT.index('\n)\n',START)+3
FUNCTION=TEXT[START:END]
PASS='Test Suite \'All tests\' passed\nExecuted 1 tests, with 0 failures (0 unexpected)\n'
ACTUAL_LOG=None


class SwiftTestWrapperTests(unittest.TestCase):
    def invoke(self,text,process_exit=0):
        with tempfile.TemporaryDirectory(prefix='tractanda-wrapper-') as temporary:
            root=Path(temporary);bin=root/'bin';bin.mkdir();fixture=root/'fixture.log';fixture.write_text(text)
            swift=bin/'swift'
            swift.write_text('#!/bin/sh\ncat "$WRAPPER_FIXTURE_LOG"\nexit "$WRAPPER_FIXTURE_EXIT"\n')
            swift.chmod(0o755)
            script='set -eu\n'+FUNCTION+'\nrun_tests "$1" "$2"\n'
            result=subprocess.run(['sh','-c',script,'wrapper',str(root/'result.log'),str(root/'scratch')],
                env={**os.environ,'PATH':str(bin)+os.pathsep+os.environ.get('PATH',''),
                     'WRAPPER_FIXTURE_LOG':str(fixture),'WRAPPER_FIXTURE_EXIT':str(process_exit)},
                capture_output=True,text=True)
            return result.returncode,result.stdout+result.stderr

    def test_actual_colored_warning_source_context_is_not_an_error(self):
        excerpt=(
            '/__w/tractanda/tractanda/Sources/TractandaCore/Store.swift:12170:17: '
            '\x1b[1;33mwarning: \x1b[1;39minitialization of immutable value was never used\x1b[0m\n'
            '\x1b[0;36m12172 |\x1b[0m                 packageID: packageID, phase: intakePhase, error: error)\n')
        for warning in (excerpt,excerpt.replace('\x1b','^[')):
            with self.subTest(caret_escaped='^[' in warning):
                code,output=self.invoke(warning+PASS)
                self.assertEqual(code,0,output)

    def test_real_compiler_tool_fatal_and_unnumbered_caret_errors_remain_rejected(self):
        for diagnostic in ('file.swift:9:2: error: bad expression','clang: error: missing input',
                           'fatal error: unavailable module','error: emit-module failed',
                           '    | ^ error: invalid expression',
                           'file.swift:1: warning: quoted "error: label"'):
            with self.subTest(diagnostic=diagnostic):
                code,output=self.invoke(diagnostic+'\n'+PASS)
                self.assertNotEqual(code,0,output)

    def test_xctest_swifttesting_and_no_tests_failures_remain_rejected(self):
        for failure in ("Test Case 'Case.test' failed (0.1 seconds)","Test Suite 'All tests' failed",
                        '✘ Test example() failed after 0.1 seconds with 1 issue.',
                        '✘ Test run with 1 tests failed after 0.1 seconds with 1 issue.',
                        'No tests found'):
            with self.subTest(failure=failure):
                self.assertNotEqual(self.invoke(failure+'\n'+PASS)[0],0)

    def test_empty_zero_and_source_only_fake_completion_remain_rejected(self):
        for empty in ('','Executed 0 tests, with 0 failures','Test run with 0 tests passed',
                      '17 | Executed 9 tests, with 0 failures'):
            with self.subTest(empty=empty):self.assertNotEqual(self.invoke(empty)[0],0)

    def test_success_log_does_not_override_nonzero_swift_process_exit(self):
        self.assertNotEqual(self.invoke(PASS,process_exit=7)[0],0)
        self.assertEqual(self.invoke(PASS,process_exit=0)[0],0)

    def test_whole_actual_ci_log(self):
        if ACTUAL_LOG is None:
            self.skipTest('Full actual CI log is a private operator input')
        rows=[]
        for line in ACTUAL_LOG.read_text().splitlines():
            parts=line.split('\t',2)
            body=parts[-1] if len(parts)==3 else line
            body=re.sub(r'^\d{4}-\d{2}-\d{2}T\S+\s','',body)
            rows.append(body)
        raw='\n'.join(rows)
        self.assertFalse(re.search(r"Test (?:Case|Suite) '[^']+' failed",raw))
        self.assertEqual(len(re.findall(r'\berror:',raw)),1)
        code,output=self.invoke(raw)
        self.assertEqual(code,0,output[-3000:])


if __name__=='__main__':
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--actual-ci-log',type=Path)
    args,rest=parser.parse_known_args()
    ACTUAL_LOG=args.actual_ci_log
    unittest.main(argv=[__file__,*rest])
