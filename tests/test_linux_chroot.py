"""Optional pinned-initrd tests in a new chroot, with no host mounts/block devices.

Set W2D_TEST_INITRD and W2D_TEST_SSH_UDEB; run as root. SSH authentication
uses sshd -i over an AF_UNIX socketpair: no TCP listener or remote connection.
Requires existing ar/openssl and, for the SSH check, paramiko. Installs nothing.
"""
import gzip
import hashlib
import io
import os
from pathlib import Path
import secrets
import shutil
import socket
import stat
import subprocess
import tarfile
import tempfile
import time
import unittest

ROOT = Path(__file__).resolve().parents[1]
INITRD_SHA256 = "57303d157cffce3fa402301667fbc9b2280aa7372082b081e777375ae49da5f2"
SSH_UDEB_SHA256 = "46edeeee6167758a4b69d5e6990daee8cb8590698d55f0fa40b79ebb0b813aef"
GUID = "11111111-2222-4333-8444-555555555555"


def unpack_initrd(image, root):
    data = gzip.decompress(image.read_bytes())
    pos, entries = 0, []
    while pos + 110 <= len(data):
        if data[pos:pos + 6] not in (b"070701", b"070702"):
            raise ValueError("not a newc archive")
        h = [int(data[pos + 6 + i * 8:pos + 14 + i * 8], 16) for i in range(13)]
        name = data[pos + 110:pos + 110 + h[11] - 1].decode()
        start = (pos + 110 + h[11] + 3) & ~3
        content = data[start:start + h[6]]
        pos = (start + h[6] + 3) & ~3
        if name == "TRAILER!!!":
            break
        if Path(name).is_absolute() or ".." in Path(name).parts:
            raise ValueError("unsafe cpio path")
        entries.append((name, h, content))
    links, hard = [], {}
    for name, h, content in entries:
        p, mode = root / name, h[1]
        if stat.S_ISDIR(mode):
            p.mkdir(parents=True, exist_ok=True)
        elif stat.S_ISREG(mode):
            p.parent.mkdir(parents=True, exist_ok=True)
            if h[4] > 1:
                hard.setdefault((h[0], h[7], h[8]), []).append((p, mode, content))
            else:
                p.write_bytes(content)
                p.chmod(mode & 0o777)
        elif stat.S_ISLNK(mode):
            links.append((p, content.decode()))
        # Deliberately do not create archive device nodes.
    for group in hard.values():
        content = next((d for _, _, d in group if d), b"")
        first = group[0][0]
        first.write_bytes(content)
        first.chmod(group[0][1] & 0o777)
        for p, _, _ in group[1:]:
            os.link(first, p)
    for p, target in links:
        p.parent.mkdir(parents=True, exist_ok=True)
        p.symlink_to(target)


def unpack_udeb(package, root):
    names = subprocess.check_output(["ar", "t", str(package)], text=True).splitlines()
    name = next(n for n in names if n.startswith("data.tar"))
    payload = subprocess.check_output(["ar", "p", str(package), name])
    with tarfile.open(fileobj=io.BytesIO(payload), mode="r:*") as archive:
        for member in archive:
            name = member.name.removeprefix("./")
            if not name or name == ".":
                continue
            if Path(name).is_absolute() or ".." in Path(name).parts:
                raise ValueError("unsafe udeb path")
            p = root / name
            if not p.parent.resolve().is_relative_to(root.resolve()):
                raise ValueError("udeb path escapes fixture")
            if member.isdir():
                p.mkdir(parents=True, exist_ok=True)
            elif member.isfile():
                p.parent.mkdir(parents=True, exist_ok=True)
                if p.is_symlink():
                    p.unlink()
                p.write_bytes(archive.extractfile(member).read())
                p.chmod(member.mode & 0o777)


@unittest.skipUnless(os.geteuid() == 0 and os.environ.get("W2D_TEST_INITRD") and os.environ.get("W2D_TEST_SSH_UDEB"),
                     "optional: supply pinned initrd/SSH udeb paths and run as root")
class ChrootTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temp = tempfile.TemporaryDirectory(prefix="w2d-chroot-")
        cls.root = Path(cls.temp.name)
        initrd = Path(os.environ["W2D_TEST_INITRD"])
        udeb = Path(os.environ["W2D_TEST_SSH_UDEB"])
        for file, digest in [(initrd, INITRD_SHA256), (udeb, SSH_UDEB_SHA256)]:
            if hashlib.sha256(file.read_bytes()).hexdigest() != digest:
                raise ValueError("test input is not the pinned verified material")
        unpack_initrd(initrd, cls.root)
        unpack_udeb(udeb, cls.root)
        for d in ["dev", "run", "proc", "sys", "w2d", "var/log"]:
            (cls.root / d).mkdir(exist_ok=True, parents=True)
        for name, minor in [("null", 3), ("zero", 5), ("random", 8), ("urandom", 9)]:
            p = cls.root / "dev" / name
            if p.exists() or p.is_symlink():
                p.unlink()
            os.mknod(p, stat.S_IFCHR | 0o666, os.makedev(1, minor))
        for script in (ROOT / "linux").glob("*.sh"):
            shutil.copy2(script, cls.root / "w2d" / script.name)
        cls.password = secrets.token_urlsafe(24)
        cls.crypted = subprocess.run(["openssl", "passwd", "-6", "-stdin"],
                                     input=cls.password + "\n", text=True, check=True,
                                     capture_output=True).stdout.strip()
        cls.config()
        cls.call(". /w2d/common.sh; w2d_load_config && w2d_setup_accounts")
        # Match d-i S20 initialization before exercising real preseed tools.
        cls.call("debconf-loadtemplate d-i /var/lib/dpkg/info/*.templates")
        cls.call('for c in depmod modprobe udpkg blkid; do command -v "$c" || exit 1; done')
        # Even accidental future calls cannot reboot or reconfigure the host.
        for command in ["reboot", "halt", "poweroff", "modprobe", "depmod", "ip"]:
            cls.stub(command, 'printf "%s\\n" stub >> /run/stub-commands\nexit 0')

    @classmethod
    def tearDownClass(cls):
        cls.password = cls.crypted = None
        cls.temp.cleanup()

    @classmethod
    def config(cls, mode="test"):
        values = dict(MODE=mode, IP_ADDRESS="192.0.2.20", PREFIX_LENGTH="24",
                      NETMASK="255.255.255.0", GATEWAY="192.0.2.1",
                      DNS_SERVERS="192.0.2.53", NIC_MAC="02:00:00:00:00:20",
                      HOSTNAME="debian-test", TIME_ZONE="Etc/UTC", SSH_PORT="2222",
                      ROOT_PASSWORD_HASH=cls.crypted, EXPECTED_ESP_PARTUUID=GUID,
                      EXPECTED_DISK_BYTES="33285996544", FALLBACK_SECONDS="600")
        p = cls.root / "w2d/config.sh"
        p.write_text("".join(f"{k}='{v}'\n" for k, v in values.items()))
        p.chmod(0o600)

    @classmethod
    def call(cls, command, *, check=True, env=None):
        result = subprocess.run(["chroot", str(cls.root), "/bin/sh", "-c", command],
                                capture_output=True, text=True, env=env, timeout=20)
        if cls.crypted in result.stdout + result.stderr:
            raise AssertionError("runtime leaked a credential hash")
        if check and result.returncode:
            raise AssertionError(result.stdout + result.stderr)
        return result

    @classmethod
    def stub(cls, name, body):
        for directory in ["usr/sbin", "usr/bin"]:
            p = cls.root / directory / name
            if p.exists() or p.is_symlink():
                p.unlink()
        p = cls.root / "usr/bin" / name
        p.write_text("#!/bin/sh\n" + body + "\n")
        p.chmod(0o755)

    def setUp(self):
        self.config()
        shutil.copy2(ROOT / 'linux/common.sh', self.root / 'w2d/common.sh')
        for name in ['install-preseed.cfg', 'install-preseed.cfg.tmp']:
            (self.root / 'w2d' / name).unlink(missing_ok=True)
        for name in ['class', 'devices']:
            path = self.root / 'sys' / name
            if path.exists():
                shutil.rmtree(path)
        for p in (self.root / "run").glob("w2d-*"):
            if p.is_dir():
                shutil.rmtree(p)
            else:
                p.unlink()
        (self.root / "run/w2d-state").write_text("trial\n")
        (self.root / "run/w2d-deadline").write_text("999999999\n")
        (self.root / "proc/uptime").write_text("100.00 100.00\n")

    def test_actual_busybox_tools_and_sshd_config(self):
        self.call("for c in awk grep ls readlink mkdir mv sleep cut depmod modprobe; do command -v $c || exit 1; done; /usr/sbin/sshd -t -f /w2d/sshd_config")
        self.assertTrue((self.root / "etc/ssh/ssh_host_ed25519_key").exists())
        self.assertIn("installer:x:0:0:installer:/:/bin/sh", (self.root / "etc/passwd").read_text())

    def test_real_in_target_preserves_effective_sshd_stdout(self):
        # Exercise the exact pinned in-target and log-output, not a stdout stub.
        self.assertEqual(hashlib.sha256((self.root / 'usr/bin/in-target').read_bytes()).hexdigest(),
                         '1f48fddbcebfae9fe2d2a30e053f7fb3861b32ee0a3f60e99b4815b8b0e960da')
        self.assertEqual(hashlib.sha256((self.root / 'usr/bin/log-output').read_bytes()).hexdigest(),
                         'b80dae1e3de1ca402caa7efa109c6da2385f164aeda3c8b561bcab53debbcaa9')
        setup = self.root / 'usr/lib/chroot-setup.sh'
        original_setup = setup.read_bytes()
        target = self.root / 'target'
        target_existed = target.is_dir()
        if target_existed:
            target.rmdir()  # Fail if not empty; never remove a populated target.
        # Inside the outer chroot, /target -> / is still the isolated fixture.
        target.symlink_to('/')
        setup.write_text('chroot_setup() { return 0; }\nchroot_cleanup() { return 0; }\n')
        try:
            # Only mount preparation is bypassed. The nested chroot and sshd
            # are real, as is log-output's default stdout-to-syslog behavior.
            default = self.call('in-target /usr/sbin/sshd -T -f /w2d/sshd_config')
            self.assertEqual(default.stdout, '')
            direct = self.call('in-target --pass-stdout /usr/sbin/sshd -T -f /w2d/sshd_config')
            self.assertIn('port 2222\n', direct.stdout)
            captured = self.call('. /w2d/common.sh; effective=$(w2d_in_target /usr/sbin/sshd -T -f /w2d/sshd_config); printf "%s\\n" "$effective"')
            self.assertIn('port 2222\n', captured.stdout)
            self.assertIn('permitrootlogin yes\n', captured.stdout)
            self.assertIn('passwordauthentication yes\n', captured.stdout)
            failed = self.call(". /w2d/common.sh; w2d_in_target /bin/sh -c 'exit 23'", check=False)
            self.assertEqual(failed.returncode, 23)
        finally:
            setup.write_bytes(original_setup)
            target.unlink()
            if target_existed:
                target.mkdir()

    def test_real_sshd_password_auth_installer_and_root(self):
        try:
            import paramiko
        except ImportError:
            self.skipTest("optional SSH authentication check needs existing paramiko")
        for username in ["installer", "root"]:
            with self.subTest(username=username):
                client, server = socket.socketpair()
                stderr = tempfile.TemporaryFile()
                proc = subprocess.Popen(["chroot", str(self.root), "/usr/sbin/sshd", "-i", "-e", "-f", "/w2d/sshd_config"],
                                        stdin=server, stdout=server, stderr=stderr, close_fds=True)
                server.close()
                transport = paramiko.Transport(client)
                try:
                    transport.start_client(timeout=10)
                    transport.auth_password(username, self.password)
                    self.assertTrue(transport.is_authenticated())
                    channel = transport.open_session(timeout=10)
                    channel.exec_command("id -u")
                    self.assertEqual(channel.makefile("rb").read().strip(), b"0")
                    self.assertEqual(channel.recv_exit_status(), 0)
                    channel.close()
                finally:
                    transport.close()
                    client.close()
                    try:
                        proc.wait(timeout=5)
                    except subprocess.TimeoutExpired:
                        proc.kill()
                        proc.wait()
                    stderr.close()

    def test_runtime_gate_and_auto_failure_do_not_release(self):
        self.assertNotEqual(self.call("/w2d/install-debian.sh --auto", check=False).returncode, 0)
        self.assertEqual((self.root / "run/w2d-state").read_text().strip(), "trial")
        self.config("auto")
        for name in ["w2d-startup-ready", "w2d-ssh-ready"]:
            (self.root / "run" / name).touch()
        self.assertNotEqual(self.call("/w2d/install-debian.sh --auto", check=False).returncode, 0)
        self.assertEqual((self.root / "run/w2d-state").read_text().strip(), "trial")
        self.assertFalse((self.root / "run/w2d-install.lock").exists())

    def test_hold_does_not_release_and_cancel_after_authorization_refused(self):
        env = dict(os.environ, SSH_CONNECTION="192.0.2.44 45000 192.0.2.20 2222")
        self.call("/w2d/install-debian.sh --hold", env=env)
        self.assertEqual((self.root / "run/w2d-state").read_text().strip(), "held")
        self.call(". /w2d/common.sh; w2d_publish_authorization")
        self.assertNotEqual(self.call("/w2d/install-debian.sh --cancel", env=env, check=False).returncode, 0)
        self.assertEqual((self.root / "run/w2d-state").read_text().strip(), "authorized")
        self.call("/w2d/install-debian.sh")

    def good_preflight(self):
        # Regular fixture files only; never create a block device, even a dummy one.
        with (self.root / 'w2d/common.sh').open('a') as f:
            f.write('\nw2d_is_block() { [ -f "$1" ]; }\n')
        disk = self.root / 'sys/devices/pci/block/sda'
        (disk / 'sda1').mkdir(parents=True)
        (disk / 'size').write_text('65011712\n')
        (disk / 'ro').write_text('0\n')
        (disk / 'sda1/partition').write_text('1\n')
        (disk / 'holders').mkdir()
        cls = self.root / 'sys/class/block'
        cls.mkdir(parents=True)
        (cls / 'sda').symlink_to('/sys/devices/pci/block/sda')
        (cls / 'sda1').symlink_to('/sys/devices/pci/block/sda/sda1')
        for name in ['sda', 'sda1']:
            (self.root / 'dev' / name).touch()
        nic = self.root / 'sys/class/net/eth1'
        nic.mkdir(parents=True)
        (nic / 'address').write_text('02:00:00:00:00:20\n')
        self.stub('blkid', f'''case "$*" in
*PARTUUID*) echo {GUID};;
*PTTYPE*) echo gpt;;
*PART_ENTRY_TYPE*) echo c12a7328-f81f-11d2-ba4b-00a0c93ec93b;;
*TYPE*) echo vfat;; *) exit 1;; esac''')
        self.stub('wget', '''while [ "$#" -gt 0 ]; do
if [ "$1" = -O ]; then shift; out=$1; fi
shift
done
printf '%s\\n' '-----BEGIN PGP SIGNED MESSAGE-----' > "$out"''')
        for name in ['w2d-startup-ready', 'w2d-ssh-ready']:
            (self.root / 'run' / name).touch()

    def test_successful_auto_preflight_only_releases_once(self):
        self.config('auto')
        self.good_preflight()
        self.call('/w2d/install-debian.sh --auto')
        self.assertEqual((self.root / 'run/w2d-state').read_text().strip(), 'authorized')
        preseed = (self.root / 'w2d/install-preseed.cfg').read_bytes()
        self.assertTrue(b'partman-auto/disk string /dev/sda' in preseed)
        self.call('[ "$(debconf-get netcfg/target_network_config)" = ifupdown ]')
        self.call('/w2d/install-debian.sh --auto')
        self.assertTrue((self.root / 'w2d/install-preseed.cfg').read_bytes() == preseed)
        self.assertFalse((self.root / 'run/w2d-install.lock').exists())

    def test_valid_disk_but_network_failure_stays_closed(self):
        self.config('auto')
        self.good_preflight()
        self.stub('wget', 'exit 1')
        self.assertNotEqual(self.call('/w2d/install-debian.sh --auto', check=False).returncode, 0)
        self.assertEqual((self.root / 'run/w2d-state').read_text().strip(), 'trial')
        self.assertFalse((self.root / 'w2d/install-preseed.cfg').exists())

    def test_startup_unpack_depmod_storage_order_and_idempotency(self):
        (self.root / 'run/w2d-started').write_text('100\n')
        packages = self.root / 'w2d/packages'
        packages.mkdir(exist_ok=True)
        for name in ['a.udeb', 'b.udeb']:
            (packages / name).touch()
        with (self.root / 'w2d/common.sh').open('a') as f:
            f.write('''
udpkg() { printf 'udpkg %s\\n' "$*" >> /run/startup-sequence; }
depmod() { printf 'depmod %s\\n' "$*" >> /run/startup-sequence; }
modprobe() { printf 'modprobe %s\\n' "$*" >> /run/startup-sequence; }
''')
        (self.root / 'run/startup-sequence').unlink(missing_ok=True)
        self.call('/w2d/startup.sh')
        sequence = (self.root / 'run/startup-sequence').read_text().splitlines()
        self.assertTrue(sequence[0].endswith('/w2d/packages/a.udeb'))
        self.assertTrue(sequence[1].endswith('/w2d/packages/b.udeb'))
        self.assertTrue(sequence[2].startswith('depmod -a '))
        self.assertEqual(sequence[3], 'modprobe hv_storvsc')
        self.assertTrue((self.root / 'run/w2d-startup-ready').exists())
        self.assertEqual((self.root / 'run/w2d-state').read_text().strip(), 'trial')
        self.call('/w2d/startup.sh')
        self.assertEqual((self.root / 'run/startup-sequence').read_text().splitlines(), sequence)

    def test_unknown_options_never_skip_confirmation(self):
        for option in ['--yes', '--force', 'auto', '--unknown']:
            self.assertNotEqual(self.call('/w2d/install-debian.sh ' + option, check=False).returncode, 0)
        self.assertEqual((self.root / 'run/w2d-state').read_text().strip(), 'trial')

    def test_anna_guard_blocks_held_then_preserves_arguments(self):
        (self.root / 'run/w2d-state').write_text('held\n')
        real = self.root / 'usr/bin/anna.w2d-real'
        real.write_text('#!/bin/sh\nprintf "%s\\n" "$@" > /run/anna-called\n')
        real.chmod(0o755)
        (self.root / 'run/anna-called').unlink(missing_ok=True)
        proc = subprocess.Popen(['chroot', str(self.root), '/w2d/anna-guard.sh', 'install', 'two words'],
                                stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        try:
            time.sleep(0.1)
            self.assertIsNone(proc.poll())
            self.assertFalse((self.root / 'run/anna-called').exists())
            self.call('. /w2d/common.sh; w2d_publish_authorization')
            self.assertEqual(proc.wait(timeout=5), 0)
            self.assertEqual((self.root / 'run/anna-called').read_text(), 'install\ntwo words\n')
        finally:
            if proc.poll() is None:
                proc.kill()
                proc.wait()
            real.unlink(missing_ok=True)


if __name__ == '__main__':
    unittest.main()
