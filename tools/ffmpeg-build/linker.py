#!/usr/bin/env python3
"""Keep one PE link map per DLL, including statically linked runtime objects."""

import os
from pathlib import Path
import subprocess
import sys


arguments = sys.argv[1:]
if "-shared" in arguments and "-o" in arguments:
    output = arguments[arguments.index("-o") + 1]
    arguments.extend(["-Wl,-Map," + output + ".map", "-Wl,--verbose"])
    compiler = os.environ["VOXCLIP_LINKER"]
    result = subprocess.run([compiler, *arguments], stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    Path(output + ".link.txt").write_bytes(result.stdout)
    map_path = Path(output + ".map")
    if map_path.exists():
        with map_path.open("ab") as report:
            report.write(b"\nLLD archive extraction evidence:\n")
            report.write(result.stdout)
    if result.returncode:
        sys.stderr.buffer.write(b"\n".join(result.stdout.splitlines()[-60:]) + b"\n")
    sys.exit(result.returncode)
compiler = os.environ["VOXCLIP_LINKER"]
os.execv(compiler, [compiler, *arguments])
