#!/usr/bin/env python3
"""Haoze Connect distribution configuration validation.

Checks that the internal fork's branding / packaging / update configuration is
internally consistent (Android id + label, Windows exe name + metadata +
installer, app logo, workflow dart-defines and build paths) and that no
upstream Hiddify update channel is left wired into the build.

Run from anywhere:  python3 scripts/haoze_validate.py
"""

import json
import os
import re
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
LOCK_FILE = "hiddify-core.lock.json"

APP_NAME = "Haoze Connect"
BINARY_NAME = "HaozeConnect"
APPLICATION_ID = "com.haoze.connect"
BASE_URL = "https://www.haoze.cyou"
APP_ID_GUID = "c20913cb-7ffa-4db4-b003-b5944d757d21"
UPSTREAM_APP_ID_GUID = "6L903538-42B1-4596-G479-BJ779F21A65D"


def repo(rel: str) -> Path:
    return ROOT / rel


def read(rel: str) -> str:
    return repo(rel).read_text(encoding="utf-8", errors="replace")


class TestAndroidBranding(unittest.TestCase):
    def test_application_id_independent(self):
        gradle = read("android/app/build.gradle")
        self.assertIn(f'applicationId "{APPLICATION_ID}"', gradle)
        self.assertNotIn("app.hiddify.com", gradle)

    def test_kotlin_namespace_untouched(self):
        gradle = read("android/app/build.gradle")
        self.assertIn("namespace 'com.hiddify.hiddify'", gradle)

    def test_manifest_label(self):
        manifest = read("android/app/src/main/AndroidManifest.xml")
        self.assertIn(f'android:label="{APP_NAME}"', manifest)

    def test_manifest_encrypted_prefs_no_backup(self):
        manifest = read("android/app/src/main/AndroidManifest.xml")
        self.assertIn('android:allowBackup="false"', manifest)

    def test_launcher_foreground_is_new_vector(self):
        fg = read("android/app/src/main/res/drawable/ic_launcher_foreground.xml")
        self.assertIn("<vector", fg)
        self.assertNotIn("#455FE9", fg)  # upstream Hiddify mark color
        self.assertIn("#FFFFFF", fg)

    def test_launcher_background_color(self):
        bg = read("android/app/src/main/res/values/ic_launcher_background.xml")
        self.assertIn("#2563EB", bg)


