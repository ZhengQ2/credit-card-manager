"""Audit Card Ledger's named AWS resources through read-only AWS APIs."""

import argparse
import json
import os
import re
import subprocess
import sys


class ScanError(Exception):
    pass


class Aws:
    def __init__(self, region, profile=None):
        self.options = [f"--region={region}", "--output", "json", "--no-cli-pager", "--no-cli-auto-prompt",
                        "--cli-connect-timeout", "5", "--cli-read-timeout", "10"]
        if profile:
            self.options.append(f"--profile={profile}")

    def read(self, service, operation, *args, query):
        env = {**os.environ, "AWS_IGNORE_CONFIGURED_ENDPOINT_URLS": "true", "AWS_MAX_ATTEMPTS": "2"}
        try:
            result = subprocess.run(["aws", service, operation, *args, *self.options, "--query", query],
                                    env=env, capture_output=True, text=True, timeout=35)
            if result.returncode:
                code = re.search(r"An error occurred \(([A-Za-z0-9]+)\)", result.stderr)
                reason = code.group(1) if code else "AWS CLI error"
                raise ScanError(f"{service} {operation} failed ({reason})")
            return json.loads(result.stdout)
        except (OSError, subprocess.TimeoutExpired, ValueError) as error:
            raise ScanError(f"{service} {operation} did not return a report") from error


def web_ingress_only(groups):
    for group in groups:
        for rule in group["IpPermissions"]:
            if rule.get("IpProtocol") not in ("tcp", "6"):
                return False
            start, end = rule.get("FromPort"), rule.get("ToPort")
            if start != end or start not in (80, 443):
                return False
    return True


def host_checks(aws, target):
    instances = aws.read("ec2", "describe-instances", "--instance-ids", target.instance_id,
                         query="Reservations[].Instances[].{Metadata:MetadataOptions.{HttpEndpoint:HttpEndpoint,HttpTokens:HttpTokens},"
                               "Volumes:BlockDeviceMappings[].Ebs.VolumeId,Groups:SecurityGroups[].GroupId}")
    if len(instances) != 1:
        raise ScanError("EC2 did not return exactly the requested instance")
    instance = instances[0]
    volumes = set(instance["Volumes"] or [])
    groups = set(instance["Groups"] or [])
    if not volumes or not groups:
        raise ScanError("EC2 did not return the attached volumes and security groups")
    volume_config = aws.read("ec2", "describe-volumes", "--volume-ids", *sorted(volumes),
                             query="Volumes[].{Id:VolumeId,Encrypted:Encrypted}")
    group_config = aws.read("ec2", "describe-security-groups", "--group-ids", *sorted(groups),
                            query="SecurityGroups[].{Id:GroupId,IpPermissions:IpPermissions[].{IpProtocol:IpProtocol,FromPort:FromPort,ToPort:ToPort}}")
    if {item["Id"] for item in volume_config} != volumes or {item["Id"] for item in group_config} != groups:
        raise ScanError("EC2 returned an incomplete volume or security group inventory")
    metadata = instance["Metadata"]
    return {
        "Instance metadata requires IMDSv2 or is disabled": (
            metadata.get("HttpEndpoint") == "disabled" or metadata.get("HttpTokens") == "required"),
        "All attached EBS volumes are encrypted": all(volume.get("Encrypted") is True for volume in volume_config),
        "Security groups allow inbound TCP ports 80 and 443 only": web_ingress_only(group_config),
    }


def database_checks(aws, target):
    table = f"--table-name={target.table_name}"
    protection = aws.read("dynamodb", "describe-table", table, query="Table.DeletionProtectionEnabled")
    recovery = aws.read("dynamodb", "describe-continuous-backups", table,
                        query="ContinuousBackupsDescription.PointInTimeRecoveryDescription.PointInTimeRecoveryStatus")
    ttl = aws.read("dynamodb", "describe-time-to-live", table, query="TimeToLiveDescription")
    return {
        "DynamoDB deletion protection is enabled": protection is True,
        "DynamoDB point-in-time recovery is enabled": recovery == "ENABLED",
        "DynamoDB expires records using the ttl attribute": (
            ttl.get("TimeToLiveStatus") == "ENABLED" and ttl.get("AttributeName") == "ttl"),
    }


def key_checks(aws, target):
    key = aws.read("kms", "describe-key", f"--key-id={target.kms_key_id}", query="KeyMetadata.{Arn:Arn,State:KeyState}")
    arn = key["Arn"]
    if not isinstance(arn, str) or not arn.startswith("arn:") or ":key/" not in arn:
        raise ScanError("KMS did not return a key ARN")
    rotation = aws.read("kms", "get-key-rotation-status", f"--key-id={arn}", query="KeyRotationEnabled")
    return {"KMS key is enabled": key["State"] == "Enabled", "KMS key rotation is enabled": rotation is True}


def parameter_checks(aws, target):
    checks = {}
    for name in ("PLAID_CLIENT_ID", "PLAID_SECRET", "JWT_SECRET", "CODE_PEPPER"):
        path = f"{target.ssm_prefix.rstrip('/')}/{name}"
        types = aws.read("ssm", "describe-parameters", "--parameter-filters", f"Key=Name,Option=Equals,Values={path}",
                         query="Parameters[].Type")
        checks[f"SSM stores {name} as SecureString"] = types == ["SecureString"]
    return checks


def scan(aws, target, output=print):
    try:
        actual_account = aws.read("sts", "get-caller-identity", query="Account")
    except ScanError as error:
        output(f"INCOMPLETE  {error}")
        return 2
    if actual_account != target.aws_account:
        output("INCOMPLETE  AWS credentials belong to a different account than requested.")
        return 2

    failed = False
    incomplete = False
    for check in (host_checks, database_checks, key_checks, parameter_checks):
        try:
            for description, passed in check(aws, target).items():
                output(f"{'PASS' if passed else 'FINDING'}  {description}")
                failed |= not passed
        except ScanError as error:
            output(f"INCOMPLETE  {error}")
            incomplete = True
        except (TypeError, KeyError, AttributeError):
            output(f"INCOMPLETE  AWS returned unexpected data for {check.__name__}.")
            incomplete = True
    return 2 if incomplete else int(failed)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--aws-account", required=True)
    parser.add_argument("--region", required=True)
    parser.add_argument("--instance-id", required=True)
    parser.add_argument("--table-name", default="card-ledger")
    parser.add_argument("--kms-key-id", default="alias/card-ledger-plaid-tokens")
    parser.add_argument("--ssm-prefix", default="/card-ledger/prod")
    parser.add_argument("--profile")
    target = parser.parse_args()
    if not re.fullmatch(r"[0-9]{12}", target.aws_account):
        parser.error("--aws-account must be a 12-digit AWS account ID")
    if not re.fullmatch(r"i-(?:[0-9a-f]{8}|[0-9a-f]{17})", target.instance_id):
        parser.error("--instance-id must be an EC2 instance ID")
    if not re.fullmatch(r"/[0-9A-Za-z_./-]+", target.ssm_prefix):
        parser.error("--ssm-prefix must be an absolute SSM parameter path")
    return scan(Aws(target.region, target.profile), target)


if __name__ == "__main__":
    sys.exit(main())
