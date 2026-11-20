import json
from pathlib import Path
import plistlib
from tempfile import TemporaryDirectory
from types import SimpleNamespace
import unittest
from unittest.mock import patch

from scan_aws_config import ScanError, scan
from scan_source import plist_findings
from scan_swift_dependencies import find_advisories, read_queries


class FakeAws:
    def __init__(self):
        self.calls = []
        self.responses = {
            "get-caller-identity": "123456789012",
            "describe-instances": [{
                "Metadata": {"HttpEndpoint": "enabled", "HttpTokens": "required"},
                "Volumes": ["vol-test"], "Groups": ["sg-test"],
            }],
            "describe-volumes": [{"Id": "vol-test", "Encrypted": True}],
            "describe-security-groups": [{"Id": "sg-test", "IpPermissions": [
                {"IpProtocol": "tcp", "FromPort": 443, "ToPort": 443},
            ]}],
            "describe-table": True,
            "describe-continuous-backups": "ENABLED",
            "describe-time-to-live": {"TimeToLiveStatus": "ENABLED", "AttributeName": "ttl"},
            "describe-key": {"Arn": "arn:aws:kms:ca-central-1:123456789012:key/test", "State": "Enabled"},
            "get-key-rotation-status": True,
            "describe-parameters": ["SecureString"],
        }

    def read(self, service, operation, *args, query):
        self.calls.append((service, operation, args, query))
        response = self.responses[operation]
        if isinstance(response, Exception):
            raise response
        return response


class AwsScanTests(unittest.TestCase):
    def setUp(self):
        self.aws = FakeAws()
        self.target = SimpleNamespace(aws_account="123456789012", instance_id="i-12345678",
                                      table_name="card-ledger", kms_key_id="alias/card-ledger", ssm_prefix="/test")
        self.output = []

    def test_checks_only_named_resources_and_parameter_metadata(self):
        self.assertEqual(scan(self.aws, self.target, self.output.append), 0)
        self.assertEqual(len(self.output), 12)
        self.assertTrue(all(line.startswith("PASS") for line in self.output))
        self.assertIn(("ec2", "describe-volumes", ("--volume-ids", "vol-test")), [call[:3] for call in self.aws.calls])
        self.assertIn(("kms", "get-key-rotation-status", ("--key-id=arn:aws:kms:ca-central-1:123456789012:key/test",)),
                      [call[:3] for call in self.aws.calls])
        self.assertEqual(
            {args[-1] for service, _, args, _ in self.aws.calls if service == "ssm"},
            {f"Key=Name,Option=Equals,Values=/test/{name}" for name in ("PLAID_CLIENT_ID", "PLAID_SECRET", "JWT_SECRET", "CODE_PEPPER")},
        )
        self.assertTrue(all(query == "Parameters[].Type" for service, _, _, query in self.aws.calls if service == "ssm"))

    def test_wrong_account_stops_before_any_configuration_reads(self):
        self.aws.responses["get-caller-identity"] = "234567890123"
        self.assertEqual(scan(self.aws, self.target, self.output.append), 2)
        self.assertEqual([call[0] for call in self.aws.calls], ["sts"])

    def test_reports_insecure_ingress_and_retention(self):
        self.aws.responses["describe-security-groups"][0]["IpPermissions"][0]["FromPort"] = 22
        self.aws.responses["describe-time-to-live"]["AttributeName"] = "unrelated"
        self.assertEqual(scan(self.aws, self.target, self.output.append), 1)
        self.assertEqual(sum(line.startswith("FINDING") for line in self.output), 2)

    def test_failed_or_incomplete_api_reads_do_not_pass(self):
        self.aws.responses["describe-volumes"] = []
        self.aws.responses["describe-table"] = ScanError("access denied")
        self.assertEqual(scan(self.aws, self.target, self.output.append), 2)
        self.assertEqual(sum(line.startswith("INCOMPLETE") for line in self.output), 2)
        self.assertTrue(any(line.startswith("PASS") and "KMS" in line for line in self.output))


class SwiftScanTests(unittest.TestCase):
    def test_queries_both_public_version_and_resolved_commit(self):
        with TemporaryDirectory() as directory:
            lockfile = Path(directory) / "Package.resolved"
            lockfile.write_text(json.dumps({"pins": [{"location": "https://github.com/Example/Swift.git",
                                                     "state": {"revision": "a" * 40, "version": "1.0.0"}}]}),
                                encoding="utf-8")
            self.assertEqual(read_queries(lockfile), [
                ("github.com/example/swift@1.0.0", {"commit": "a" * 40}),
                ("github.com/example/swift@1.0.0", {"package": {"ecosystem": "SwiftURL", "name": "github.com/example/swift"},
                                                   "version": "1.0.0"}),
            ])

    def test_pages_and_deduplicates_advisories(self):
        label = "test-package"
        queries = [(label, {"commit": "a" * 40}), (label, {"version": "1.0.0"})]
        calls = []

        def query_batch(pending):
            calls.append(pending)
            if len(calls) == 1:
                shared = {"vulns": [{"id": "TEST-1"}]}
                return [{**shared, "next_page_token": "page2"}, shared]
            return [{"vulns": [{"id": "TEST-2"}]}]

        self.assertEqual(find_advisories(queries, query_batch), [(label, "TEST-1"), (label, "TEST-2")])
        self.assertEqual(calls[1], [{"commit": "a" * 40, "page_token": "page2"}])

    def test_incomplete_advisory_response_fails(self):
        with self.assertRaisesRegex(ValueError, "incomplete OSV response"):
            find_advisories([("test-package", {"commit": "a" * 40})], lambda _: [])


class AppleConfigurationTests(unittest.TestCase):
    def test_reports_an_insecure_plist_by_filename_and_rule(self):
        with TemporaryDirectory() as directory, patch("scan_source.ROOT", Path(directory)):
            info = Path(directory) / "Info.plist"
            info.write_bytes(plistlib.dumps({"NSAppTransportSecurity": {"NSAllowsArbitraryLoads": True}}))
            self.assertEqual(plist_findings([info.name]), [(info.name, "card-ledger.ats-global-exception")])