class TestWindowsBranding(unittest.TestCase):
    def test_binary_name(self):
        cmake = read("windows/CMakeLists.txt")
        self.assertIn(f'set(BINARY_NAME "{BINARY_NAME}")', cmake)

    def test_rc_metadata(self):
        rc = read("windows/runner/Runner.rc")
        self.assertIn('VALUE "OriginalFilename", "HaozeConnect.exe"', rc)
        self.assertIn('VALUE "FileDescription", "Haoze Connect"', rc)
        self.assertIn('VALUE "ProductName", "Haoze Connect"', rc)
        self.assertIn('VALUE "CompanyName", "Haoze"', rc)
        self.assertNotIn('VALUE "OriginalFilename", "Hiddify.exe"', rc)

    def test_main_cpp_single_instance_consistency(self):
        main = read("windows/runner/main.cpp")
        self.assertEqual(main.count('L"Haoze Connect"'), 3, "SendAppLinkToInstance/Create title must all match")
        self.assertIn('FindWindowA(NULL, "Haoze Connect")', main)
        self.assertIn('L"HaozeConnectMutex"', main)

    def test_core_interface_names_not_rebranded(self):
        # The Go core exposes HiddifyCli.exe / fixed service names; these must
        # NOT be blindly renamed or the TUN helper breaks.
        tun = read("lib/hiddifycore/core_interface/core_interface_desktop_tun.dart")
        self.assertIn("'HiddifyCli.exe'", tun)
        for f in [
            "windows/packaging/exe/inno_setup.sas",
            "scripts/haoze-windows-installer.iss",
            "lib/hiddifycore/core_interface/core_interface_desktop_tun.dart",
        ]:
            text = read(f)
            self.assertNotIn("HaozeAdminBG", text, "service names are core-owned, must not be invented")
            self.assertNotIn("HaozeTunnelService", text)

    def test_installer_has_no_service_control_and_no_global_uninstall_delete(self):
        for installer in ["scripts/haoze-windows-installer.iss", "windows/packaging/exe/inno_setup.sas"]:
            with self.subTest(installer=installer):
                # Inspect both active packaging entry points, excluding comments.
                code = "\n".join(l for l in read(installer).splitlines() if not l.strip().startswith(";"))
                self.assertFalse(re.search(r"^\[(Code|UninstallDelete)\]\s*$", code, re.M | re.I))
                for forbidden in ["HiddifyAdminBG", "HiddifyTunnelService", "{userappdata}", "runascurrentuser"]:
                    self.assertNotIn(forbidden.lower(), code.lower())
                launches = [line for line in code.splitlines() if "postinstall" in line.lower()]
                self.assertTrue(launches, "installer must retain its optional post-install launch")
                for launch in launches:
                    self.assertIn("runasoriginaluser", launch.lower())

    def test_installer_identity_and_paths(self):
        iss = read("scripts/haoze-windows-installer.iss")
        self.assertIn(APP_ID_GUID, iss)
        self.assertNotIn(UPSTREAM_APP_ID_GUID, iss)
        self.assertIn('DefaultDirName={autopf64}\\HaozeConnect', iss)
        # The package script selects the tree for both ZIP and Setup. The ISS
        # must use the supplied paths, rather than silently packing defaults.
        self.assertIn('Source: "{#SOURCE_DIR}\\*"', iss)
        self.assertIn('OutputDir={#OUTPUT_DIR}', iss)
        self.assertIn('OutputBaseFilename=HaozeConnect-Windows-Setup-x64-{#APP_VERSION}', iss)
        self.assertIn('SetupIconFile=..\\windows\\runner\\resources\\app_icon.ico', iss)
        self.assertTrue(repo("windows/runner/resources/app_icon.ico").exists())
        # A declared language must exist without relying on optional files in
        # the compiler installation (the first Windows CI run exposed this).
        for language_file in re.findall(r'MessagesFile:\s*"([^"]+)"', iss):
            if not language_file.startswith("compiler:"):
                self.assertTrue(
                    (repo("scripts") / language_file.replace("\\", "/")).is_file(),
                    f"Missing bundled installer language: {language_file}",
                )

    def test_fastforge_exe_config(self):
        cfg = read("windows/packaging/exe/make_config.yaml")
        self.assertIn("app_id: " + APP_ID_GUID, cfg)
        self.assertIn("display_name: " + APP_NAME, cfg)
        self.assertIn('install_dir_name: "{autopf64}\\\\HaozeConnect"', cfg)
        self.assertIn("https://www.haoze.cyou", cfg)

    def test_msix_identity(self):
        cfg = read("windows/packaging/msix/make_config.yaml")
        self.assertIn("identity_name: Haoze.HaozeConnect", cfg)
        self.assertIn("display_name: " + APP_NAME, cfg)
        self.assertNotIn("Hiddify.HiddifyNext", cfg)

    def test_package_script_matches(self):
        ps = read("scripts/haoze-package-windows.ps1")
        self.assertIn("HaozeConnect.exe", ps)
        self.assertIn("hiddify-core.dll", ps)
        self.assertIn("HiddifyCli.exe", ps)
        self.assertIn("libcronet.dll", ps)
        self.assertIn("haoze-windows-installer.iss", ps)
        self.assertIn("HaozeConnect-Windows-Standalone-x64.zip", ps)
        self.assertIn('"/DSOURCE_DIR=$BuildDir"', ps)
        self.assertIn('"/DOUTPUT_DIR=$OutDir"', ps)
        self.assertIn('$PSScriptRoot', ps)
        self.assertNotIn('[string]$StagingDir', ps, "temporary cleanup must not delete a caller-selected directory")

    def test_windows_crt_comes_from_selected_toolchain(self):
        cmake = read("windows/CMakeLists.txt")
        self.assertIn('${CMAKE_CXX_COMPILER}', cmake)
        self.assertIn('${_haoze_vc_root}/Redist/MSVC/*', cmake)
        self.assertIn('_version VERSION_GREATER_EQUAL _haoze_toolset_version', cmake)
        self.assertIn('list(FILTER PLUGIN_BUNDLED_LIBRARIES EXCLUDE REGEX', cmake)
        self.assertIn('set(CMAKE_INSTALL_SYSTEM_RUNTIME_LIBS_SKIP TRUE)', cmake)
        self.assertIn('set(CMAKE_INSTALL_DEBUG_LIBRARIES FALSE)', cmake)
        self.assertIn('include(InstallRequiredSystemLibraries)', cmake)
        self.assertLess(cmake.index('install(FILES "${PLUGIN_BUNDLED_LIBRARIES}"'),
                        cmake.index('install(FILES ${CMAKE_INSTALL_SYSTEM_RUNTIME_LIBS}'))
        self.assertIn('CONFIGURATIONS Profile Release', cmake)
        self.assertIn('check_msvc_runtime.ps1', cmake)
        check = read("windows/scripts/check_msvc_runtime.ps1")
        for assertion in ['ReadUInt16() -ne $expectedMachine', '$version -lt $MinimumVersion',
                          'Microsoft Corporation', 'CACHE_ONLY_URL_RETRIEVAL', '$status -ne 0']:
            self.assertIn(assertion, check)


