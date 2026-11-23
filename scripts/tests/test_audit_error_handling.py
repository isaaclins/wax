"""
Tests for scripts/audit-error-handling.sh (#607) and the driver half of
scripts/eq-mic-permission-audit.sh.

Each rule gets a fixture built from a real site on main that the audit issue
named (try? cache.loadPinnedItems, a catch that only sets a flag, the driver's
(void)AudioObjectSetPropertyData, error.localizedDescription in the settings
store, ...). The audit must fail on it as new code, naming the file, line and
rule; let it through once it is in the baseline; and fail again when a second
copy appears or when the baseline lists a site that is gone.

Run from the repository root:  python3 -m unittest discover -s scripts/tests
"""
import json
import shutil
import subprocess
import sys
import tempfile
import textwrap
import unittest
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
AUDIT = REPO / 'scripts' / 'audit_error_handling.py'
MIC_AUDIT = REPO / 'scripts' / 'eq-mic-permission-audit.sh'
BASELINE = 'scripts/error-handling-baseline.json'


class Fixture(unittest.TestCase):
    def setUp(self):
        self.root = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, self.root)
        (self.root / 'scripts').mkdir()
        self.write(BASELINE, '[]\n')

    def write(self, rel, text):
        p = self.root / rel
        p.parent.mkdir(parents=True, exist_ok=True)
        p.write_text(textwrap.dedent(text))

    def audit(self, *args):
        r = subprocess.run([sys.executable, str(AUDIT), '--root', str(self.root), *args],
                           capture_output=True, text=True)
        return r.returncode, r.stdout + r.stderr

    def assertFinding(self, rel, line, rule):
        code, out = self.audit()
        self.assertEqual(code, 1, out)
        self.assertIn('%s:%d: [%s]' % (rel, line, rule), out)

    def assertClean(self):
        code, out = self.audit()
        self.assertEqual(code, 0, out)


