"""Scan repository source with Semgrep and report findings without source excerpts."""

import argparse
import json
import os
from pathlib import Path
import plistlib
import subprocess
import sys
import tempfile
from xml.parsers.expat import ExpatError


ROOT = Path(__file__).resolve().parents[1]
SCAN_ROOTS = ("CardLedger/", "owner-service/", "security/", ".github/workflows/")
PLIST_EXTENSIONS = {".plist", ".entitlements"}
EXTENSIONS = {".swift", ".ts", ".js", ".py", ".sh", ".yml", ".yaml", ".tf"} | PLIST_EXTENSIONS


def repository_sources():
    inventory = subprocess.run(
        ["git", "ls-files", "-z", "--cached", "--others", "--exclude-standard", "--", *SCAN_ROOTS],
        cwd=ROOT, check=True, capture_output=True,
    )
    sources = []
    for name in sorted(set(os.fsdecode(inventory.stdout).split("\0"))):
        path = ROOT / name
        if path.suffix in EXTENSIONS and path.is_file() and path.resolve() == path:
            sources.append(name)
    return sources


def plist_findings(sources):
    findings = []
    for name in sources:
        path = ROOT / name
        with path.open("rb") as source:
            config = plistlib.load(source)
        if path.suffix == ".plist" and config.get("NSAppTransportSecurity", {}).get("NSAllowsArbitraryLoads") is True:
            findings.append((name, "card-ledger.ats-global-exception"))
        if path.suffix == ".entitlements" and "webcredentials:*" in config.get("com.apple.developer.associated-domains", []):
            findings.append((name, "card-ledger.passkey-wildcard-domain"))
    return findings


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--offline", action="store_true", help="Only run the checked-in rules")
    args = parser.parse_args()
    try:
        sources = repository_sources()
        if not sources:
            raise ValueError("empty source inventory")
        plists = [name for name in sources if Path(name).suffix in PLIST_EXTENSIONS]
        code = [name for name in sources if Path(name).suffix not in PLIST_EXTENSIONS]
        if not code:
            raise ValueError("empty code inventory")
        configurations = plist_findings(plists)
        command = ["semgrep", "scan", "--config", "security/semgrep.yml", "--metrics=off",
                   "--disable-version-check", "--json", "--quiet", "--error"]
        if not args.offline:
            command.extend(["--config", "p/default"])
        env = os.environ.copy()
        env.pop("SEMGREP_APP_TOKEN", None)
        if sys.platform == "darwin" and Path("/etc/ssl/cert.pem").is_file():
            env.setdefault("SSL_CERT_FILE", "/etc/ssl/cert.pem")
        with tempfile.TemporaryDirectory(prefix="card-ledger-semgrep-") as directory:
            env["SEMGREP_SETTINGS_FILE"] = str(Path(directory) / "settings.yml")
            env["SEMGREP_LOG_FILE"] = str(Path(directory) / "scan.log")
            result = subprocess.run(command + ["--", *code], cwd=ROOT, env=env,
                                    capture_output=True, text=True, timeout=300)
        if result.returncode not in (0, 1):
            print(f"Source scan did not complete (Semgrep exit {result.returncode}).", file=sys.stderr)
            return 2
        report = json.loads(result.stdout)
        findings = report["results"]
        scanned = report["paths"]["scanned"]
        print(f"Source scan checked {len(scanned) + len(plists)} files and reported {len(findings) + len(configurations)} findings.")
        for finding in findings:
            print(f"{finding['path']!r}:{finding['start']['line']} {finding['check_id']!r}")
        for path, rule in configurations:
            print(f"{path!r} {rule!r}")
        errors = report["errors"]
        if errors or not scanned:
            for error in errors:
                kind = error.get("type", "unknown")
                if isinstance(kind, list):
                    kind = kind[0]
                print(f"Scanner issue {kind!r} in {error.get('path', 'configuration')!r}.", file=sys.stderr)
            return 2
        return int(bool(findings or configurations))
    except FileNotFoundError:
        print("Install Git and Semgrep to run the source scan.", file=sys.stderr)
    except (subprocess.SubprocessError, OSError, ValueError, KeyError, TypeError, AttributeError,
            plistlib.InvalidFileException, ExpatError):
        print("Source scan could not produce a valid report.", file=sys.stderr)
    return 2


if __name__ == "__main__":
    raise SystemExit(main())
