"""Check the iOS project's resolved Swift dependencies against OSV."""

import json
from pathlib import Path
import re
import sys
from urllib.request import Request, urlopen


LOCKFILE = (Path(__file__).resolve().parents[1] / "CardLedger/CardLedger.xcodeproj"
            / "project.xcworkspace/xcshareddata/swiftpm/Package.resolved")


def read_queries(lockfile):
    pins = json.loads(lockfile.read_text(encoding="utf-8"))["pins"]
    if not pins:
        raise ValueError("no Swift packages found")
    queries = []
    for pin in pins:
        location = pin["location"]
        if not re.fullmatch(r"https://github\.com/[\w.-]+/[\w.-]+/?", location, re.ASCII):
            raise ValueError("unsupported Swift package origin")
        package = location.removeprefix("https://").rstrip("/").removesuffix(".git").lower()
        revision = pin["state"]["revision"]
        if not re.fullmatch(r"[0-9a-f]{40}", revision):
            raise ValueError("invalid Swift package revision")
        version = pin["state"].get("version")
        label = f"{package}@{version or revision[:12]}"
        queries.append((label, {"commit": revision}))
        if version:
            if not re.fullmatch(r"[0-9A-Za-z.+-]+", version):
                raise ValueError("invalid Swift package version")
            queries.append((label, {"package": {"ecosystem": "SwiftURL", "name": package}, "version": version}))
    return queries


def fetch(queries):
    request = Request("https://api.osv.dev/v1/querybatch", data=json.dumps({"queries": queries}).encode(),
                      headers={"Content-Type": "application/json"})
    # The request has a fixed HTTPS destination. Lockfile values appear only in the body.
    # nosemgrep: python.lang.security.audit.dynamic-urllib-use-detected.dynamic-urllib-use-detected
    with urlopen(request, timeout=30) as response:
        return json.load(response)["results"]


def find_advisories(queries, query_batch=fetch):
    findings = set()
    pending = queries
    for _ in range(10):
        results = query_batch([query for _, query in pending])
        if len(results) != len(pending):
            raise ValueError("incomplete OSV response")
        next_page = []
        for (label, query), result in zip(pending, results, strict=True):
            for advisory in result.get("vulns", []):
                findings.add((label, advisory["id"]))
            if result.get("next_page_token"):
                next_page.append((label, {**query, "page_token": result["next_page_token"]}))
        if not next_page:
            return sorted(findings)
        pending = next_page
    raise ValueError("too many OSV response pages")


def main():
    try:
        queries = read_queries(LOCKFILE)
        findings = find_advisories(queries)
        print(f"Swift dependency scan checked {len({label for label, _ in queries})} resolved packages.")
        for package, advisory in findings:
            print(f"{package}: {advisory!r}")
        return int(bool(findings))
    except (OSError, ValueError, KeyError, TypeError, AttributeError):
        print("Swift dependency scan could not read the lockfile or complete the OSV query.", file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
