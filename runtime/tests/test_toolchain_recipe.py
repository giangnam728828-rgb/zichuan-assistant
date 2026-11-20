#!/usr/bin/env python3
"""Guard Ubuntu developer-tool source and command aliases in the runtime recipe."""
import importlib.util
from pathlib import Path
import posixpath
import unittest

sys_path = Path(__file__).resolve().parents[1] / "lib" / "rtbuild.py"
spec = importlib.util.spec_from_file_location("rtbuild", sys_path)
rtbuild = importlib.util.module_from_spec(spec)
spec.loader.exec_module(rtbuild)


class ToolchainRecipe(unittest.TestCase):
    def test_go_cross_arch_objects_are_not_runtime_elf(self):
        self.assertTrue(rtbuild.is_go_arch_object(
            "usr/share/go-1.22/src/crypto/internal/boring/syso/goboringcrypto_linux_amd64.syso"
        ))
        self.assertTrue(rtbuild.is_go_arch_object(
            "usr/share/go-1.22/src/debug/dwarf/testdata/bitfields.elf4"
        ))
        self.assertFalse(rtbuild.is_go_arch_object("usr/bin/gcc-13"))

    def test_universe_sources_match_runtime_architecture(self):
        for abi, host in (("arm64-v8a", "ports.ubuntu.com/ubuntu-ports"),
                          ("x86_64", "archive.ubuntu.com/ubuntu")):
            with self.subTest(abi=abi):
                overlay = rtbuild.overlay_entries({"abi": abi})
                sources = overlay["etc/apt/sources.list.d/ubuntu.sources"].data.decode()
                self.assertIn(host, sources)
                self.assertIn("Suites: noble noble-updates", sources)
                self.assertIn("Suites: noble-security", sources)
                self.assertEqual(sources.count("Components: main universe"), 2)
                self.assertIn("ubuntu-archive-keyring.gpg", sources)

    def test_java_home_is_fixed_for_each_abi(self):
        for abi, host_arch in (("arm64-v8a", "arm64"), ("x86_64", "amd64")):
            with self.subTest(abi=abi):
                self.assertIn(
                    f"JAVA_HOME=/usr/lib/jvm/java-21-openjdk-{host_arch}",
                    rtbuild.launch_template(abi)["argv"],
                )
                profile = rtbuild.overlay_entries({"abi": abi})["etc/profile.d/dsh-app.sh"].data.decode()
                self.assertIn(f"java-21-openjdk-{host_arch}", profile)

    def test_versioned_compiler_aliases_resolve_inside_rootfs(self):
        abi = "arm64-v8a"
        entries = {
            f"usr/bin/{name}-{version}": rtbuild.Entry("file", 0o755, data=b"x", origin="deb")
            for name, version in (("gcc", "13"), ("g++", "13"), ("cpp", "13"),
                                  ("clang", "18"), ("clang++", "18"))
        }
        home = "usr/lib/jvm/java-21-openjdk-arm64"
        entries[home] = rtbuild.Entry("dir", 0o755, origin="deb")
        for name in ("java", "javac"):
            entries[f"{home}/bin/{name}"] = rtbuild.Entry("file", 0o755, data=b"x", origin="deb")

        aliases = rtbuild.install_toolchain_shims(entries, abi)
        self.assertTrue({"gcc", "cc", "g++", "c++", "clang", "clang++", "java", "javac"} <= aliases.keys())
        for name, target in aliases.items():
            link = entries[f"usr/local/bin/{name}"].link
            self.assertEqual(posixpath.normpath(posixpath.join("usr/local/bin", link)), target)


if __name__ == "__main__":
    unittest.main(verbosity=2)
