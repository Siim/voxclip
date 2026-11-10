#!/usr/bin/env python3
"""Run a test command; when it hangs, save the stacks of its processes and end it.

    python3 scripts/test-watchdog.py --label media -- swift test --jobs 2 --filter VoxClipMediaTests

The command's stdout and stderr pass through unchanged, and a run that ends on its own exits with the
command's exit code. A run counts as hung when, for --idle-seconds (default 6 minutes), it printed nothing
AND its processes used almost no CPU (a deadlocked cooperative pool or an unanswered system-service await). A
test may compute silently for many minutes (the caption goldens render 519 s with no output, and the test
process's stdout is block-buffered, so passing CI runs go quiet for up to 13 min), so silence alone counts only
after --silent-seconds (default 20 minutes), which catches a spinning hang.

On a hang, before ending the run, it writes to --stacks-dir:
  - process-tree.txt: the command's process tree with each process's CPU time;
  - sample-<pid>-<name>.txt: `sample <pid> 5` of each process (`sudo -n sample`, then `sudo -n spindump`, when a
    plain `sample` can't attach);
  - concurrency-<pid>-<name>.txt: `swift-inspect dump-concurrency <pid>` (Swift tasks and actors, which a thread
    sample doesn't show), when swift-inspect exists and may attach;
  - SUMMARY.txt: why it fired and what each tool reported.
It also asks each process to flush its stdout through lldb (only where attaching can't pop up an authorization
dialog), so the log ends at the real last lines instead of at the last full buffer. Then it ends the process
tree (SIGTERM, then SIGKILL) and exits with 124.
"""

import argparse
import os
import re
import shutil
import signal
import subprocess
import sys
import threading
import time

HUNG_EXIT = 124


def parse_cpu(text):
    """`ps -o time` reads [days-][hours:]minutes:seconds.hundredths."""
    days = 0
    if "-" in text:
        day_text, text = text.split("-", 1)
        days = int(day_text)
    seconds = 0.0
    for part in text.split(":"):
        seconds = seconds * 60 + float(part)
    return days * 86400 + seconds


def process_table():
    """{pid: (ppid, cpu seconds, command)} for every process."""
    out = subprocess.run(
        ["/bin/ps", "-A", "-o", "pid=,ppid=,time=,command="],
        stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, universal_newlines=True, check=False,
    ).stdout
    table = {}
    for line in out.splitlines():
        fields = line.split(None, 3)
        if len(fields) < 3:
            continue
        try:
            table[int(fields[0])] = (int(fields[1]), parse_cpu(fields[2]), fields[3] if len(fields) > 3 else "")
        except ValueError:
            continue
    return table


def descendants(root, table):
    """The root and every process below it, parents first."""
    children = {}
    for pid, (ppid, _, _) in table.items():
        children.setdefault(ppid, []).append(pid)
    order, queue = [], [root]
    while queue:
        pid = queue.pop(0)
        if pid in table:
            order.append(pid)
        queue.extend(sorted(children.get(pid, [])))
    return order


def is_busy(previous, current, floor):
    """A new process, or the tree's processes together used at least `floor` CPU seconds since the last poll."""
    if any(pid not in previous for pid in current):
        return True
    used = sum(max(0.0, current[pid] - previous[pid]) for pid in current)
    return used >= floor


def verdict(silent, since_busy, args):
    """Why the run counts as hung, or None."""
    idle = min(silent, since_busy)
    if idle >= args.idle_seconds:
        return "no output and under %.2f cores of CPU for %d s" % (args.idle_cpu_share, idle)
    if silent >= args.silent_seconds:
        return "no output for %d s (its processes were still using CPU)" % silent
    return None


def short_name(command):
    name = os.path.basename(command.split(" ", 1)[0]) or "process"
    return re.sub(r"[^A-Za-z0-9._-]", "_", name)[:40]


def run_tool(argv, timeout):
    """(ok, combined output) of a diagnostic tool, never raising."""
    try:
        done = subprocess.run(
            argv, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, stdin=subprocess.DEVNULL,
            universal_newlines=True, timeout=timeout, check=False,
        )
        return done.returncode == 0, done.stdout
    except subprocess.TimeoutExpired as error:
        return False, "timed out after %d s\n%s" % (timeout, error.output or "")
    except OSError as error:
        return False, str(error)


