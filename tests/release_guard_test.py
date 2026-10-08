"""Run the actual release identity script without contacting GitHub."""
import os
from pathlib import Path
import subprocess
import tempfile
import unittest


class ReleaseGuard(unittest.TestCase):
    def test_release_controls(self):
        lines = Path('.github/workflows/release.yml').read_text().splitlines()
        start = next(i for i, line in enumerate(lines) if line == '      - name: Determine release version')
        start = next(i for i in range(start, len(lines)) if lines[i] == '        run: |') + 1
        end = next(i for i in range(start, len(lines)) if lines[i].startswith('      - '))
        script = '\n'.join(line[10:] for line in lines[start:end])+'\n'
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            git = root/'git'
            git.write_text('#!/bin/sh\ncase "$1" in\nfetch|tag) exit 0 ;;\nrev-parse) test "$TAG_EXISTS" = yes ;;\n*) exit 90 ;;\nesac\n')
            git.chmod(0o755)
            base = dict(os.environ, PATH=str(root)+os.pathsep+os.environ['PATH'],
                        GITHUB_REF='refs/heads/main', TARGET='cli', BUMP='patch',
                        GITHUB_OUTPUT=str(root/'output'), TAG_EXISTS='no')
            cases = [({}, True), ({'TAG_EXISTS': 'yes'}, False),
                     ({'GITHUB_REF': 'refs/heads/feature'}, False),
                     ({'TARGET': 'unknown'}, False), ({'BUMP': 'unknown'}, False)]
            for override, success in cases:
                with self.subTest(override=override):
                    (root/'output').unlink(missing_ok=True)
                    result = subprocess.run(['bash', '-c', script], cwd=root, env=base|override,
                                            text=True, capture_output=True, timeout=10)
                    self.assertEqual(result.returncode == 0, success, result.stderr)
                    if success:
                        self.assertIn('tag=cli-v0.0.1', (root/'output').read_text())
                    else:
                        self.assertFalse((root/'output').exists())


if __name__ == '__main__':
    unittest.main(verbosity=2)
