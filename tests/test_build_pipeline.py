"""Build metadata and fail-closed workflow wiring, without pretending to compile macOS."""
import os
import plistlib
import re
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


class BuildPipelineTests(unittest.TestCase):
    def setUp(self):
        directory = tempfile.TemporaryDirectory()
        self.addCleanup(directory.cleanup)
        self.root = Path(directory.name)
        self.bin = self.root / "bin"
        self.bin.mkdir()
        self.log = self.root / "commands.log"
        self.env = {**os.environ, "PATH": str(self.bin) + os.pathsep + os.environ["PATH"], "COMMAND_LOG": str(self.log)}
        for key in ("VERSION", "DEVELOP_SHA", "BUILD_COMMIT", "GITHUB_RUN_NUMBER", "FAIL_TEST"):
            self.env.pop(key, None)
        self.stub("git", 'exit 1\n')  # no repository in the isolated build fixture
        self.stub("codesign", 'exit 0\n')
        self.stub("xcrun", '''
if [[ "$*" == *--show-sdk-path* ]]; then echo /fake-sdk; exit 0; fi
printf '%s\\n' "$*" >> "$COMMAND_LOG"
if [[ "$1" == lipo ]]; then
  while [[ "$1" != -output ]]; do shift; done
  shift
  touch "$1"
  exit 0
fi
while [[ "$#" -gt 0 ]]; do
  if [[ "$1" == -o ]]; then
    shift
    cat > "$1" <<'PROGRAM'
#!/bin/bash
printf 'execute:%s\\n' "$(basename "$0")" >> "$COMMAND_LOG"
[[ "$(basename "$0")" != "${FAIL_TEST:-}" ]]
PROGRAM
    chmod +x "$1"
    exit 0
  fi
  shift
done
exit 1
''')
        for name in ("services", "config", ".github", "app/Sources"):
            (self.root / name).mkdir(parents=True, exist_ok=True)
        (self.root / "services/helper.py").write_text("# fixture\n")
        (self.root / "config/config.example.json").write_text("{}")
        (self.root / ".github/RELEASE_VERSION").write_text((ROOT / ".github/RELEASE_VERSION").read_text())
        shutil.copy2(ROOT / "build_app.sh", self.root)

    def stub(self, name, body):
        path = self.bin / name
        path.write_text("#!/bin/bash\nset -euo pipefail\n" + body)
        path.chmod(0o755)

    def build(self, **env):
        result = subprocess.run(["bash", str(self.root / "build_app.sh")], env={**self.env, **env}, capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        with (self.root / "build/VEN OBS Utils.app/Contents/Info.plist").open("rb") as handle:
            return plistlib.load(handle)

    def test_develop_sha_is_separate_from_apple_numeric_versions(self):
        sha = "abcdef0123456789" * 2 + "abcdef01"
        info = self.build(DEVELOP_SHA=sha)
        release = (ROOT / ".github/RELEASE_VERSION").read_text().strip().removeprefix("v")
        self.assertEqual(info["CFBundleShortVersionString"], re.split(r"[-+]", release)[0])
        self.assertRegex(info["CFBundleVersion"], r"^[0-9]+(?:\.[0-9]+){0,2}$")
        self.assertEqual(info["VENDevelopCommit"], sha)
        self.assertIn("develop " + sha[:12], info["CFBundleGetInfoString"])
        self.assertEqual(info["CFBundleIdentifier"], "works.ven.obs-utils")

    def test_release_semver_and_prerelease_keep_numeric_bundle_versions(self):
        for version in ("0.2.0", "2.3.4-rc.1", "2.3.4-rc.1+build.5"):
            info = self.build(VERSION=version)
            self.assertEqual(info["CFBundleShortVersionString"], version.split("-")[0])
            self.assertEqual(info["CFBundleVersion"], "1")
            self.assertEqual(info["CFBundleGetInfoString"], version)
            self.assertFalse(info.get("VENDevelopCommit"))

    def test_invalid_metadata_fails_before_compilation(self):
        for env in ({"DEVELOP_SHA": "not-a-commit"}, {"VERSION": "garbage"}):
            result = subprocess.run(["bash", str(self.root / "build_app.sh")], env={**self.env, **env}, capture_output=True)
            self.assertNotEqual(result.returncode, 0)
            self.assertFalse(self.log.exists(), "Invalid metadata must not compile or replace the app")

    def test_tests_and_release_share_required_suite_before_build_and_publish(self):
        for filename in ("test.yml", "release.yml"):
            workflow = (ROOT / ".github/workflows" / filename).read_text()
            self.assertIn("run: ./test.sh", workflow)
            self.assertLess(workflow.index("run: ./test.sh"), workflow.index("run: ./build_app.sh"))
            self.assertNotIn("continue-on-error", workflow)
            if filename == "release.yml":
                self.assertLess(workflow.index("run: ./test.sh"), workflow.index("gh release"))
        suite = (ROOT / "test.sh").read_text()
        self.assertIn("python3 -m unittest discover -s tests -v", suite)
        discovered = {path.name for path in (ROOT / "app/Tests").glob("*.swift")}
        referenced = set(re.findall(r"app/Tests/([A-Za-z]+Tests\.swift)", suite))
        self.assertEqual(referenced, discovered, "Every Swift suite must remain in the shared test gate")

    def test_shared_suite_stops_on_swift_failure(self):
        shutil.copy2(ROOT / "test.sh", self.root)
        self.stub("python3", 'printf "python:%s\\n" "$*" >> "$COMMAND_LOG"\n')
        result = subprocess.run(["bash", str(self.root / "test.sh")],
                                env={**self.env, "FAIL_TEST": "scene-automation-tests"}, capture_output=True)
        self.assertNotEqual(result.returncode, 0)
        log = self.log.read_text()
        self.assertIn("python:-m unittest discover -s tests -v", log)
        self.assertIn("execute:scene-automation-tests", log)
        self.assertNotIn("app-config-migration-tests", log)

    def test_shared_suite_stops_on_python_failure(self):
        shutil.copy2(ROOT / "test.sh", self.root)
        self.stub("python3", 'exit 7\n')
        result = subprocess.run(["bash", str(self.root / "test.sh")], env=self.env, capture_output=True)
        self.assertEqual(result.returncode, 7)
        self.assertFalse(self.log.exists(), "No Swift compilation may follow a failed Python suite")

    def test_universal_build_uses_explicit_macos13_targets_and_embeds_rc_commit(self):
        sha = "1234567890abcdef" * 2 + "12345678"
        info = self.build(VERSION="0.2.1-rc.1", BUILD_COMMIT=sha)
        self.assertEqual(info["VENBuildCommit"], sha)
        self.assertEqual(info["CFBundleShortVersionString"], "0.2.1")
        log = self.log.read_text()
        self.assertIn("-target arm64-apple-macosx13.0", log)
        self.assertIn("-target x86_64-apple-macosx13.0", log)
        self.assertIn("lipo -create", log)

    def test_rc_tag_resolution_is_explicit_and_invalid_suffix_fails_closed(self):
        import textwrap
        workflow = (ROOT / '.github/workflows/release.yml').read_text()
        block = workflow.split('      - name: Resolve release version', 1)[1].split('      - name:', 1)[0]
        script = textwrap.dedent(block.split('        run: |\n', 1)[1])
        output = self.root / 'outputs'
        for tag, flag in [('v0.2.1-rc.1', 'true'), ('v0.2.1', 'false')]:
            output.write_text('')
            result = subprocess.run(['bash', '-c', script], cwd=ROOT, env={**self.env,
                'GITHUB_REF_TYPE':'tag', 'GITHUB_REF_NAME':tag, 'GITHUB_OUTPUT':str(output)}, capture_output=True)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn('prerelease=' + flag, output.read_text())
        result = subprocess.run(['bash', '-c', script], cwd=ROOT, env={**self.env,
            'GITHUB_REF_TYPE':'tag', 'GITHUB_REF_NAME':'v0.2.1-unknown.1', 'GITHUB_OUTPUT':str(output)}, capture_output=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('FLAGS+=(--prerelease --latest=false --notes-file', workflow)
        self.assertIn('--verify-tag', workflow)
        self.assertNotIn('--clobber', workflow)

    def test_packaging_rejects_unsafe_label_before_tools(self):
        result = subprocess.run(['bash', str(ROOT / 'package_app.sh'), '../invalid'], env=self.env, capture_output=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(self.log.exists())