class TestDartConstantsAndUpdates(unittest.TestCase):
    def test_app_name_define(self):
        c = read("lib/core/model/constants.dart")
        # Parsing tolerance: dart format may wrap order/arguments across lines.
        self.assertRegex(
            c,
            re.compile(
                r'static\s+const\s+appName\s*=\s*'
                r'string\.fromEnvironment\(\s*[\'"]XBOARD_APP_NAME[\'"],\s*'
                r'(?:defaultValue:\s*[\'"]Haoze Connect[\'"],?\s*)?\)',
                re.I | re.S,
            ),
        )

    def test_upstream_update_endpoints_removed(self):
        c = read("lib/core/model/constants.dart")
        # No constant-mapped upstream update endpoints.
        for upstream in [
            "static const githubReleasesApiUrl",
            "static const githubLatestReleaseUrl",
            "static const appCastUrl =",
        ]:
            self.assertNotIn(upstream, c)
        # No literal upstream update URL usable as a channel.
        self.assertNotIn('https://api.github.com/repos/hiddify', c)
        self.assertNotIn('https://raw.githubusercontent.com/hiddify', c)
        # attribution links kept (license condition)
        self.assertIn("https://github.com/hiddify/hiddify-next", c)

    def test_update_url_validation(self):
        c = read("lib/core/model/constants.dart")
        self.assertIn('String.fromEnvironment("XBOARD_UPDATE_URL")', c)
        self.assertIn("scheme != 'https'", c)
        # forbid upstream endpoints & bare github repo urls as feeds
        self.assertIn("host == 'github.com'", c)
        self.assertIn("path.startsWith('/hiddify/')", c)
        self.assertIn("path.startsWith('/repos/hiddify/')", c)
        self.assertIn("hiddify.com", c)

    def test_updater_never_uses_upstream_stores(self):
        notifier = read("lib/features/app_update/notifier/app_update_notifier.dart")
        self.assertNotIn("Constants.appCastUrl", notifier)
        self.assertNotIn("UpgraderPlayStore", notifier)
        self.assertNotIn("UpgraderAppStore", notifier)
        self.assertNotIn("UpgraderAppcastStore(appcastURL: Constants.xboardUpdateUrl)", notifier)
        # Only the validated https feed may be used. The callback is nullable:
        # a null store callback is how "updates disabled" is expressed, so do
        # not require a specific local variable name or non-null assertion.
        self.assertNotIn("Constants.updateUrl!", notifier)
        self.assertIn("Constants.updateUrl", notifier)
        self.assertRegex(notifier, re.compile(r"UpgraderAppcastStore\(\s*appcastURL:"))
        self.assertRegex(notifier, re.compile(r"==\s*null\s*\?\s*null\s*:"))
        self.assertRegex(notifier, re.compile(r"onAndroid:\s*allowCustom\s*\?"))
        self.assertIn("AppUpdateState.disabled()", notifier)

        repository = read("lib/features/app_update/data/app_update_repository.dart")
        self.assertNotIn("Constants.githubReleasesApiUrl", repository)

    def test_manual_check_disabled(self):
        notifier = read("lib/features/app_update/notifier/app_update_notifier.dart")
        self.assertIn("manual update check disabled", notifier)


