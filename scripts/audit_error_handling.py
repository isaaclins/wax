#!/usr/bin/env python3
"""
Error-handling audit (#607): stops new silent failures from going in.

Rules (each finding prints as `path:line: [rule] message`):

  try-reason        `try?` needs a reason comment on the same line or the line
                    above: `// try?: best-effort cleanup, nothing depends on it`.
  catch-drops-error A `catch` block must log (SpotiglassLog.error/info/debug, the
                    helper's helperLog, or a log* helper) or
                    hand the error on (throw, resume(throwing:), .failure(...)).
                    An empty `catch {}` always fails. `catch is CancellationError`
                    is exempt: cancelling is not a failure.
  print-logging     No print(, debugPrint(, NSLog( in app or helper code, and no
                    printf / fprintf(stderr|stdout) / NSLog in the driver.
                    Driver code inside `#if defined(SPOTIGLASS_EQ_DEBUG)` (or
                    `#ifdef SPOTIGLASS_EQ_DEBUG`) is allowed.
  blocking-wait     No Thread.sleep, usleep( or a blocking .wait(...) on a
                    semaphore or group in Spotiglass/.
  localized-text    No `localizedDescription` in Spotiglass/ outside a
                    SpotiglassLog call: it is a raw system sentence, not text for
                    a listener.
  ignored-status    No `(void)` on a Core Audio call that returns an OSStatus in
                    the driver, and no `_ = Audio...(` in Swift.

Sites that existed when the audit went in are listed in
scripts/error-handling-baseline.json by file, rule and line text (not line
number, so moving code around doesn't break it). A finding that is not in the
baseline fails. A baseline entry that no longer matches anything also fails, so
fixing a site means deleting its entry (`--update-baseline` does that and never
adds entries). `--no-growth-from <git ref>` fails if the baseline has entries
or counts the baseline at that ref did not have.

Run from the repository root:  scripts/audit-error-handling.sh
"""
import argparse
import json
import re
import subprocess
import sys
from collections import Counter
from pathlib import Path

BASELINE_REL = 'scripts/error-handling-baseline.json'

APP_DIR = 'Spotiglass'
HELPER_DIR = 'SpotiglassEQPrivilegedHelper'
DRIVER_DIR = 'SpotiglassEQDriver'
DRIVER_EXCLUDE = ('SpotiglassEQDriver/tests/',)

C_SUFFIXES = ('.c', '.cpp', '.cc', '.h', '.hpp', '.m', '.mm')

MESSAGES = {
    'try-reason': 'try? without a reason; add `// try?: <why dropping the error is fine>` on this line or the line above',
    'catch-drops-error': 'catch block neither logs (SpotiglassLog) nor hands the error on (throw)',
    'print-logging': 'print/NSLog logging; use SpotiglassLog',
    'blocking-wait': 'blocking sleep or wait; the main thread must never block',
    'localized-text': 'localizedDescription outside a SpotiglassLog call; show a sentence written for the listener',
    'ignored-status': 'OSStatus from a Core Audio call is thrown away; check it and log on failure',
}


# ---------------------------------------------------------------------------
# Lexing: blank out comments and string text, keep line structure. Code inside
# Swift string interpolation `\( ... )` stays code, so `"\(error.localizedDescription)"`
# and `"\(try? x)"` are still seen.
# ---------------------------------------------------------------------------