def sudo_works():
    if os.environ.get("VOXCLIP_WATCHDOG_NO_SUDO") == "1":
        return False
    return shutil.which("sudo") is not None and run_tool(["sudo", "-n", "true"], 10)[0]


def attach_is_silent():
    """lldb and swift-inspect may attach without an authorization dialog (CI runners, or developer mode on)."""
    if os.environ.get("VOXCLIP_WATCHDOG_NO_ATTACH") == "1":
        return False
    ok, out = run_tool(["/usr/sbin/DevToolsSecurity", "-status"], 10)
    return (ok and "enabled" in out) or sudo_works()


class Output:
    """Copies one pipe to one of our streams, byte for byte, and records when it last saw output."""

    def __init__(self, pipe, sink, clock):
        self.pipe, self.sink, self.clock = pipe, sink, clock
        self.thread = threading.Thread(target=self._pump, daemon=True)
        self.thread.start()

    def _pump(self):
        fd = self.pipe.fileno()
        while True:
            try:
                chunk = os.read(fd, 65536)
            except OSError:
                break
            if not chunk:
                break
            self.clock.touch()
            self.sink.write(chunk)
            self.sink.flush()


class Clock:
    def __init__(self):
        self.lock = threading.Lock()
        self.last = time.monotonic()

    def touch(self):
        with self.lock:
            self.last = time.monotonic()

    def silent_for(self, now):
        with self.lock:
            return now - self.last


def message(text):
    """One line to stderr, plus a GitHub annotation on a runner."""
    sys.stdout.flush()
    sys.stderr.write("test-watchdog: %s\n" % text)
    if os.environ.get("GITHUB_ACTIONS") == "true":
        sys.stderr.write("::error title=Test run hung::%s\n" % text)
    sys.stderr.flush()


def dump(root, table, stacks_dir, reason, sample_seconds):
    os.makedirs(stacks_dir, exist_ok=True)
    tree = descendants(root, table)
    with open(os.path.join(stacks_dir, "process-tree.txt"), "w") as handle:
        handle.write("pid\tppid\tcpu_s\tcommand\n")
        for pid in tree:
            ppid, cpu, command = table[pid]
            handle.write("%d\t%d\t%.2f\t%s\n" % (pid, ppid, cpu, command))

    use_sudo = sudo_works()
    attach = attach_is_silent()
    inspect = shutil.which("swift-inspect")
    lldb = shutil.which("lldb") or (run_tool(["xcrun", "--find", "lldb"], 20)[1].strip() or None)
    notes = ["%s" % reason, "processes: %d; sudo -n: %s; silent attach: %s" % (len(tree), use_sudo, attach)]

    for pid in tree:
        name = short_name(table[pid][2])
        path = os.path.join(stacks_dir, "sample-%d-%s.txt" % (pid, name))
        attempts = [["/usr/bin/sample", str(pid), str(sample_seconds), "-file", path]]
        if use_sudo:
            attempts.append(["sudo", "-n", "/usr/bin/sample", str(pid), str(sample_seconds), "-file", path])
            attempts.append(["sudo", "-n", "/usr/sbin/spindump", str(pid), str(sample_seconds), "-o", path])
        tried = []
        for argv in attempts:
            ok, out = run_tool(argv, sample_seconds + 90)
            if ok and os.path.exists(path) and os.path.getsize(path) > 0:
                if argv[0] == "sudo":
                    run_tool(["sudo", "-n", "chmod", "a+r", path], 10)
                tried.append("%s: ok" % " ".join(argv[:3]))
                break
            last = (out.strip().splitlines() or [""])[-1]
            tried.append("%s: failed: %s" % (" ".join(argv[:3]), last))
        else:
            with open(path, "w") as handle:
                handle.write("no stacks for pid %d (%s)\n%s\n" % (pid, table[pid][2], "\n".join(tried)))
        notes.append("pid %d %s: %s" % (pid, name, "; ".join(tried)))

        if attach and inspect:
            argv = [inspect, "dump-concurrency", str(pid)]
            if use_sudo:
                argv = ["sudo", "-n"] + argv
            ok, out = run_tool(argv, 120)
            with open(os.path.join(stacks_dir, "concurrency-%d-%s.txt" % (pid, name)), "w") as handle:
                handle.write(out)
            notes.append("pid %d swift-inspect dump-concurrency: %s" % (pid, "ok" if ok else "failed"))

    # Flush last: a hung test process holds its last lines in its stdout buffer, so the log would end a whole
    # buffer early. lldb's expression runs on the process's own threads; bound it so a held stdout lock can't
    # hang the watchdog too.
    if attach and lldb:
        for pid in tree:
            argv = [lldb, "--batch", "--no-lldbinit", "-p", str(pid),
                    "-o", "expression -l c --timeout 10000000 --unwind-on-error true -- (int)fflush((void *)0)",
                    "-o", "process detach"]
            if use_sudo:
                argv = ["sudo", "-n"] + argv
            ok, out = run_tool(argv, 90)
            notes.append("pid %d lldb fflush: %s" % (pid, "ok" if ok else "failed"))
    else:
        notes.append("lldb fflush skipped (attaching could ask for authorization here)")

    with open(os.path.join(stacks_dir, "SUMMARY.txt"), "w") as handle:
        handle.write("\n".join(notes) + "\n")
    return tree


