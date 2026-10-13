"""Local-only Linux payload tests: no servers, mounts, or partitioning tools.

Run: python3 -m unittest discover -s tests -p 'test_linux*.py' -v
"""
import os
from pathlib import Path
import pty
import select
import shlex
import subprocess
import tempfile
import time
import unittest

ROOT = Path(__file__).resolve().parents[1]
COMMON = ROOT / "linux/common.sh"
HASH = "$6$fixture$" + "A" * 86  # Syntax fixture, not a usable production secret.
GUID = "11111111-2222-4333-8444-555555555555"


def config_values(**overrides):
    values = dict(MODE="test", IP_ADDRESS="192.0.2.20", PREFIX_LENGTH="24",
                  NETMASK="255.255.255.0", GATEWAY="192.0.2.1",
                  DNS_SERVERS="192.0.2.53 198.51.100.53", NIC_MAC="02:00:00:00:00:20",
                  HOSTNAME="debian-test", TIME_ZONE="Etc/UTC", SSH_PORT="2222",
                  ROOT_PASSWORD_HASH=HASH, EXPECTED_ESP_PARTUUID=GUID,
                  EXPECTED_DISK_BYTES="33285996544", FALLBACK_SECONDS="600")
    values.update(overrides)
    return values


def write_config(path, **overrides):
    values = config_values(**overrides)
    path.write_text("".join(f"{k}='{v}'\n" for k, v in values.items()))
    path.chmod(0o600)
    return values


class RuntimeTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix="w2d-unit-")
        self.addCleanup(self.tmp.cleanup)
        self.base = Path(self.tmp.name)
        self.run = self.base / "run"
        self.run.mkdir()
        self.config = self.base / "config.sh"
        write_config(self.config)
        self.bin = self.base / "bin"
        self.bin.mkdir()

    def shell(self, code, *, check=True, env=None):
        prefix = (f". {shlex.quote(str(COMMON))}\n"
                  f"W2D_RUN={shlex.quote(str(self.run))}\n"
                  f"W2D_PAYLOAD={shlex.quote(str(ROOT / 'linux'))}\n"
                  f"PATH={shlex.quote(str(self.bin))}:$PATH\n")
        result = subprocess.run(["/bin/sh", "-c", prefix + code], text=True,
                                capture_output=True, env=env)
        if check:
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        # No test operation should emit a crypt value, even on failure.
        self.assertNotIn(HASH, result.stdout + result.stderr)
        return result

    def mock(self, name, body):
        p = self.bin / name
        p.write_text("#!/bin/sh\n" + body + "\n")
        p.chmod(0o755)
        return p

    def load(self):
        return "w2d_load_config " + shlex.quote(str(self.config)) + " || exit $?\n"

    def state(self, value="trial", deadline=200):
        (self.run / "w2d-state").write_text(value + "\n")
        (self.run / "w2d-deadline").write_text(str(deadline) + "\n")

    def test_syntax(self):
        for script in (ROOT / "linux").glob("*.sh"):
            subprocess.run(["/bin/sh", "-n", str(script)], check=True)

    @unittest.skipUnless(os.geteuid() == 0, "config ownership is intentionally uid 0")
    def test_valid_config_and_no_code_execution(self):
        self.shell(self.load() + '[ "$MODE" = test ] && [ "$SSH_PORT" = 2222 ]')
        marker = self.base / "injected"
        write_config(self.config, HOSTNAME="$(touch " + str(marker) + ")")
        self.assertNotEqual(self.shell(self.load(), check=False).returncode, 0)
        self.assertFalse(marker.exists())

    @unittest.skipUnless(os.geteuid() == 0, "config ownership check")
    def test_config_rejections(self):
        bad = [("MODE", "yes"), ("IP_ADDRESS", "192.0.2.0"),
               ("IP_ADDRESS", "192.0.2.255"), ("IP_ADDRESS", "192.00.2.20"),
               ("GATEWAY", "198.51.100.1"), ("GATEWAY", "192.0.2.20"),
               ("NETMASK", "255.255.0.0"), ("PREFIX_LENGTH", "31"),
               ("PREFIX_LENGTH", "32"), ("DNS_SERVERS", "192.0.2.53; reboot"),
               ("NIC_MAC", "01:00:00:00:00:01"), ("NIC_MAC", "02:AA:00:00:00:01"),
               ("HOSTNAME", "-bad"), ("TIME_ZONE", "../../etc/shadow"),
               ("TIME_ZONE", "Unknown/NoSuchZone"),
               ("ROOT_PASSWORD_HASH", "$6$invalid"), ("EXPECTED_ESP_PARTUUID", "sda1"),
               ("EXPECTED_DISK_BYTES", "33285996545"), ("SSH_PORT", "65536"),
               ("SSH_PORT", "022"), ("FALLBACK_SECONDS", "0")]
        for key, value in bad:
            with self.subTest(key=key, value=value if "HASH" not in key else "invalid"):
                write_config(self.config, **{key: value})
                self.assertNotEqual(self.shell(self.load(), check=False).returncode, 0)
        write_config(self.config)
        self.config.write_text(self.config.read_text() + "MODE='auto'\n")
        self.assertNotEqual(self.shell(self.load(), check=False).returncode, 0)
        write_config(self.config)
        self.config.chmod(0o644)
        self.assertNotEqual(self.shell(self.load(), check=False).returncode, 0)

    def disk_fixture(self, disk="nvme0n1", partition="nvme0n1p1", sectors="65011712"):
        sys = self.base / "sys"
        devices = sys / "devices" / "pci" / "block" / disk
        part = devices / partition
        part.mkdir(parents=True)
        (part / "partition").write_text("1\n")
        (devices / "size").write_text(sectors + "\n")
        (devices / "ro").write_text("0\n")
        (devices / "holders").mkdir()
        cls = sys / "class/block"
        cls.mkdir(parents=True)
        (cls / disk).symlink_to(devices)
        (cls / partition).symlink_to(part)
        dev = self.base / "dev"
        dev.mkdir()
        (dev / disk).touch()
        (dev / partition).touch()
        self.mock("blkid", rf'''case "$*" in
*-s\ PARTUUID*) echo {GUID};;
*-s\ PTTYPE*) echo gpt;;
*-s\ PART_ENTRY_TYPE*) echo c12a7328-f81f-11d2-ba4b-00a0c93ec93b;;
*-s\ TYPE*) echo vfat;;
*) exit 1;; esac''')
        return (self.load() + f"W2D_SYS={shlex.quote(str(sys))}\nW2D_DEV={shlex.quote(str(dev))}\n"
                'w2d_is_block() { [ -f "$1" ]; }\n')

    @unittest.skipUnless(os.geteuid() == 0, "config ownership check")
    def test_disk_exact_identity_and_nvme_parent(self):
        code = self.disk_fixture()
        self.shell(code + 'w2d_identify_disk || exit 1\n[ "${DISK_DEVICE##*/}" = nvme0n1 ]')
        (self.base / "sys/devices/pci/block/nvme0n1/size").write_text("65011711\n")
        self.assertNotEqual(self.shell(code + 'w2d_identify_disk', check=False).returncode, 0)

    @unittest.skipUnless(os.geteuid() == 0, "config ownership check")
    def test_disk_duplicate_esp_refused(self):
        code = self.disk_fixture("sda", "sda1")
        original = self.base / "sys/devices/pci/block/sda/sda1"
        other = self.base / "sys/devices/pci/block/sda/sda2"
        other.mkdir()
        (other / "partition").write_text("2\n")
        (self.base / "sys/class/block/sda2").symlink_to(other)
        (self.base / "dev/sda2").touch()
        self.assertNotEqual(self.shell(code + 'w2d_identify_disk', check=False).returncode, 0)

    @unittest.skipUnless(os.geteuid() == 0, "config ownership check")
    def test_disk_missing_guid_wrong_type_and_readonly_refused(self):
        code = self.disk_fixture("sda", "sda1")
        self.mock("blkid", "exit 1")
        self.assertNotEqual(self.shell(code + 'w2d_identify_disk', check=False).returncode, 0)
        self.mock("blkid", f'''case "$*" in *PARTUUID*) echo {GUID};; *) echo ntfs;; esac''')
        self.assertNotEqual(self.shell(code + 'w2d_identify_disk', check=False).returncode, 0)
        (self.base / "sys/devices/pci/block/sda/ro").write_text("1\n")
        self.assertNotEqual(self.shell(code + 'w2d_identify_disk', check=False).returncode, 0)

    @unittest.skipUnless(os.geteuid() == 0, "config ownership check")
    def test_nic_mac_unique_not_first(self):
        net = self.base / "sys/class/net"
        for name, mac in [("eth0", "02:00:00:00:00:11"), ("eth1", "02:00:00:00:00:20")]:
            (net / name).mkdir(parents=True)
            (net / name / "address").write_text(mac + "\n")
        code = self.load() + f'W2D_SYS={shlex.quote(str(self.base / "sys"))}\n'
        self.shell(code + 'w2d_find_nic || exit 1\n[ "$IFACE" = eth1 ]')
        (net / "eth0/address").write_text("02:00:00:00:00:20\n")
        self.assertNotEqual(self.shell(code + 'w2d_find_nic', check=False).returncode, 0)

    def test_watchdog_expires_and_terminal_reboot_state(self):
        self.state(deadline=100)
        self.shell('w2d_now() { echo 100; }; w2d_reboot() { echo reboot > "$W2D_RUN/request"; }; '
                   'w2d_watchdog_tick; [ "$(w2d_state)" = rebooting ]')
        self.assertTrue((self.run / "request").exists())
        self.assertNotEqual(self.shell('w2d_now() { echo 99; }; w2d_publish_authorization', check=False).returncode, 0)

    def test_authorize_disables_watchdog_atomically(self):
        self.state()
        self.shell('w2d_now() { echo 199; }; w2d_publish_authorization || exit 1; '
                   'w2d_now() { echo 999; }; w2d_reboot() { echo reboot > "$W2D_RUN/request"; }; '
                   'w2d_watchdog_tick; w2d_is_authorized')
        self.assertFalse((self.run / "request").exists())

    def test_hold_separate_from_authorization_and_deadline(self):
        self.state()
        self.shell('w2d_now() { echo 100; }; w2d_hold || exit 1; '
                   '! w2d_is_authorized || exit 1; w2d_now() { echo 999; }; '
                   'w2d_deadline_valid || exit 1; w2d_publish_authorization')
        self.state(deadline=100)
        self.assertNotEqual(self.shell('w2d_now() { echo 100; }; w2d_hold', check=False).returncode, 0)

    def test_watchdog_lock_serializes_reboot_and_authorize(self):
        self.state(deadline=100)
        prefix = (f'. {shlex.quote(str(COMMON))}; W2D_RUN={shlex.quote(str(self.run))}; '
                  'w2d_now() { echo 100; }; ')
        watchdog = subprocess.Popen(["/bin/sh", "-c", prefix +
            'w2d_reboot() { touch "$W2D_RUN/reboot-entered"; sleep 1; }; w2d_watchdog_tick'],
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        self.addCleanup(lambda: watchdog.poll() is None and watchdog.kill())
        for _ in range(100):
            if (self.run / "reboot-entered").exists():
                break
            time.sleep(0.02)
        self.assertTrue((self.run / "reboot-entered").exists())
        result = self.shell('w2d_now() { echo 99; }; w2d_publish_authorization', check=False)
        self.assertNotEqual(result.returncode, 0)
        watchdog.wait(timeout=5)
        self.assertEqual((self.run / "w2d-state").read_text().strip(), "rebooting")

    def test_manual_confirmation_exact_and_tty_required(self):
        self.assertNotEqual(self.shell('DISK_DEVICE=/dev/sda; EXPECTED_DISK_BYTES=512; EXPECTED_ESP_PARTUUID=x; w2d_confirm_disk', check=False).returncode, 0)
        for answer, expected in [("WIPE /dev/sdb", 1), ("WIPE /dev/sda", 0), ("yes", 1)]:
            with self.subTest(answer=answer):
                master, slave = pty.openpty()
                proc = subprocess.Popen(["/bin/sh", "-c", f'. {shlex.quote(str(COMMON))}; DISK_DEVICE=/dev/sda; EXPECTED_DISK_BYTES=512; EXPECTED_ESP_PARTUUID=x; w2d_confirm_disk'],
                                        stdin=slave, stdout=slave, stderr=slave)
                os.close(slave)
                data = b""
                while b"> " not in data:
                    self.assertTrue(select.select([master], [], [], 5)[0])
                    data += os.read(master, 4096)
                os.write(master, answer.encode() + b"\n")
                self.assertEqual(proc.wait(timeout=5), expected)
                os.close(master)

    def test_network_probe_failure_and_success(self):
        self.mock("wget", "exit 1")
        self.assertNotEqual(self.shell('w2d_network_preflight', check=False).returncode, 0)
        self.mock("wget", '''while [ "$#" -gt 0 ]; do
if [ "$1" = -O ]; then shift; out=$1; fi
shift
done
printf '%s\\n' '-----BEGIN PGP SIGNED MESSAGE-----' > "$out"''')
        result = self.shell('w2d_network_preflight')
        self.assertIn("NOT prove inbound SSH", result.stdout)
        self.assertEqual(list(self.run.glob("w2d-network-probe-*")), [])

    @unittest.skipUnless(os.geteuid() == 0, "config ownership check")
    def test_preseed_has_explicit_disk_hash_and_no_early_reentry(self):
        output = self.base / "preseed.cfg"
        self.shell(self.load() + f'IFACE=eth1; DISK_DEVICE=/dev/nvme0n1; w2d_write_preseed {shlex.quote(str(output))}')
        text = output.read_text()
        self.assertIn('partman-auto/disk string /dev/nvme0n1', text)
        self.assertIn('grub-installer/bootdev string /dev/nvme0n1', text)
        self.assertIn('linux-image-cloud-amd64', text)
        self.assertIn('d-i netcfg/target_network_config select ifupdown\n', text)
        self.assertIn('passwd/root-password-crypted password ' + HASH, text)
        self.assertIn('d-i preseed/early_command string\n', text)
        self.assertEqual(output.stat().st_mode & 0o777, 0o600)

    def target_fixture(self):
        target = self.base / "target"
        for name, content in {
            "etc/debian_version": "13.7\n", "etc/shadow": "root:" + HASH + ":1:0:99999:7:::\n",
            "usr/share/zoneinfo/Etc/UTC": "fixture", "etc/network/interfaces": "old",
            "boot/efi/EFI/debian/shimx64.efi": "fixture", "boot/efi/EFI/debian/grubx64.efi": "fixture",
            "boot/grub/grub.cfg": "linux ... net.ifnames=0\n",
            "boot/vmlinuz-6.12-fixture-cloud-amd64": "fixture",
            "boot/initrd.img-6.12-fixture-cloud-amd64": "fixture",
        }.items():
            path = target / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(content)
        code = self.load() + f'W2D_TARGET={shlex.quote(str(target))}\n' + '''
w2d_in_target() {
    printf '%s\n' "$*" >> "$W2D_RUN/in-target-calls"
    if [ "$*" = '/usr/sbin/sshd -T' ]; then
        printf 'port 2222\npermitrootlogin yes\npasswordauthentication yes\n'
    fi
}
'''
        return target, code

    @unittest.skipUnless(os.geteuid() == 0, "config ownership check")
    def test_late_configuration_idempotent_and_mac_bound(self):
        target, code = self.target_fixture()
        self.shell(code + 'w2d_finish_target || exit 1; w2d_finish_target')
        self.assertIn('MACAddress=02:00:00:00:00:20', (target / 'etc/systemd/network/10-w2d.link').read_text())
        self.assertIn('auto w2d0', (target / 'etc/network/interfaces').read_text())
        self.assertIn('address 192.0.2.20/24', (target / 'etc/network/interfaces').read_text())
        self.assertIn('Port 2222', (target / 'etc/ssh/sshd_config.d/00-w2d.conf').read_text())
        calls = (self.run / 'in-target-calls').read_text()
        for call in ['update-initramfs -u -k all', 'update-grub', 'systemctl enable ssh', '/usr/sbin/sshd -t']:
            self.assertIn(call, calls)

    @unittest.skipUnless(os.geteuid() == 0, "config ownership check")
    def test_late_rejects_missing_boot_files_and_wrong_hash(self):
        target, code = self.target_fixture()
        (target / 'boot/efi/EFI/debian/shimx64.efi').unlink()
        self.assertNotEqual(self.shell(code + 'w2d_finish_target', check=False).returncode, 0)
        (target / 'etc/shadow').write_text('root:!:1:0:99999:7:::\n')
        self.assertNotEqual(self.shell(code + 'w2d_finish_target', check=False).returncode, 0)


if __name__ == '__main__':
    unittest.main()