class RulesFailOnNewCode(Fixture):
    def test_try_without_reason(self):
        self.write('Spotiglass/Pinning/PinStore.swift', '''\
            func load() {
                pinned = (try? cache.loadPinnedItems()) ?? []
            }
            ''')
        self.assertFinding('Spotiglass/Pinning/PinStore.swift', 2, 'try-reason')

    def test_try_with_reason_on_same_line_or_line_above_passes(self):
        self.write('Spotiglass/Pinning/PinStore.swift', '''\
            func load() {
                try? handle.close() // try?: the file is moved next; a failed close only leaks a descriptor
                // try?: best-effort cleanup, nothing depends on it
                try? FileManager.default.removeItem(at: url)
            }
            ''')
        self.assertClean()

    def test_an_unrelated_comment_is_not_a_reason(self):
        self.write('Spotiglass/Pinning/PinStore.swift', '''\
            func load() {
                // Load the pins.
                pinned = (try? cache.loadPinnedItems()) ?? []
            }
            ''')
        self.assertFinding('Spotiglass/Pinning/PinStore.swift', 3, 'try-reason')

    def test_try_inside_a_string_or_comment_is_ignored_but_not_inside_interpolation(self):
        self.write('Spotiglass/Views/Help.swift', '''\
            let help = "use try? sparingly" // a try? here is fine
            let shown = "\\(try? store.load())"
            ''')
        code, out = self.audit()
        self.assertEqual(code, 1, out)
        self.assertIn('Spotiglass/Views/Help.swift:2: [try-reason]', out)
        self.assertNotIn('Help.swift:1:', out)

    def test_catch_that_drops_the_error(self):
        self.write('Spotiglass/Settings/Store.swift', '''\
            func save() {
                do {
                    try settingsStore.mutate { $0.volume = 1 }
                } catch {
                    didFail = true
                }
            }
            ''')
        self.assertFinding('Spotiglass/Settings/Store.swift', 4, 'catch-drops-error')

    def test_empty_catch_fails_even_with_a_comment(self):
        self.write('Spotiglass/Playback/Lyrics.swift', '''\
            func scroll() async {
                do { try await Task.sleep(for: .seconds(1)) } catch {
                    // Cancellation is the normal path.
                }
            }
            ''')
        self.assertFinding('Spotiglass/Playback/Lyrics.swift', 2, 'catch-drops-error')

    def test_catch_that_logs_rethrows_or_hands_on_passes(self):
        self.write('Spotiglass/Services/Client.swift', '''\
            func a() throws {
                do { try x() } catch { SpotiglassLog.error(.api, "x failed: \\(SpotiglassLog.describe(error))") }
                do { try x() } catch { throw MyError.wrapped }
                do { try x() } catch { logRequestFailure(error: error) }
                do { try x() } catch { continuation.resume(throwing: error) }
                do { try x() } catch { completion(.failure(error)) }
                do { try x() } catch is CancellationError { return }
            }
            ''')
        self.assertClean()

    def test_print_in_swift(self):
        self.write('SpotiglassEQPrivilegedHelper/main.swift', 'print("helper started")\n')
        self.assertFinding('SpotiglassEQPrivilegedHelper/main.swift', 1, 'print-logging')
        self.write('SpotiglassEQPrivilegedHelper/main.swift', 'NSLog("helper started")\n')
        self.assertFinding('SpotiglassEQPrivilegedHelper/main.swift', 1, 'print-logging')

    def test_print_in_driver_unless_behind_the_debug_flag(self):
        self.write('SpotiglassEQDriver/Plugin.cpp', '''\
            #if defined(SPOTIGLASS_EQ_DEBUG)
            fprintf(stderr, "StartIO\\n");
            #endif
            static void f() { snprintf(buf, sizeof buf, "%d", 1); }
            ''')
        self.assertClean()
        self.write('SpotiglassEQDriver/Plugin.cpp', '''\
            #if defined(SPOTIGLASS_EQ_DEBUG)
            #else
            fprintf(stderr, "StartIO\\n");
            #endif
            ''')
        self.assertFinding('SpotiglassEQDriver/Plugin.cpp', 3, 'print-logging')

    def test_blocking_wait_in_the_app(self):
        self.write('Spotiglass/Playback/Eq.swift', '''\
            func waitForDevice() {
                Thread.sleep(forTimeInterval: 0.05)
                _ = semaphore.wait(timeout: .now() + 30)
                try await sleep(delay)
            }
            ''')
        code, out = self.audit()
        self.assertEqual(code, 1, out)
        self.assertIn('Spotiglass/Playback/Eq.swift:2: [blocking-wait]', out)
        self.assertIn('Spotiglass/Playback/Eq.swift:3: [blocking-wait]', out)
        self.assertNotIn('Eq.swift:4:', out)  # an async sleep doesn't block

    def test_module_qualified_print_is_still_print(self):
        self.write('SpotiglassEQPrivilegedHelper/main.swift', 'Swift.print("helper started")\n')
        self.assertFinding('SpotiglassEQPrivilegedHelper/main.swift', 1, 'print-logging')

    def test_debug_block_only_counts_when_the_flag_is_required(self):
        self.write('SpotiglassEQDriver/Plugin.cpp', '''\
            #if defined(SPOTIGLASS_EQ_DEBUG) || defined(NDEBUG)
            fprintf(stderr, "StartIO\\n");
            #endif
            #if defined(SPOTIGLASS_EQ_DEBUG) && VERBOSE
            fprintf(stderr, "Mix\\n");
            #endif
            ''')
        code, out = self.audit()
        self.assertEqual(code, 1, out)
        self.assertIn('SpotiglassEQDriver/Plugin.cpp:2: [print-logging]', out)
        self.assertNotIn('Plugin.cpp:5:', out)

    def test_wait_wrapped_over_lines(self):
        self.write('Spotiglass/Playback/Eq.swift', '''\
            func waitForDevice() {
                _ = semaphore.wait(
                    timeout: .now() + 30
                )
            }
            ''')
        self.assertFinding('Spotiglass/Playback/Eq.swift', 2, 'blocking-wait')

    def test_catch_pattern_wrapped_over_lines(self):
        self.write('Spotiglass/Services/Client.swift', '''\
            func a() {
                do { try x() } catch let error as NSError
                    where error.code == 7 {}
            }
            ''')
        self.assertFinding('Spotiglass/Services/Client.swift', 2, 'catch-drops-error')

    def test_an_injected_log_closure_is_logging(self):
        # AppBundleMigration logs through its `log: (String) -> Void` parameter.
        self.write('Spotiglass/Infrastructure/AppBundleMigration.swift', '''\
            func migrate() {
                do { try move() } catch {
                    log("Wax bundle rename deferred: \\(error)")
                }
            }
            ''')
        self.assertClean()

    def test_driver_print_wrapped_over_lines(self):
        self.write('SpotiglassEQDriver/Plugin.cpp', '''\
            static void f() {
                fprintf(
                    stderr, "StartIO\\n");
            }
            ''')
        self.assertFinding('SpotiglassEQDriver/Plugin.cpp', 2, 'print-logging')

    def test_module_qualified_sleep_and_status_drop(self):
        self.write('Spotiglass/Playback/Eq.swift', '''\
            func settle() {
                Darwin.usleep(50_000)
                _ = CoreAudio.AudioObjectSetPropertyData(id, &address, 0, nil, size, &value)
            }
            ''')
        code, out = self.audit()
        self.assertEqual(code, 1, out)
        self.assertIn('Spotiglass/Playback/Eq.swift:2: [blocking-wait]', out)
        self.assertIn('Spotiglass/Playback/Eq.swift:3: [ignored-status]', out)

    def test_catch_pattern_wrapped_over_many_lines(self):
        self.write('Spotiglass/Services/Client.swift', '''\
            func a() {
                do { try x() } catch let error as NSError
                    where error.domain == NSCocoaErrorDomain
                        && error.code == 7
                        && retries > 0
                        && !cancelled {
                    return
                }
            }
            ''')
        self.assertFinding('Spotiglass/Services/Client.swift', 2, 'catch-drops-error')

    def test_logging_a_nested_cleanup_error_does_not_cover_the_outer_one(self):
        self.write('Spotiglass/Persistence/Store.swift', '''\
            func save() {
                do { try write() } catch {
                    do { try removeTemporaryFile() } catch {
                        SpotiglassLog.error(.persistence, "cleanup failed: \\(SpotiglassLog.describe(error))")
                    }
                }
            }
            ''')
        code, out = self.audit()
        self.assertEqual(code, 1, out)
        self.assertIn('Spotiglass/Persistence/Store.swift:2: [catch-drops-error]', out)
        self.assertNotIn('Store.swift:3:', out)

    def test_core_audio_call_as_a_whole_statement_drops_its_status(self):
        # Deleting the (void) from the driver's AudioObjectSetPropertyData must not
        # count as fixing it.
        self.write('SpotiglassEQDriver/EQRouter.cpp', '''\
            static void stop(Router* router) {
                if (router->started)
                    AudioDeviceStop(router->device, router->ioProc);
                AudioObjectSetPropertyData(
                    target, &addr, 0, nullptr, sizeof(want), &want);
                OSStatus status =
                    AudioDeviceStart(router->device, router->ioProc);
                if (AudioDeviceStop(router->device, router->ioProc) != noErr) { log(); }
                WriteRouterStatus("ready", uid, 0);
            }
            ''')
        code, out = self.audit()
        self.assertEqual(code, 1, out)
        self.assertIn('SpotiglassEQDriver/EQRouter.cpp:3: [ignored-status]', out)
        self.assertIn('SpotiglassEQDriver/EQRouter.cpp:4: [ignored-status]', out)
        for line in (7, 8, 9):
            self.assertNotIn('EQRouter.cpp:%d:' % line, out)

    def test_formatting_the_error_is_not_logging_it(self):
        # SpotiglassLog.describe(error) only builds a string; a catch that puts it
        # on screen still drops the error.
        self.write('Spotiglass/Settings/SettingsView.swift', '''\
            func save() {
                do { try store.save() } catch {
                    message = SpotiglassLog.describe(error)
                }
            }
            ''')
        self.assertFinding('Spotiglass/Settings/SettingsView.swift', 2, 'catch-drops-error')

    def test_the_helper_and_the_log_file_log_with_their_own_loggers(self):
        # The privileged helper logs with helperLog and the log file sink with
        # diagnostics (both os.Logger), as in their real catches on main.
        self.write('SpotiglassEQPrivilegedHelper/main.swift', '''\
            func clean() {
                do { try fileManager.removeItem(at: temporaryURL) } catch {
                    helperLog.error("Could not remove the temporary copy: \\(String(describing: error), privacy: .public)")
                }
            }
            ''')
        self.write('Spotiglass/Infrastructure/SpotiglassLog.swift', '''\
            func rotate() {
                do { try moveItem(url, earlierURL) } catch {
                    diagnostics.error("Could not move the log aside (\\(String(describing: error), privacy: .public))")
                }
            }
            ''')
        self.assertClean()

    def test_localized_description_shown_but_fine_inside_a_log_call(self):
        self.write('Spotiglass/Settings/SpotiglassSettingsStore.swift', '''\
            func save() {
                SpotiglassLog.error(
                    .settings,
                    "Could not save: \\(error.localizedDescription)"
                )
                lastError = error.localizedDescription
            }
            ''')
        code, out = self.audit()
        self.assertEqual(code, 1, out)
        self.assertIn('SpotiglassSettingsStore.swift:6: [localized-text]', out)
        self.assertNotIn('SpotiglassSettingsStore.swift:4:', out)

    def test_ignored_core_audio_status(self):
        self.write('SpotiglassEQDriver/SpotiglassEQPlugin.cpp', '''\
            static void sync() {
                (void)AudioObjectSetPropertyData(
                    target, &addr, 0, nullptr, sizeof(want), &want
                );
                (void)fmt;
            }
            ''')
        self.assertFinding('SpotiglassEQDriver/SpotiglassEQPlugin.cpp', 2, 'ignored-status')
        self.write('Spotiglass/Playback/Output.swift', '_ = AudioObjectSetPropertyData(id, &address, 0, nil, size, &value)\n')
        self.assertFinding('Spotiglass/Playback/Output.swift', 1, 'ignored-status')


