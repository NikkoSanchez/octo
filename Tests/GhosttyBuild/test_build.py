import importlib.util
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location("ghostty_build", ROOT / "Scripts/ghostty/build.py")
build = importlib.util.module_from_spec(spec)
spec.loader.exec_module(build)


class OutputVerificationTests(unittest.TestCase):
    def test_modified_missing_or_extra_outputs_fail(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            output = root / "header.h"
            output.write_text("original")
            expected = build.inventory(root)
            build.verify_tree(root, expected)
            output.write_text("changed")
            with self.assertRaises(RuntimeError):
                build.verify_tree(root, expected)
            output.unlink()
            with self.assertRaises(RuntimeError):
                build.verify_tree(root, expected)
            output.write_text("original")
            (root / "extra").write_text("unexpected")
            with self.assertRaises(RuntimeError):
                build.verify_tree(root, expected)

    def test_lock_recipe_revision_and_architecture_invalidate_manifest(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            lock = root / "lock.json"
            lock.write_text('{"source":{"revision":"abc"}}')
            framework = root / "framework"
            resources = root / "resources"
            for output in [framework, resources]:
                output.mkdir()
                (output / "file").write_text("built")
            manifest = root / "manifest.json"
            valid = dict(lockSHA256=build.digest(lock), scriptSHA256=build.digest(build.__file__),
                         sourceRevision="abc", target="native", frameworkFiles=build.inventory(framework),
                         resourceFiles=build.inventory(resources))
            with patch.multiple(build, LOCK=lock, MANIFEST=manifest, FRAMEWORK=framework, RESOURCES=resources):
                manifest.write_text(json.dumps(valid))
                build.verify_manifest(json.loads(lock.read_text()), "native")
                for key, value in [("lockSHA256", "wrong"), ("scriptSHA256", "wrong"), ("sourceRevision", "def"), ("target", "universal")]:
                    manifest.write_text(json.dumps(dict(valid, **{key: value})))
                    with self.subTest(key=key), self.assertRaises(RuntimeError):
                        build.verify_manifest(json.loads(lock.read_text()), "native")


if __name__ == "__main__":
    unittest.main()
