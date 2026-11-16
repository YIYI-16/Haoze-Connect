import tempfile
import unittest
from pathlib import Path
import zipfile

from haoze_rust_bridge import check


class RustLoaderContractTest(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.plugin = self.root / 'plugins/rust_api'
        (self.plugin / 'rust').mkdir(parents=True)
        (self.plugin / 'lib/src/rust').mkdir(parents=True)
        (self.plugin / 'rust/Cargo.toml').write_text('[lib]\nname = "rust_api"\n')
        self.generated = self.plugin / 'lib/src/rust/frb_generated.dart'
        self.generated.write_text("ExternalLibraryLoaderConfig(\n  stem: 'rust_api',\n)")

    def apk(self, abis):
        path = self.root / 'app.apk'
        with zipfile.ZipFile(path, 'w') as archive:
            for abi, include_rust in abis.items():
                archive.writestr(f'lib/{abi}/libapp.so', b'app')
                if include_rust:
                    archive.writestr(f'lib/{abi}/librust_api.so', b'rust')
        return path

    def test_rejects_unknown_stem_even_when_correct_library_is_packaged(self):
        apk = self.apk({'arm64-v8a': True})
        self.generated.write_text("ExternalLibraryLoaderConfig(stem: 'UNKNOWN',)")
        with self.assertRaises(ValueError):
            check(self.root, apk)

    def test_requires_a_matching_library_for_every_packaged_abi(self):
        with self.assertRaises(ValueError):
            check(self.root, self.apk({'arm64-v8a': True, 'x86_64': False}))
        self.assertEqual(check(self.root, self.apk({'arm64-v8a': True, 'x86_64': True})), 'rust_api')

    def test_rejects_another_library_name(self):
        self.generated.write_text("ExternalLibraryLoaderConfig(stem: 'other',)")
        with self.assertRaises(ValueError):
            check(self.root)


if __name__ == '__main__':
    unittest.main()