class Baseline(Fixture):
    SITE = '''\
        func load() {
            pinned = (try? cache.loadPinnedItems()) ?? []
        }
        '''

    def baseline(self):
        return json.loads((self.root / BASELINE).read_text())

    def test_known_site_passes_but_a_new_copy_does_not(self):
        self.write('Spotiglass/Pinning/PinStore.swift', self.SITE)
        self.audit('--write-full-baseline')
        self.assertClean()
        self.write('Spotiglass/Pinning/PinStore.swift', '''\
            func load() {
                pinned = (try? cache.loadPinnedItems()) ?? []
            }
            func reload() {
                pinned = (try? cache.loadPinnedItems()) ?? []
            }
            ''')
        self.assertFinding('Spotiglass/Pinning/PinStore.swift', 5, 'try-reason')

    def test_baseline_entry_for_another_file_does_not_cover_this_one(self):
        self.write('Spotiglass/Pinning/PinStore.swift', self.SITE)
        self.audit('--write-full-baseline')
        self.write('Spotiglass/Pinning/OtherStore.swift', self.SITE)
        self.assertFinding('Spotiglass/Pinning/OtherStore.swift', 2, 'try-reason')

    def test_fixed_site_left_in_the_baseline_fails_until_removed(self):
        self.write('Spotiglass/Pinning/PinStore.swift', self.SITE)
        self.audit('--write-full-baseline')
        self.write('Spotiglass/Pinning/PinStore.swift', '''\
            func load() throws {
                pinned = try cache.loadPinnedItems()
            }
            ''')
        code, out = self.audit()
        self.assertEqual(code, 1, out)
        self.assertIn('baseline entry no longer matches anything', out)
        code, out = self.audit('--update-baseline')
        self.assertEqual(code, 0, out)
        self.assertEqual(self.baseline(), [])

    def test_update_baseline_never_adds_a_site(self):
        self.write('Spotiglass/Pinning/PinStore.swift', self.SITE)
        code, out = self.audit('--update-baseline')
        self.assertEqual(code, 1, out)
        self.assertEqual(self.baseline(), [])

    def test_moving_code_around_does_not_matter(self):
        self.write('Spotiglass/Pinning/PinStore.swift', self.SITE)
        self.audit('--write-full-baseline')
        self.write('Spotiglass/Pinning/PinStore.swift', '\n\n\n// Pins.\n' + textwrap.dedent(self.SITE))
        self.assertClean()

    def test_no_growth_from_a_git_ref(self):
        git = ['git', '-C', str(self.root), '-c', 'user.name=t', '-c', 'user.email=t@t']
        subprocess.run(git + ['init', '-q'], check=True)
        subprocess.run(git + ['add', '-A'], check=True)
        subprocess.run(git + ['commit', '-qm', 'base'], check=True)
        # Someone silences a new site by adding it to the baseline by hand.
        self.write('Spotiglass/Pinning/PinStore.swift', self.SITE)
        self.audit('--write-full-baseline')
        code, out = self.audit()
        self.assertEqual(code, 0, out)
        code, out = self.audit('--no-growth-from', 'HEAD')
        self.assertEqual(code, 1, out)
        self.assertIn('added to the baseline', out)

    def test_no_growth_from_a_ref_that_does_not_exist_fails(self):
        # A broken fetch in CI must not switch the check off.
        git = ['git', '-C', str(self.root), '-c', 'user.name=t', '-c', 'user.email=t@t']
        subprocess.run(git + ['init', '-q'], check=True)
        subprocess.run(git + ['commit', '-q', '--allow-empty', '-m', 'base'], check=True)
        code, out = self.audit('--no-growth-from', 'no-such-ref')
        self.assertEqual(code, 1, out)
        self.assertIn('no-such-ref is not a commit', out)

    def test_no_growth_from_a_commit_without_a_baseline_yet_passes(self):
        # The change that adds the audit compares with a base that has no baseline.
        git = ['git', '-C', str(self.root), '-c', 'user.name=t', '-c', 'user.email=t@t']
        subprocess.run(git + ['init', '-q'], check=True)
        subprocess.run(git + ['commit', '-q', '--allow-empty', '-m', 'base'], check=True)
        code, out = self.audit('--no-growth-from', 'HEAD')
        self.assertEqual(code, 0, out)


