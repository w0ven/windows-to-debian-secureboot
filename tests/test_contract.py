"""Cross-language producer/consumer test. All addresses and credentials are synthetic."""
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
PWSH = os.environ.get("W2D_TEST_PWSH") or shutil.which("pwsh")


@unittest.skipUnless(PWSH and hasattr(os, "geteuid") and os.geteuid() == 0, "Linux root and pwsh required for root-owned config contract check")
class PayloadContract(unittest.TestCase):
    def test_actual_windows_assignment_cpio_and_linux_config_parser(self):
        with tempfile.TemporaryDirectory(prefix="w2d-contract-") as directory:
            work = Path(directory)
            archive = work / "overlay.cpio"
            subprocess.run([PWSH, "-NoProfile", "-File", str(ROOT / "tests/make_contract_fixture.ps1"), "-Destination", str(archive)], check=True, capture_output=True, text=True)
            data = archive.read_bytes()
            offset = 0
            config = None
            while offset + 110 <= len(data):
                self.assertEqual(data[offset:offset + 6], b"070701")
                fields = [int(data[offset + 6 + i * 8:offset + 14 + i * 8], 16) for i in range(13)]
                name = data[offset + 110:offset + 110 + fields[11] - 1].decode()
                start = (offset + 110 + fields[11] + 3) & ~3
                if name == "w2d/config.sh":
                    self.assertEqual(fields[1], 0o100600)
                    self.assertEqual(fields[2:4], [0, 0])
                    config = work / "config.sh"
                    config.write_bytes(data[start:start + fields[6]])
                    config.chmod(0o600)
                offset = (start + fields[6] + 3) & ~3
                if name == "TRAILER!!!":
                    break
            self.assertIsNotNone(config)
            result = subprocess.run(["/bin/sh", "-c", '. "$1/common.sh"; W2D_PAYLOAD=$1; w2d_load_config "$2" || exit; test "$MODE" = test && test "$SSH_PORT" = 2222 && test "$IP_ADDRESS" = 192.0.2.100 && test "$EXPECTED_DISK_BYTES" = 34359738368 && printf "CONTRACT_OK\\n"', "sh", str(ROOT / "linux"), str(config)], capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(result.stdout.strip(), "CONTRACT_OK")


if __name__ == "__main__":
    unittest.main()
