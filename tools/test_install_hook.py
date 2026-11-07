"""Tests for install_hook.py, each against a scratch settings folder.

Run: python3 -m unittest discover -s tools -p 'test_*.py'
"""
import importlib.util
import json
import os
import subprocess
import sys
import tempfile
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
SCRIPT = os.path.join(HERE, "install_hook.py")


def load(env):
    """The installer module, as it would load with [env]."""
    old = dict(os.environ)
    os.environ.update(env)
    try:
        spec = importlib.util.spec_from_file_location("install_hook", SCRIPT)
        mod = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(mod)
        return mod
    finally:
        os.environ.clear()
        os.environ.update(old)


class InstallHookTest(unittest.TestCase):
    def setUp(self):
        self.home = tempfile.mkdtemp()
        self.claude = os.path.join(self.home, "claude-config")
        os.makedirs(self.claude)
        self.settings = os.path.join(self.claude, "settings.json")

    def run_installer(self, *args):
        env = {**os.environ, "CLAUDE_CONFIG_DIR": self.claude, "HOME": self.home, "USERPROFILE": self.home}
        return subprocess.run([sys.executable, "-I", SCRIPT, *args], env=env, capture_output=True, text=True)

    def text(self):
        with open(self.settings, encoding="utf-8") as f:
            return f.read()

    def read(self):
        with open(self.settings, encoding="utf-8") as f:
            return json.load(f)

    def write(self, data):
        with open(self.settings, "w", encoding="utf-8") as f:
            json.dump(data, f, ensure_ascii=False)

    def test_finds_settings_in_claude_config_dir_or_home(self):
        self.assertEqual(load({"CLAUDE_CONFIG_DIR": self.claude}).SETTINGS, self.settings)
        os.environ.pop("CLAUDE_CONFIG_DIR", None)
        mod = load({"HOME": self.home, "USERPROFILE": self.home, "CLAUDE_CONFIG_DIR": ""})
        self.assertEqual(mod.SETTINGS, os.path.join(self.home, ".claude", "settings.json"))

    def test_installs_keeps_other_settings_and_is_idempotent(self):
        self.write({"model": "haiku", "hooks": {"Stop": [{"hooks": [{"type": "command", "command": "echo mine"}]}]}})
        r = self.run_installer()
        self.assertEqual(r.returncode, 0, r.stderr)
        s = self.read()
        self.assertEqual(s["model"], "haiku")
        self.assertEqual(len(s["hooks"]["Stop"]), 2)  # yours kept, ours added
        self.assertIn("mcp__claude-code-remote__send_message", s["hooks"]["PostToolUse"][0]["matcher"])
        self.assertTrue(os.path.exists(self.settings + ".bak"))
        before = self.text()
        r = self.run_installer()
        self.assertIn("Nothing to change", r.stdout)
        self.assertEqual(self.text(), before)

    def test_upgrades_an_older_copy_in_place(self):
        old = {"type": "command", "command": "curl -s -m 1 -X POST http://127.0.0.1:47321/changed >/dev/null 2>&1 || true",
               "async": True, "timeout": 3}
        self.write({"hooks": {"PostToolUse": [{"matcher": "mcp__hearthbot__post_message", "hooks": [old]}]}})
        self.assertEqual(self.run_installer().returncode, 0)
        groups = self.read()["hooks"]["PostToolUse"]
        self.assertEqual(len(groups), 1)
        self.assertIn("claude-code-remote__send_message", groups[0]["matcher"])

    def test_uninstall_removes_only_ours(self):
        self.write({"hooks": {"Stop": [{"hooks": [{"type": "command", "command": "echo mine"}]}]}})
        self.run_installer()
        r = self.run_installer("--uninstall")
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(self.read(), {"hooks": {"Stop": [{"hooks": [{"type": "command", "command": "echo mine"}]}]}})

    def test_keeps_non_ascii_text_intact(self):
        self.write({"statusLine": {"type": "command", "command": "echo 'café ✓ 日本'"}})
        self.run_installer()
        self.assertEqual(self.read()["statusLine"]["command"], "echo 'café ✓ 日本'")

    def test_a_broken_settings_file_is_left_alone(self):
        with open(self.settings, "w", encoding="utf-8") as f:
            f.write("{ not json")
        r = self.run_installer()
        self.assertNotEqual(r.returncode, 0)
        self.assertIn("Nothing was changed", r.stderr)
        self.assertEqual(self.text(), "{ not json")

    def test_help_and_unknown_arguments_change_nothing(self):
        for args, code in ((["--help"], 0), (["-h"], 0), (["--nope"], 2)):
            r = self.run_installer(*args)
            self.assertEqual(r.returncode, code)
            self.assertIn("Usage:", r.stdout)
        self.assertFalse(os.path.exists(self.settings))

    def test_creates_settings_when_there_are_none(self):
        os.rmdir(self.claude)
        self.assertEqual(self.run_installer().returncode, 0)
        self.assertEqual(set(self.read()["hooks"]), {"UserPromptSubmit", "Stop", "PostToolUse"})


if __name__ == "__main__":
    unittest.main()