class RealRepository(unittest.TestCase):
    def test_main_matches_its_baseline(self):
        r = subprocess.run([sys.executable, str(AUDIT), '--root', str(REPO)], capture_output=True, text=True)
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)


class MicAuditCoversTheDriver(unittest.TestCase):
    def setUp(self):
        self.root = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, self.root)
        for d in ('Spotiglass', 'SpotiglassTests'):
            (self.root / d).mkdir()
        shutil.copytree(REPO / 'SpotiglassEQDriver', self.root / 'SpotiglassEQDriver',
                        ignore=shutil.ignore_patterns('build', '*.o'))

    def run_audit(self):
        r = subprocess.run(['bash', str(MIC_AUDIT)], cwd=self.root, capture_output=True, text=True)
        return r.returncode, r.stdout + r.stderr

    def test_reviewed_scope_checks_pass(self):
        code, out = self.run_audit()
        self.assertEqual(code, 0, out)

    def test_new_input_use_in_the_driver_fails(self):
        router = self.root / 'SpotiglassEQDriver' / 'EQRouter.cpp'
        router.write_text(router.read_text() + '\nstatic AudioObjectPropertyScope s = kAudioObjectPropertyScopeInput;\n')
        code, out = self.run_audit()
        self.assertEqual(code, 1, out)
        self.assertIn('SpotiglassEQDriver/EQRouter.cpp', out)

    def test_changing_an_allowlisted_line_needs_a_new_review(self):
        plugin = self.root / 'SpotiglassEQDriver' / 'SpotiglassEQPlugin.cpp'
        text = plugin.read_text()
        changed = text.replace('if (address->mScope == kAudioObjectPropertyScopeInput) {',
                               'if (address->mScope == kAudioObjectPropertyScopeInput || wantsInput) {')
        self.assertNotEqual(text, changed)
        plugin.write_text(changed)
        code, out = self.run_audit()
        self.assertEqual(code, 1, out)


if __name__ == '__main__':
    unittest.main()
