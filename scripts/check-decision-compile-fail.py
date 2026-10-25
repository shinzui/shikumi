#!/usr/bin/env python3
"""Check decision-type diagnostics using the built library in cabal's environment.

Run from the repository root inside nix develop, after cabal build shikumi.
"""

from pathlib import Path
import subprocess


fixtures = {
    "FreeFormDecision": ("Decision output field", "summary"),
    "TooFewScoreLevels": ("Score requires 2 to 10 levels",),
    "TooManyScoreLevels": ("Score requires 2 to 10 levels",),
}

for name, expected in fixtures.items():
    source = Path("shikumi/test/compile-fail") / f"{name}.hs"
    result = subprocess.run(
        ["cabal", "exec", "--", "ghc", "-fno-code", "-XGHC2024",
         "-package", "shikumi", str(source)],
        capture_output=True, text=True, check=False,
    )
    output = result.stdout + result.stderr
    if result.returncode == 0 or not all(message in output for message in expected):
        raise SystemExit(f"Unexpected compiler result for {name}:\n{output}")
    print(f"{name}: rejected with expected diagnostic")