def strip_swift(src):
    """Return (code, comments): two strings the same length as src.

    `code` has comments and string text replaced by spaces (newlines kept).
    `comments` has only the comment characters, everything else spaces.
    """
    n = len(src)
    code = list(src)
    comments = [c if c == '\n' else ' ' for c in src]
    i = 0
    # Stack of contexts. ('code', paren_depth) for interpolations;
    # ('str', hashes, multiline) for strings.
    stack = []

    def blank(a, b, keep_comment=False):
        for k in range(a, b):
            if src[k] != '\n':
                if keep_comment:
                    comments[k] = src[k]
                code[k] = ' '

    while i < n:
        top = stack[-1] if stack else None
        if top is None or top[0] == 'code':
            c = src[i]
            if src.startswith('//', i):
                j = src.find('\n', i)
                j = n if j == -1 else j
                blank(i, j, keep_comment=True)
                i = j
                continue
            if src.startswith('/*', i):
                depth, j = 1, i + 2
                while j < n and depth:
                    if src.startswith('/*', j):
                        depth, j = depth + 1, j + 2
                    elif src.startswith('*/', j):
                        depth, j = depth - 1, j + 2
                    else:
                        j += 1
                blank(i, j, keep_comment=True)
                i = j
                continue
            m = re.match(r'(#*)("""|")', src[i:i + 40])
            if m and (m.group(1) == '' or src[i] == '#'):
                hashes = len(m.group(1))
                multiline = m.group(2) == '"""'
                j = i + len(m.group(0))
                blank(i, j)
                stack.append(('str', hashes, multiline))
                i = j
                continue
            if top is not None:
                if c == '(':
                    stack[-1] = ('code', top[1] + 1)
                elif c == ')':
                    if top[1] == 0:
                        stack.pop()  # end of interpolation, back in the string
                        code[i] = ' '
                        i += 1
                        continue
                    stack[-1] = ('code', top[1] - 1)
            i += 1
            continue
        # Inside a string.
        _, hashes, multiline = top
        close = ('"""' if multiline else '"') + '#' * hashes
        esc = '\\' + '#' * hashes
        if src.startswith(esc + '(', i):
            blank(i, i + len(esc) + 1)
            stack.append(('code', 0))
            i += len(esc) + 1
            continue
        if src.startswith(esc, i) and hashes == 0:
            blank(i, min(n, i + 2))
            i += 2
            continue
        if src.startswith(close, i):
            blank(i, i + len(close))
            stack.pop()
            i += len(close)
            continue
        if src[i] == '\n' and not multiline:
            stack.pop()  # unterminated; don't swallow the file
            i += 1
            continue
        blank(i, i + 1)
        i += 1
    return ''.join(code), ''.join(comments)


def strip_c(src):
    """Blank out C/C++ comments, string and char literals (newlines kept)."""
    out = list(src)
    n, i = len(src), 0
    while i < n:
        if src.startswith('//', i):
            j = src.find('\n', i)
            j = n if j == -1 else j
        elif src.startswith('/*', i):
            j = src.find('*/', i + 2)
            j = n if j == -1 else j + 2
        elif src[i] in '"\'':
            q, j = src[i], i + 1
            while j < n and src[j] != q and src[j] != '\n':
                j += 2 if src[j] == '\\' else 1
            j = min(n, j + 1)
        else:
            i += 1
            continue
        for k in range(i, j):
            if out[k] != '\n':
                out[k] = ' '
        i = j
    return ''.join(out)


def line_of(text, offset):
    return text.count('\n', 0, offset) + 1


def matching(code, open_idx, open_ch, close_ch):
    depth = 0
    for k in range(open_idx, len(code)):
        if code[k] == open_ch:
            depth += 1
        elif code[k] == close_ch:
            depth -= 1
            if depth == 0:
                return k
    return len(code) - 1


# ---------------------------------------------------------------------------
# Rules
# ---------------------------------------------------------------------------

REASON = re.compile(r'//\s*try\?:\s*\S')


def rule_try_reason(code, comments, raw_lines):
    code_lines = code.split('\n')
    comment_lines = comments.split('\n')
    for idx, line in enumerate(code_lines):
        if not re.search(r'\btry\?', line):
            continue
        here = comment_lines[idx]
        above = comment_lines[idx - 1] if idx > 0 else ''
        above_is_comment = idx > 0 and code_lines[idx - 1].strip() == '' and above.strip() != ''
        if REASON.search(here) or (above_is_comment and REASON.search(above)):
            continue
        yield idx + 1


CATCH = re.compile(r'(?<![\w.])catch\b')
# The calls that write to the log: SpotiglassLog in the app, the privileged
# helper's own os.Logger (helperLog), and the log file sink's os.Logger
# (diagnostics), which can't log through itself. SpotiglassLog.describe(...)
# only formats an error into a string, so it is not logging.
LOG_FUNCS = r'(?:error|info|debug|notice|warning|fault|critical)'
LOGGERS = r'(?:SpotiglassLog|helperLog|diagnostics)'
LOG_CALL = re.compile(r'\b' + LOGGERS + r'\.' + LOG_FUNCS + r'\s*\(')

HANDS_ON = re.compile(
    LOG_CALL.pattern +           # logged
    r'|\blog[A-Z]\w*\s*\('       # a log helper (logRequestFailure(...))
    r'|\blog\s*\('                # an injected log closure (log: (String) -> Void)
    r'|\bthrow\b'                # rethrown or mapped
    r'|\bthrowing\s*:'           # continuation.resume(throwing:)
    r'|\.failure\s*\('           # handed on as a Result
)


