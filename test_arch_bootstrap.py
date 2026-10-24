#!/usr/bin/env python3
"""Unprivileged tests: real signature failures, path guards, and mount planning."""
import os
from pathlib import Path
import shlex
import shutil
import subprocess
import tempfile
import unittest

SCRIPT = Path(__file__).with_name("arch-bootstrap.sh")


class ShellRunner:
    def shell(self, code, *args):
        return subprocess.run(
            ["bash", "-c", f"source {shlex.quote(str(SCRIPT))}\n{code}", "test", *map(str, args)],
            text=True, capture_output=True, check=False,
        )


class BootstrapTests(ShellRunner, unittest.TestCase):
    def test_help_needs_no_root_or_network(self):
        result = subprocess.run(["bash", str(SCRIPT), "--help"], capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("NOT a sandbox", result.stdout)

    def test_invalid_arguments(self):
        for args in [[], ["relative"], ["--wat"], ["--release"],
                     ["--release", "../bad", "/srv/arch"],
                     ["--enter", "--release", "2026.10.01", "/srv/arch"],
                     ["/srv/one", "/srv/two"]]:
            with self.subTest(args=args):
                self.assertNotEqual(self.shell('parse_args "$@"', *args).returncode, 0)

    def test_internal_session_cannot_bypass_namespace_entry(self):
        result = subprocess.run(["bash", str(SCRIPT), "--internal-session", "/", "/etc/resolv.conf"],
                                capture_output=True, text=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Unknown option", result.stderr)

    def test_version_discovery_ignores_unversioned_alias(self):
        with tempfile.TemporaryDirectory() as tmp:
            index = Path(tmp) / "index"
            index.write_text('<a href="archlinux-bootstrap-x86_64.tar.zst">latest</a>\n'
                             '<a href="archlinux-bootstrap-2026.10.01-x86_64.tar.zst">dated</a>\n')
            result = self.shell('discover_release "$1"', index)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(result.stdout.strip(), "2026.10.01")

    def test_unrecognised_index_fails(self):
        with tempfile.NamedTemporaryFile(mode="w") as index:
            index.write("<html>No bootstrap</html>\n")
            index.flush()
            self.assertNotEqual(self.shell('discover_release "$1"', index.name).returncode, 0)

    def test_existing_destination_and_symlink_are_preserved(self):
        with tempfile.TemporaryDirectory() as tmp:
            target = Path(tmp) / "existing"
            target.mkdir()
            sentinel = target / "keep"
            sentinel.write_text("valuable")
            link = Path(tmp) / "link"
            link.symlink_to(target)
            for destination in (target, link):
                result = self.shell('MODE=create; DESTINATION=$1; check_ancestors() { :; }; check_destination', destination)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("already exists", result.stderr)
                self.assertEqual(sentinel.read_text(), "valuable")

    def test_user_owned_ancestor_is_rejected(self):
        if os.getuid() == 0:
            self.skipTest("This test requires an unprivileged runner")
        with tempfile.TemporaryDirectory() as tmp:
            result = self.shell('check_ancestors "$1"', tmp)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("root-owned", result.stderr)

    def test_readonly_and_non_linux_filesystems_are_rejected(self):
        with tempfile.TemporaryDirectory() as tmp:
            for fstype, options in [("ext4", "ro,relatime"), ("ext4", "rw,noexec"),
                                    ("ntfs3", "rw"), ("exfat", "rw")]:
                with self.subTest(fstype=fstype, options=options):
                    result = self.shell('''
                        MODE=create; DESTINATION=$1
                        check_ancestors() { :; }
                        test_fs=$2; test_options=$3
                        findmnt() { if [[ $* == *FSTYPE* ]]; then echo "$test_fs"; else echo "$test_options"; fi; }
                        check_destination
                    ''', Path(tmp) / "new-root", fstype, options)
                    self.assertNotEqual(result.returncode, 0, result.stderr)

    def test_mount_plan_uses_recursive_devices_private_run_and_resolver(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp) / "root"
            for directory in ("dev", "proc", "sys", "run", "tmp", "etc"):
                (root / directory).mkdir(parents=True)
            (root / "etc/resolv.conf").touch()
            result = self.shell('''
                mount() { printf 'mount'; printf ' <%s>' "$@"; printf '\\n'; }
                chroot() { printf 'chroot <%s>\\n' "$1"; }
                enter_session "$1" "$2"
            ''', root, Path(tmp) / "resolver")
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn("<--rbind> </dev>", result.stdout)
            self.assertIn(f"<--make-rslave> <{root}/dev>", result.stdout)
            self.assertIn("<--rbind> </sys>", result.stdout)
            self.assertIn("<nosuid,nodev,mode=755>", result.stdout)
            self.assertIn("<remount,bind,ro>", result.stdout)
            self.assertNotIn("<--rbind> </run>", result.stdout)

    def test_official_metadata_layout_and_unexpected_member(self):
        with tempfile.TemporaryDirectory() as tmp:
            base = Path(tmp)
            (base / "root.x86_64").mkdir()
            (base / "root.x86_64/inside").write_text("fixture")
            (base / "pkglist.x86_64.txt").write_text("package versions")
            (base / "version").write_text("2026.10.01")
            (base / "unexpected").write_text("outside root")
            for members, accepted in [(["root.x86_64", "pkglist.x86_64.txt", "version"], True),
                                      (["root.x86_64", "unexpected"], False),
                                      (["pkglist.x86_64.txt", "version"], False)]:
                with self.subTest(members=members):
                    archive = base / "fixture.tar.zst"
                    subprocess.run(["tar", "--zstd", "-cf", str(archive), "-C", str(base), *members],
                                   check=True, capture_output=True)
                    result = self.shell('check_archive_layout "$1" "$2"', archive, base / "members")
                    self.assertEqual(result.returncode == 0, accepted, result.stderr)


@unittest.skipUnless(shutil.which("gpg") and shutil.which("gpgconf"), "GnuPG is needed")
class SignatureTests(ShellRunner, unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temp = tempfile.TemporaryDirectory(prefix="arch-bootstrap-test-")
        cls.base = Path(cls.temp.name)
        cls.signhome = cls.base / "signing"
        cls.signhome.mkdir(mode=0o700)
        cls.gpg = ["gpg", "--no-options", "--homedir", str(cls.signhome), "--batch"]
        result = subprocess.run(cls.gpg + ["--pinentry-mode", "loopback", "--passphrase", "",
                                         "--quick-generate-key", "Bootstrap fixture <test@example.invalid>",
                                         "ed25519", "sign", "0"], capture_output=True, text=True)
        if result.returncode:
            cls.temp.cleanup()
            raise RuntimeError(result.stderr)
        listed = subprocess.run(cls.gpg + ["--with-colons", "--list-keys"], check=True,
                                capture_output=True, text=True).stdout
        cls.fingerprint = next(line.split(":")[9] for line in listed.splitlines() if line.startswith("fpr:"))
        cls.key = cls.base / "release.asc"
        cls.key.write_bytes(subprocess.run(cls.gpg + ["--armor", "--export", cls.fingerprint],
                                          check=True, capture_output=True).stdout)
        cls.archive = cls.base / "archive"
        cls.archive.write_bytes(b"Known authentic release fixture\n")
        cls.signature = cls.base / "archive.sig"
        subprocess.run(cls.gpg + ["--detach-sign", "--output", str(cls.signature), str(cls.archive)],
                       check=True, capture_output=True)

    @classmethod
    def tearDownClass(cls):
        subprocess.run(["gpgconf", "--homedir", str(cls.signhome), "--kill", "gpg-agent"],
                       check=False, capture_output=True)
        cls.temp.cleanup()

    def verify(self, key, archive, fingerprint):
        with tempfile.TemporaryDirectory(dir=self.base) as tmp:
            return self.shell('verify_signature "$1" "$2" "$3" "$4" "$5"',
                              key, self.signature, archive, Path(tmp) / "verify", fingerprint)

    def test_valid_pinned_signature(self):
        result = self.verify(self.key, self.archive, self.fingerprint)
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_modified_archive_is_rejected(self):
        tampered = self.base / "tampered"
        tampered.write_bytes(self.archive.read_bytes() + b"tampered")
        result = self.verify(self.key, tampered, self.fingerprint)
        self.assertNotEqual(result.returncode, 0)

    def test_wrong_pinned_fingerprint_is_rejected(self):
        result = self.verify(self.key, self.archive, "0" * 40)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("fingerprint", result.stderr)

    def test_failed_signature_prevents_destination_creation(self):
        with tempfile.TemporaryDirectory(dir=self.base) as tmp:
            base = Path(tmp)
            work = base / "work"
            work.mkdir()
            target = base / "destination"
            tampered = base / "tampered"
            tampered.write_bytes(b"not the signed archive")
            result = self.shell('''
                WORK=$1; PARENT=$2; ROOT=$3; RELEASE=2026.10.01
                fixture_key=$4; fixture_signature=$5; fixture_archive=$6
                RELEASE_FINGERPRINT=$7
                df() { printf 'Filesystem 1048576-blocks Used Available Capacity Mounted\\nfixture 8000 1 7999 1%% /\\n'; }
                fetch() {
                    case $1 in
                        *.sig) cp "$fixture_signature" "$2" ;;
                        *keyserver*) cp "$fixture_key" "$2" ;;
                        *) cp "$fixture_archive" "$2" ;;
                    esac
                }
                create_bootstrap
            ''', work, base, target, self.key, self.signature, tampered, self.fingerprint)
            self.assertNotEqual(result.returncode, 0)
            self.assertFalse(target.exists(), "Extraction must never start after a failed signature")

    def test_failed_extraction_leaves_no_published_root(self):
        with tempfile.TemporaryDirectory(dir=self.base) as tmp:
            base = Path(tmp)
            work = base / "work"
            work.mkdir()
            target = base / "destination"
            result = self.shell('''
                WORK=$1; PARENT=$2; ROOT=$3; RELEASE=2026.10.01
                fixture_key=$4; fixture_signature=$5; fixture_archive=$6
                RELEASE_FINGERPRINT=$7
                trap cleanup_work EXIT
                df() { printf 'Filesystem 1048576-blocks Used Available Capacity Mounted\\nfixture 8000 1 7999 1%% /\\n'; }
                fetch() {
                    case $1 in
                        *.sig) cp "$fixture_signature" "$2" ;;
                        *keyserver*) cp "$fixture_key" "$2" ;;
                        *) cp "$fixture_archive" "$2" ;;
                    esac
                }
                check_archive_layout() { :; }
                tar() { printf 'simulated full disk\\n' >&2; return 77; }
                create_bootstrap
            ''', work, base, target, self.key, self.signature, self.archive, self.fingerprint)
            self.assertEqual(result.returncode, 77, result.stderr)
            self.assertFalse(target.exists())
            self.assertFalse(work.exists())


if __name__ == "__main__":
    unittest.main()
