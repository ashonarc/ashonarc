"""Copy the ABI of each shipped contract from the forge artefacts into web/lib/abi.

Run after `forge build`. Keeps the web layer honest: no hand-typed ABI strings.
"""
import json, pathlib

ROOT = pathlib.Path(__file__).resolve().parent.parent
NAMES = ["LaunchFactory", "LaunchpadLens", "BondingCurve", "RedemptionVault", "LaunchToken"]

for name in NAMES:
    src = ROOT / "out" / f"{name}.sol" / f"{name}.json"
    abi = json.loads(src.read_text(encoding="utf-8"))["abi"]
    dst = ROOT / "web" / "lib" / "abi" / f"{name}.json"
    dst.write_text(json.dumps(abi, separators=(",", ":")) + "\n", encoding="utf-8")
    print(f"{name:16s} {len(abi):3d} entries -> {dst.relative_to(ROOT)}")