def catch_blocks(code):
    """Yield (match, pattern, brace, end) for each `catch ... { ... }`."""
    for m in CATCH.finditer(code):
        brace = code.find('{', m.end())
        if brace == -1:
            continue
        pattern = code[m.end():brace]
        # A pattern may wrap (`catch let e as NSError\n where e.code == 7 {`), but
        # it never holds a statement or a closing brace; those mean this `catch`
        # isn't followed by its own block.
        if ';' in pattern or '}' in pattern:
            continue
        yield m, pattern, brace, matching(code, brace, '{', '}')


def without_nested_catches(body):
    """The body with the blocks of catches inside it blanked out: logging the
    error of a nested cleanup doesn't account for the outer error."""
    out = list(body)
    for _, _, brace, end in catch_blocks(body):
        for k in range(brace, end + 1):
            if out[k] != '\n':
                out[k] = ' '
    return ''.join(out)


def rule_catch(code):
    for m, pattern, brace, end in catch_blocks(code):
        if re.fullmatch(r'\s*(is|let\s+\w+\s+as)\s+CancellationError\s*', pattern):
            continue
        body = code[brace + 1:end]
        if body.strip() == '' or not HANDS_ON.search(without_nested_catches(body)):
            # Keyed by the catch line plus the first line of its body, so a
            # file's many `} catch {` lines stay apart in the baseline.
            first = next((l.strip() for l in body.split('\n') if l.strip()), '')
            yield line_of(code, m.start()), first


SWIFT_PRINT = re.compile(r'(?:(?<![\w.])|(?<=\bSwift\.)|(?<=\bFoundation\.))(print|debugPrint|NSLog)\s*\(')
C_PRINT = re.compile(r'(?<![\w.>])(printf|NSLog|puts)\s*\(|\bfprintf\s*\(\s*(stderr|stdout)\b')
# Only a condition that guarantees the flag: the flag alone, or the flag AND
# something else. `defined(SPOTIGLASS_EQ_DEBUG) || ...` can be true without it.
DEBUG_IF = re.compile(
    r'^\s*#\s*(?:if\s+defined(?:\s*\(\s*SPOTIGLASS_EQ_DEBUG\s*\)|\s+SPOTIGLASS_EQ_DEBUG\b)(?:\s*&&[^|]*)?'
    r'|ifdef\s+SPOTIGLASS_EQ_DEBUG)\s*$')


def rule_print_swift(code):
    for idx, line in enumerate(code.split('\n')):
        if SWIFT_PRINT.search(line):
            yield idx + 1


def rule_print_c(code):
    depth_stack = []  # True for a SPOTIGLASS_EQ_DEBUG block
    debug_lines = set()
    for idx, line in enumerate(code.split('\n')):
        s = line.strip()
        if re.match(r'#\s*if', s):
            depth_stack.append(bool(DEBUG_IF.match(line)))
        elif re.match(r'#\s*endif', s):
            if depth_stack:
                depth_stack.pop()
        elif re.match(r'#\s*(else|elif)', s) and depth_stack:
            depth_stack[-1] = False
        elif any(depth_stack):
            debug_lines.add(idx + 1)
    # Across lines: `fprintf(\n    stderr, ...)` is still printing.
    for m in C_PRINT.finditer(code):
        ln = line_of(code, m.start())
        if ln not in debug_lines:
            yield ln


BLOCKING = re.compile(
    r'\bThread\.sleep\b'
    r'|(?:(?<![\w.])|(?<=\bDarwin\.)|(?<=\bFoundation\.))usleep\s*\('
    r'|\.wait\s*\(\s*(\)|timeout\s*:|wallTimeout\s*:)'
)


def rule_blocking(code):
    # Across lines: `semaphore.wait(\n    timeout: ...)` is still a wait.
    for m in BLOCKING.finditer(code):
        yield line_of(code, m.start())




def rule_localized(code):
    inside = [False] * len(code)
    for m in LOG_CALL.finditer(code):
        open_idx = m.end() - 1
        end = matching(code, open_idx, '(', ')')
        for k in range(open_idx, end + 1):
            inside[k] = True
    for m in re.finditer(r'\blocalizedDescription\b', code):
        if not inside[m.start()]:
            yield line_of(code, m.start())