class TestsCoreLock(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.lock = json.loads(read(LOCK_FILE))

    def test_app_and_core_commits_recorded(self):
        self.assertEqual(self.lock["schema"], 1)
        self.assertEqual(
            self.lock["app"]["commit"],
            "2ab88d922bb478c73d7867abe707180b7e1c96bb",
        )
        self.assertEqual(
            self.lock["core"]["gitlink"],
            "a1104ab7fc518fafa0246f484fc91b07412a69a4",
        )
        self.assertEqual(self.lock["core"]["release_channel"], "draft")

    def _assert_asset(self, platform, filename, extract_to, required):
        asset = self.lock["assets"][platform]
        self.assertEqual(
            asset["url"],
            "https://github.com/hiddify/hiddify-core/releases/download/draft/"
            + filename,
        )
        self.assertRegex(asset["sha256"], re.compile(r"^[0-9a-f]{64}$"))
        self.assertNotEqual(asset["sha256"], "0" * 64)
        self.assertRegex(
            asset["asset_updated_at"],
            re.compile(r"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$"),
        )
        self.assertEqual(asset["archive"], filename)
        self.assertEqual(asset["extract_to"], extract_to)
        self.assertEqual(asset["required"], required)

    def test_android_asset_matches_lock(self):
        self._assert_asset(
            "android",
            "hiddify-lib-android.tar.gz",
            "android/app/libs",
            ["hiddify-core.aar"],
        )

    def test_windows_asset_matches_lock(self):
        self._assert_asset(
            "windows",
            "hiddify-lib-windows-amd64.tar.gz",
            "hiddify-core/bin",
            ["hiddify-core.dll", "HiddifyCli.exe", "libcronet.dll"],
        )

    def test_core_script_supports_offline_verification(self):
        script = read("scripts/haoze_core.py")
        self.assertIn("--archive", script)
        self.assertIn("--cache", script)
        self.assertIn("releases/download/draft/", script)
        self.assertIn("Refusing to use it", script)


class TestsWorkflow(unittest.TestCase):
    def test_upstream_jobs_cannot_run_on_a_fork(self):
        for workflow in repo(".github/workflows").glob("*.yml"):
            if workflow.name == "haoze-build.yml":
                continue
            text = workflow.read_text(encoding="utf-8")
            jobs = re.split(r"(?=^  [A-Za-z_][A-Za-z0-9_-]*:\s*$)", text.split("jobs:\n", 1)[1], flags=re.M)
            for job in jobs:
                if not re.match(r"^  [A-Za-z_][A-Za-z0-9_-]*:", job):
                    continue
                with self.subTest(workflow=workflow.name, job=job.splitlines()[0].strip()):
                    condition = re.search(r"^    if:\s*(.+)$", job, re.M)
                    self.assertIsNotNone(condition, "upstream jobs must explicitly restrict the repository")
                    expr = condition.group(1).strip().strip('"')
                    if expr.startswith("${{") and expr.endswith("}}"):
                        expr = expr[3:-2].strip()
                    # A leading positive equality combined by AND fails closed
                    # for every fork; OR would permit bypassing this condition.
                    self.assertRegex(expr, r"^github\.repository\s*==\s*'hiddify/hiddify-app'(?:\s*&&\s*\(.*\))?$")

    def test_dispatch_only_and_no_publishing(self):
        wf = read(".github/workflows/haoze-build.yml")
        self.assertIn("workflow_dispatch", wf)
        self.assertNotIn("on:\n    push", wf)
        self.assertNotIn("on:\n  push", wf)
        for forbidden in ["gh-release", "softprops/action-gh-release", "create_draft_release", "ccsynch", "upload-release"]:
            self.assertNotIn(forbidden, wf)
        self.assertIn("actions/upload-artifact@v4", wf)
        self.assertEqual(wf.count("actions/upload-artifact"), 3, "android + zip + exe artifact uploads expected")

    def test_flutter_and_dart_defines(self):
        wf = read(".github/workflows/haoze-build.yml")
        self.assertIn('FLUTTER_VERSION: "3.38.5"', wf)
        self.assertIn(f"XBOARD_BASE_URL: {BASE_URL}", wf)
        self.assertIn(f"XBOARD_APP_NAME: {APP_NAME}", wf)
        self.assertIn("--target lib/main_prod.dart", wf)
        self.assertIn("--dart-define='XBOARD_BASE_URL=https://www.haoze.cyou'", wf)
        self.assertIn("--dart-define='XBOARD_APP_NAME=Haoze Connect'", wf)
        self.assertIn('--dart-define="XBOARD_BASE_URL=https://www.haoze.cyou"', wf)
        self.assertIn('--dart-define="XBOARD_APP_NAME=Haoze Connect"', wf)

    def test_core_libs_pinned_from_lock_file(self):
        wf = read(".github/workflows/haoze-build.yml")
        self.assertIn(LOCK_FILE, wf)
        self.assertIn("scripts/haoze_core.py fetch --platform android", wf)
        self.assertIn("scripts/haoze_core.py fetch --platform windows", wf)
        self.assertEqual(wf.count("scripts/haoze_core.py fetch"), 2)
        self.assertIn("--cache", wf)
        # No stable core.version / unverified direct core download in CI.
        self.assertNotIn("CORE_VERSION", wf)
        self.assertNotIn("Select-String -Path dependencies.properties", wf)
        self.assertNotIn("sed -n 's/^core.version=", wf)
        self.assertNotIn("hiddify-core/releases/download/", wf)
        self.assertNotIn("Invoke-WebRequest", wf)

    def test_static_checks_and_regression_tests(self):
        wf = read(".github/workflows/haoze-build.yml")
        self.assertGreaterEqual(wf.count("flutter analyze"), 2)
        self.assertGreaterEqual(wf.count("flutter test"), 2)
        for test_path in [
            "test/features/xboard",
            "test/features/xboard_ui",
            "test/features/profile",
            "test/features/connection/model/startup_connection_test.dart",
        ]:
            self.assertIn(test_path, wf)

    def test_no_upstream_project_secrets(self):
        wf = read(".github/workflows/haoze-build.yml")
        for forbidden in ["SENTRY_DSN", "WINDOWS_SIGNING_KEY", "WINDOWS_SIGNING_PASSWORD", "APPLE_CERTIFICATE", "secrets.APPLE"]:
            self.assertNotIn(forbidden, wf, f"upstream/private secret {forbidden} must not be used")

    def test_signing_iters_via_env_and_validates(self):
        wf = read(".github/workflows/haoze-build.yml")
        for line in wf.splitlines():
            if "${{ secrets." in line:
                self.assertIn(": ${{ secrets.", line, f"secrets must be read via step env mappings only, not into the run shell: {line.strip()}")
        self.assertIn('SIGNING_KEY_B64: ${{ secrets.ANDROID_SIGNING_KEY }}', wf)
        self.assertIn('SIGNING_STORE_PASSWORD: ${{ secrets.ANDROID_SIGNING_STORE_PASSWORD }}', wf)
        self.assertIn("ARTIFACT_NAME=HaozeConnect-Android-debug-signed-test", wf)
        self.assertIn("ARTIFACT_NAME=HaozeConnect-Android-release-signed", wf)
        self.assertIn("signing secret incomplete", wf)

    def test_windows_packaging_steps(self):
        wf = read(".github/workflows/haoze-build.yml")
        self.assertIn("runs-on: windows-2022", wf)
        self.assertIn(".\\scripts\\haoze-windows-smoke.ps1", wf)
        self.assertIn("choco install innosetup -y", wf)
        self.assertIn(".\\scripts\\haoze-package-windows.ps1", wf)
        for artn in ["HaozeConnect-Windows-Standalone-x64-unsigned", "HaozeConnect-Windows-Setup-x64-unsigned"]:
            self.assertIn(artn, wf)


class TestsLogoAndDocs(unittest.TestCase):
    def test_logo_is_original(self):
        svg = read("assets/images/logo.svg")
        self.assertNotIn("clip-path", svg)
        self.assertNotIn("455FE9", svg)
        self.assertIn("Haoze Connect original mark", svg)

    def test_license_kept(self):
        self.assertTrue(repo("LICENSE.md").exists())
        license_text = read("LICENSE.md")
        self.assertIn("GitHub Actions", license_text)

    def test_readme_notes_fork_changes(self):
        readme = read("README.md")
        self.assertIn("Haoze Connect", readme)
        self.assertIn("fork", readme.lower())

    def test_distribution_doc_exists(self):
        doc = read("docs/DISTRIBUTION.md")
        self.assertIn("XBOARD_BASE_URL", doc)
        self.assertIn("XBOARD_UPDATE_URL", doc)
        self.assertIn("HiddifyAdminBG", doc)  # coexistence caveat must be documented
        self.assertIn("GNU GPL v3", doc)
        self.assertIn(LOCK_FILE, doc)
        self.assertIn("SHA256", doc)

    def test_build_cache_ignored_lock_and_scripts_kept(self):
        lines = [line.strip() for line in read(".gitignore").splitlines()]
        self.assertIn("/artifacts/", lines)
        self.assertIn("/android/.kotlin/", lines)
        ignored = "\n".join(line for line in lines if not line.startswith("#"))
        self.assertNotIn("hiddify-core.lock.json", ignored)
        self.assertNotIn("haoze_core.py", ignored)
        self.assertNotIn("haoze_validate.py", ignored)
        self.assertTrue(repo(LOCK_FILE).is_file())
        self.assertTrue(repo("scripts/haoze_core.py").is_file())


if __name__ == "__main__":
    print(f"validating {ROOT}")
    unittest.main(verbosity=2)