def end_tree(child, pids, grace):
    for sig in (signal.SIGTERM, signal.SIGKILL):
        try:
            os.killpg(child.pid, sig)
        except OSError:
            pass
        for pid in pids:
            try:
                os.kill(pid, sig)
            except OSError:
                pass
        try:
            child.wait(timeout=grace)
            return
        except subprocess.TimeoutExpired:
            continue


def exit_code(returncode):
    return 128 - returncode if returncode < 0 else returncode


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--label", default="tests", help="names the stacks folder")
    parser.add_argument("--stacks-dir", help="default: $RUNNER_TEMP (or the temp folder)/voxclip-test-stacks/<label>")
    parser.add_argument("--idle-seconds", type=float, default=360.0, help="silent and idle this long counts as hung")
    parser.add_argument("--silent-seconds", type=float, default=1200.0, help="silent this long counts as hung")
    parser.add_argument("--idle-cpu-share", type=float, default=0.05,
                        help="below this many cores' CPU (summed over the tree) counts as idle")
    parser.add_argument("--poll-seconds", type=float, default=15.0)
    parser.add_argument("--sample-seconds", type=int, default=5)
    parser.add_argument("command", nargs=argparse.REMAINDER)
    args = parser.parse_args(argv)
    command = args.command[1:] if args.command[:1] == ["--"] else args.command
    if not command:
        parser.error("give the command after --")
    stacks_dir = args.stacks_dir or os.path.join(
        os.environ.get("RUNNER_TEMP") or os.environ.get("TMPDIR") or "/tmp", "voxclip-test-stacks", args.label)

    clock = Clock()
    child = subprocess.Popen(command, stdout=subprocess.PIPE, stderr=subprocess.PIPE, start_new_session=True)

    def forward(signum, _frame):
        try:
            os.killpg(child.pid, signum)
        except OSError:
            pass

    for signum in (signal.SIGTERM, signal.SIGINT, signal.SIGHUP):
        signal.signal(signum, forward)

    pumps = [Output(child.stdout, sys.stdout.buffer, clock), Output(child.stderr, sys.stderr.buffer, clock)]
    last_busy = time.monotonic()
    previous = {}
    hung = None
    while True:
        try:
            child.wait(timeout=args.poll_seconds)
            break
        except subprocess.TimeoutExpired:
            pass
        now = time.monotonic()
        table = process_table()
        tree = descendants(child.pid, table)
        cpu = {pid: table[pid][1] for pid in tree}
        if is_busy(previous, cpu, args.idle_cpu_share * args.poll_seconds):
            last_busy = now
        previous = cpu
        hung = verdict(clock.silent_for(now), now - last_busy, args)
        if hung:
            message("%s; saving stacks to %s" % (hung, stacks_dir))
            pids = dump(child.pid, table, stacks_dir, hung, args.sample_seconds)
            end_tree(child, pids, 15)
            break

    for pump in pumps:
        pump.thread.join(timeout=30)
    if hung:
        message("ended the hung run (%s). Stacks: %s (CI uploads it as the macos-swift-test-stacks artifact)."
                % (hung, stacks_dir))
        return HUNG_EXIT
    return exit_code(child.returncode)


if __name__ == "__main__":
    sys.exit(main())