AUDIO_API = r'Audio(?:Object|Hardware|Device|Converter|Unit|Queue|File|Component)\w*'
C_STATUS_CALL = (r'(?:[\w.>\-]*(?:->|\.))?'
                 r'(?:' + AUDIO_API + r'|PropertiesChanged|RequestDeviceConfigurationChange|WriteMix|\w+Status)\s*\(')
C_STATUS_VOID = re.compile(r'\(\s*void\s*\)\s*' + C_STATUS_CALL)
# A call that is a whole statement: nothing looks at what it returns. Only the
# Core Audio API and the host's callbacks here; the driver's own `...Status`
# helpers return void.
C_STATUS_STATEMENT = re.compile(
    r'^[ \t]*(?:[\w.>\-]*(?:->|\.))?(?:' + AUDIO_API +
    r'|PropertiesChanged|RequestDeviceConfigurationChange|WriteMix)\s*\(', re.M)
SWIFT_STATUS_DROP = re.compile(r'(?<![\w.])_\s*=\s*(?:try\s+)?(?:\w+\.)?(' + AUDIO_API + r')\s*\(')


def starts_statement(code, start):
    """True when the code before `start` ends a statement or opens a block."""
    before = code[:start].rstrip()
    if not before:
        return True
    if before[-1] in ';{}:':
        return True
    if before[-1] == ')':
        # `if (...) Call(...)`: a statement after a condition, not a continued
        # argument list like `foo(a,\n b)` (that line ends in `,`).
        return True
    return bool(re.search(r'\belse$', before))


def rule_status_c(code):
    for m in C_STATUS_VOID.finditer(code):
        yield line_of(code, m.start())
    for m in C_STATUS_STATEMENT.finditer(code):
        at = m.start() + len(m.group(0)) - len(m.group(0).lstrip())
        if starts_statement(code, at):
            yield line_of(code, at)


def rule_status_swift(code):
    for m in SWIFT_STATUS_DROP.finditer(code):
        yield line_of(code, m.start())


# ---------------------------------------------------------------------------
# Scanning
# ---------------------------------------------------------------------------

def files_under(root, rel, suffixes):
    base = root / rel
    if not base.is_dir():
        return []
    out = []
    for p in sorted(base.rglob('*')):
        if p.is_file() and p.suffix in suffixes:
            relp = p.relative_to(root).as_posix()
            if any(relp.startswith(x) for x in DRIVER_EXCLUDE):
                continue
            out.append((relp, p))
    return out


def scan(root):
    """Return a list of (rule, file, line_number, line_text)."""
    findings = []

    def add(rule, relp, raw_lines, lines):
        # A rule yields a line number, or (line number, code that follows) when
        # the line alone is too common to tell sites apart.
        done = set()
        for item in lines:
            ln, extra = item if isinstance(item, tuple) else (item, '')
            if ln in done:
                continue
            done.add(ln)
            text = raw_lines[ln - 1] if ln - 1 < len(raw_lines) else ''
            if extra:
                text = text.strip() + ' … ' + extra
            findings.append((rule, relp, ln, text))

    for top in (APP_DIR, HELPER_DIR):
        for relp, path in files_under(root, top, ('.swift',)):
            src = path.read_text(encoding='utf-8', errors='replace')
            raw_lines = src.split('\n')
            code, comments = strip_swift(src)
            add('try-reason', relp, raw_lines, rule_try_reason(code, comments, raw_lines))
            add('catch-drops-error', relp, raw_lines, rule_catch(code))
            add('print-logging', relp, raw_lines, rule_print_swift(code))
            add('ignored-status', relp, raw_lines, rule_status_swift(code))
            if top == APP_DIR:
                add('blocking-wait', relp, raw_lines, rule_blocking(code))
                add('localized-text', relp, raw_lines, rule_localized(code))

    for relp, path in files_under(root, DRIVER_DIR, C_SUFFIXES):
        src = path.read_text(encoding='utf-8', errors='replace')
        raw_lines = src.split('\n')
        code = strip_c(src)
        add('print-logging', relp, raw_lines, rule_print_c(code))
        add('ignored-status', relp, raw_lines, rule_status_c(code))

    return findings


def key(rule, relp, text):
    return (rule, relp, ' '.join(text.split()))


