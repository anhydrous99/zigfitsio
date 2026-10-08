"""Compiler probing falls back only before compilation."""
import subprocess
import unittest
from pathlib import Path
from unittest.mock import patch

from hatch_build import ZigSharedLibraryHook


class CompilerSelectionTest(unittest.TestCase):
    def test_candidates(self):
        bundled = ['python', '-m', 'ziglang']
        hook = object.__new__(ZigSharedLibraryHook)
        cases = [
            ('0.17.0', '0.17.1', bundled),
            ('0.16.0', '0.17.0', ['zig']),
            ('0.18.0', '0.17.0', ['zig']),
            ('0.17.0-dev.1', '0.17.0', ['zig']),
            (None, '0.17.0', ['zig']),
            (subprocess.CalledProcessError(1, bundled), '0.17.0', ['zig']),
            ('0.16.0', FileNotFoundError(), None),
            (None, '0.16.0', None),
        ]
        for package_version, path_version, selected in cases:
            with self.subTest(package=package_version, path=path_version):
                def run(command, **kwargs):
                    if command[-1] == 'version':
                        version = package_version if command[:3] == bundled else path_version
                        if isinstance(version, Exception):
                            raise version
                        return subprocess.CompletedProcess(command, 0, stdout=version + '\n')
                    return subprocess.CompletedProcess(command, 0)

                with patch('hatch_build.sys.executable', 'python'), \
                     patch('hatch_build.importlib.util.find_spec', return_value=object() if package_version is not None else None), \
                     patch('hatch_build.subprocess.run', side_effect=run) as calls:
                    if selected is None:
                        with self.assertRaisesRegex(RuntimeError, 'stable Zig 0.17.x'):
                            hook._build(Path('/tmp'))
                    else:
                        hook._build(Path('/tmp'))
                        self.assertEqual(calls.call_args.args[0][:len(selected)], selected)
                        self.assertIn('-Doptimize=fast', calls.call_args.args[0])

        for installed in (True, False):
            with self.subTest(compile_failure=installed), \
                 patch('hatch_build.importlib.util.find_spec', return_value=object() if installed else None), \
                 patch('hatch_build.subprocess.run', side_effect=[
                     subprocess.CompletedProcess([], 0, stdout='0.17.0\n'),
                     subprocess.CalledProcessError(1, ['zig', 'build']),
                 ]) as calls:
                with self.assertRaises(subprocess.CalledProcessError):
                    hook._build(Path('/tmp'))
                self.assertEqual(calls.call_count, 2)
