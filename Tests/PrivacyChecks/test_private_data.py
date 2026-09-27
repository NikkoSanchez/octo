import importlib.util
import json
import pathlib
import unittest

spec = importlib.util.spec_from_file_location('privacy', pathlib.Path(__file__).parents[2] / 'Scripts/check-private-data.py')
privacy = importlib.util.module_from_spec(spec)
spec.loader.exec_module(privacy)

class PrivacyTests(unittest.TestCase):
    def test_archive_is_detected_even_when_renamed(self):
        data = json.dumps(dict(schemaVersion=1, projects=[])).encode()
        self.assertTrue(privacy.findings('innocent.data', data))
    def test_credentials_and_local_data_are_blocked(self):
        self.assertTrue(privacy.findings('config.txt', b'ghp_' + b'a' * 36))
        self.assertTrue(privacy.findings('.env.production', b'anything'))
        self.assertTrue(privacy.findings('build/output.txt', b'anything'))
    def test_source_and_lockfiles_are_allowed(self):
        self.assertFalse(privacy.findings('Package.resolved', b'{"pins":[]}'))
        self.assertFalse(privacy.findings('Models.swift', b'var remoteSessionID: String?'))

if __name__ == '__main__':
    unittest.main()

class HookIntegrationTests(unittest.TestCase):
    def test_pre_push_catches_archive_deleted_in_later_commit(self):
        import subprocess
        import tempfile
        script = pathlib.Path(privacy.__file__).resolve()
        with tempfile.TemporaryDirectory() as directory:
            def git(*args):
                return subprocess.check_output(['git', *args], cwd=directory, stderr=subprocess.DEVNULL).decode().strip()
            git('init', '-b', 'main')
            git('config', 'user.name', 'Fixture')
            git('config', 'user.email', 'fixture@example.invalid')
            git('config', 'commit.gpgsign', 'false')
            archive = pathlib.Path(directory) / 'renamed.data'
            archive.write_text(json.dumps(dict(schemaVersion=1, projects=[])))
            git('add', '.')
            git('commit', '-m', 'fixture')
            git('rm', 'renamed.data')
            git('commit', '-m', 'delete')
            head = git('rev-parse', 'HEAD')
            result = subprocess.run(['python3', str(script), '--pre-push'], cwd=directory,
                input=f'refs/heads/main {head} refs/heads/main {"0" * 40}\n', text=True, capture_output=True)
            self.assertEqual(result.returncode, 1)
            self.assertIn('Octo conversation archive', result.stderr)
