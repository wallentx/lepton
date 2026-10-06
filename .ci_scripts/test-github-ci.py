#!/usr/bin/env python3
"""Check migration parity and artifact/rootfs behavior without private services."""
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

import yaml

ROOT = Path(__file__).resolve().parents[1]
WORKFLOW = yaml.safe_load((ROOT / '.github/workflows/ci.yml').read_text())
GITLAB = list(yaml.safe_load_all((ROOT / '.gitlab-ci.yml').read_text()))[1]


class WorkflowTests(unittest.TestCase):
    def test_jobs_and_dependencies(self):
        names = {name for name, value in GITLAB.items()
                 if isinstance(value, dict) and ('script' in value or 'extends' in value)
                 and not name.startswith('.')}
        self.assertEqual(names, set(WORKFLOW['jobs']) - {'pipeline'})
        for name in names:
            job = WORKFLOW['jobs'][name]
            dependencies = GITLAB[name].get('needs', [])
            self.assertEqual(job['needs'], ['pipeline', *dependencies])
            downloaded = [step['with']['name'] for step in job['steps']
                          if step.get('uses') == './.github/actions/download']
            self.assertEqual(downloaded, dependencies)

    def test_shards(self):
        for name in ('tests-job', 'tests-14-job'):
            job = WORKFLOW['jobs'][name]
            matrix = job['strategy']['matrix']['include']
            self.assertEqual([row['shard'] for row in matrix], list(range(1, 14)))
            self.assertFalse(job['strategy']['fail-fast'])
            self.assertTrue(matrix[-1]['runner'].endswith('heavy-privileged'))
            self.assertEqual(job['env']['CI_NODE_INDEX'], '${{ matrix.shard }}')

    def test_archive_round_trip(self):
        upload = yaml.safe_load((ROOT / '.github/actions/upload/action.yml').read_text())
        download = yaml.safe_load((ROOT / '.github/actions/download/action.yml').read_text())
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            file = root / 'install/test.sh'
            file.parent.mkdir()
            file.write_text('#!/bin/sh\nexit 0\n')
            file.chmod(0o751)
            env = {**os.environ, 'ARTIFACT_PATHS': 'install/test.sh\nmissing.log'}
            subprocess.run(['bash', '-euo', 'pipefail', '-c', upload['runs']['steps'][0]['run']],
                           cwd=root, env=env, check=True)
            file.unlink()
            subprocess.run(['bash', '-euo', 'pipefail', '-c', download['runs']['steps'][1]['run']],
                           cwd=root, check=True)
            self.assertEqual(file.read_text(), '#!/bin/sh\nexit 0\n')
            self.assertEqual(file.stat().st_mode & 0o777, 0o751)


class RootfsTests(unittest.TestCase):
    def run_rootfs(self, version, branch='feature', changed=False, fail=False):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            (root / 'bin').mkdir()
            (root / '.ci_scripts').mkdir()
            (root / 'image').mkdir()
            scripts = {
                'apt-get': '#!/bin/bash\nexit 0\n',
                'git': '#!/bin/bash\nif [[ "$1" == tag ]]; then echo v1.0.0; else\n'
                       '  [[ "$*" == *".ci_scripts/build-rootfs.sh"* ]] || exit 2\n'
                       f'  exit {1 if changed else 0}\nfi\n',
                'curl': '#!/bin/bash\ntouch reused\n',
                'unzip': '#!/bin/bash\ntouch build-rootfs-artifacts.zip image/{system.img,vendor.img,NOTICE.txt,version.txt} symbols.tar.zst\n',
            }
            for name, content in scripts.items():
                path = root / 'bin' / name
                path.write_text(content)
                path.chmod(0o755)
            for name, content in {
                'install-build-rootfs-dependencies.sh': '#!/bin/bash\nexit 0\n',
                'build-rootfs.sh': '#!/bin/bash\ntouch built\n' + ('exit 7\n' if fail else
                    'touch image/{system.img,vendor.img,NOTICE.txt,version.txt} symbols.tar.zst\n'),
                'resolve-rootfs-version.py': 'print(123)\n',
            }.items():
                path = root / '.ci_scripts' / name
                path.write_text(content)
                path.chmod(0o755)
            env = {**os.environ, 'PATH': f'{root / "bin"}:{os.environ["PATH"]}',
                   'ROOTFS_VERSION_VAR': 'ROOTFS_VERSION', 'ROOTFS_VERSION': version,
                   'IMAGE_DIR': 'image', 'BUILD_SCRIPT': 'build-rootfs.sh',
                   'DEPENDENCIES_SCRIPT': 'install-build-rootfs-dependencies.sh',
                   'JOB_NAME': 'build-rootfs-job', 'SYMBOLS': 'symbols.tar.zst',
                   'CI_COMMIT_BRANCH': branch, 'CI_COMMIT_TAG': '', 'CI_COMMIT_SHA': 'test',
                   'CI_PIPELINE_SOURCE': 'push', 'CI_API_V4_URL': 'https://example.invalid',
                   'CI_LEPTON_TOKEN': 'fixture'}
            result = subprocess.run(['bash', str(ROOT / '.ci_scripts/github-build-rootfs.sh')],
                                    cwd=root, env=env, capture_output=True, text=True)
            return result.returncode, (root / 'built').exists(), (root / 'reused').exists()

    def test_empty_input_builds(self):
        self.assertEqual(self.run_rootfs(''), (0, True, False))

    def test_latest_reuses(self):
        self.assertEqual(self.run_rootfs('latest'), (0, False, True))

    def test_unchanged_main_reuses(self):
        self.assertEqual(self.run_rootfs('latest', branch='main'), (0, False, True))

    def test_changed_main_builds(self):
        self.assertEqual(self.run_rootfs('latest', branch='main', changed=True), (0, True, False))

    def test_failed_build_stops(self):
        self.assertEqual(self.run_rootfs('', fail=True), (7, True, False))


if __name__ == '__main__':
    unittest.main()