def load_baseline_text(text):
    data = json.loads(text)
    counts = Counter()
    for e in data:
        counts[(e['rule'], e['file'], ' '.join(e['code'].split()))] += int(e.get('count', 1))
    return counts


def dump_baseline(counts):
    entries = []
    for (rule, relp, code), cnt in sorted(counts.items(), key=lambda kv: (kv[0][1], kv[0][0], kv[0][2])):
        if cnt <= 0:
            continue
        e = {'file': relp, 'rule': rule, 'code': code}
        if cnt > 1:
            e['count'] = cnt
        entries.append(e)
    return json.dumps(entries, indent=2, ensure_ascii=False) + '\n'


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.split('\n\n')[0])
    ap.add_argument('--root', default='.', help='repository root (default: current directory)')
    ap.add_argument('--baseline', help='baseline file (default: <root>/%s)' % BASELINE_REL)
    ap.add_argument('--update-baseline', action='store_true',
                    help='remove baseline entries that no longer match; never adds any')
    ap.add_argument('--write-full-baseline', action='store_true', help=argparse.SUPPRESS)
    ap.add_argument('--no-growth-from', metavar='GIT_REF',
                    help='fail if the baseline lists anything the baseline at GIT_REF did not')
    args = ap.parse_args(argv)

    root = Path(args.root).resolve()
    baseline_path = Path(args.baseline) if args.baseline else root / BASELINE_REL

    findings = scan(root)
    found = Counter(key(r, f, t) for r, f, _, t in findings)

    if args.write_full_baseline:
        baseline_path.write_text(dump_baseline(found))
        print('Wrote %d entries to %s' % (sum(found.values()), baseline_path))
        return 0

    baseline = load_baseline_text(baseline_path.read_text()) if baseline_path.exists() else Counter()

    if args.update_baseline:
        pruned = Counter({k: min(v, found[k]) for k, v in baseline.items()})
        removed = sum(baseline.values()) - sum(pruned.values())
        baseline_path.write_text(dump_baseline(pruned))
        print('Removed %d fixed site(s) from %s' % (removed, baseline_path.name))
        baseline = pruned

    failures = 0

    # New sites: more occurrences of a (rule, file, line text) than the baseline allows.
    # Report the last ones in the file, which are the likeliest to be new.
    by_key = {}
    for rule, relp, ln, text in findings:
        by_key.setdefault(key(rule, relp, text), []).append(ln)
    new = []
    for k, lines in by_key.items():
        extra = len(lines) - baseline.get(k, 0)
        if extra > 0:
            new.extend((k[1], ln, k[0]) for ln in lines[-extra:])
    for relp, ln, rule in sorted(new):
        print('%s:%d: [%s] %s' % (relp, ln, rule, MESSAGES[rule]))
        failures += 1

    # Stale baseline entries: the site was fixed or changed.
    for k, cnt in sorted(baseline.items()):
        if found[k] < cnt:
            rule, relp, code = k
            print('%s: [%s] baseline entry no longer matches anything, remove it '
                  '(scripts/audit-error-handling.sh --update-baseline): %s' % (relp, rule, code))
            failures += 1

    if args.no_growth_from:
        ref = args.no_growth_from
        resolves = subprocess.run(['git', 'rev-parse', '--verify', '--quiet', ref + '^{commit}'],
                                  cwd=root, capture_output=True).returncode == 0
        if not resolves:
            print('--no-growth-from: %s is not a commit here, so the baseline cannot be compared' % ref)
            failures += 1
            old_text = None
        else:
            shown = subprocess.run(['git', 'show', '%s:%s' % (ref, BASELINE_REL)],
                                   cwd=root, capture_output=True, text=True)
            # No baseline at that commit yet (the change that adds the audit):
            # nothing to compare with.
            old_text = shown.stdout if shown.returncode == 0 else None
        if old_text is not None:
            old = load_baseline_text(old_text)
            for k, cnt in sorted(baseline.items()):
                if cnt > old.get(k, 0):
                    rule, relp, code = k
                    print('%s: [%s] added to the baseline; fix the site instead: %s' % (relp, rule, code))
                    failures += 1

    if failures:
        print()
        print('FAIL: %d error-handling finding(s). See CONTRIBUTING.md, "Errors".' % failures)
        return 1
    print('OK: no new silent failures (%d known site(s) in the baseline)' % sum(baseline.values()))
    return 0


if __name__ == '__main__':
    sys.exit(main())
