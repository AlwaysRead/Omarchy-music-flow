"""Verify shared deployment in a temporary directory without changing the desktop."""
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
FILES = (
    "BarWidget.qml", "Service.qml", "MediaModel.js", "AudioSpectrum.js",
    "manifest.json", "config/visualizer.conf", "local-i18n/en.json", "LICENSE", "CREDITS.md",
)


class DeploymentTests(unittest.TestCase):
    def test_all_runtime_files_and_attribution_are_deployed(self):
        with tempfile.TemporaryDirectory() as target:
            env = {**os.environ, "SCRIPT_DIR": str(ROOT), "TARGET_DIR": target}
            subprocess.run(["bash", "-euo", "pipefail", "-c",
                'source "$SCRIPT_DIR/scripts/install_files.sh"'], env=env, check=True)
            for name in FILES:
                self.assertEqual((ROOT / name).read_bytes(), (Path(target) / name).read_bytes(), name)
            self.assertEqual(len([p for p in Path(target).rglob("*") if p.is_file()]), len(FILES))


if __name__ == "__main__":
    unittest.main()
