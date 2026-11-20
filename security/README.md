# Security scans

The [Security scans workflow](../.github/workflows/security-scans.yml) runs on pull requests, pushes to `main`, and daily at 7:37 a.m. Toronto time. Run it on demand from **Actions → Security scans**. Each repository scan reports its own result in the workflow log.

| Check | Coverage |
|---|---|
| Source | Semgrep Community Edition with its default rule pack and the Card Ledger rules in this directory. It covers Swift and TypeScript source, selected configuration files, and GitHub workflows. Output contains a file, line and rule ID for each finding. |
| npm | `npm audit` reads the resolved lockfile, including development dependencies, and fails the job for high or critical advisories. |
| Swift | OSV checks the locked versions and Git commits of the iOS app’s GitHub-hosted Swift packages. The scanner fails on a matching advisory or an unreadable result. Advisory coverage depends on the upstream records for each package, including packages that ship prebuilt binaries. |
| AWS | A separate job checks the configured EC2 instance, attached EBS volumes and security groups, DynamoDB protection and retention, KMS key rotation, and SSM parameter types. It runs on the `main` branch on schedule or on demand once configured. |

## Run locally

Use Python 3.10 or later and Git. Run these commands from the repository root to install the same Semgrep version as CI in an isolated environment and check the repository rules offline.

```bash
python3 -m venv "$HOME/.local/share/card-ledger/semgrep"
"$HOME/.local/share/card-ledger/semgrep/bin/python" -m pip --isolated install --only-binary=:all: semgrep==1.184.0
PATH="$HOME/.local/share/card-ledger/semgrep/bin:$PATH" python3 security/scan_source.py --offline
```

The installation downloads packages. The `--offline` scan uses only the checked-in rules. Its summary reports the number of checked files and findings. Keep the environment's `bin` directory on `PATH` for the default source scan. Use npm for the Node check and AWS CLI v2 for the cloud check.

```bash
python3 security/scan_source.py
python3 security/scan_swift_dependencies.py
(cd owner-service && npm audit --package-lock-only --ignore-scripts --audit-level=high --include=dev)
python3 -m unittest discover -s security
```

Local source scope comes from Git and its ignore rules. The default source scan downloads public rules and analyzes code locally with metrics disabled. The dependency checks send package identifiers and versions or commits to advisory services.

The Python scanners return `0` for a completed scan with zero findings, `1` for findings, and `2` if the scan could not complete. Scan runs leave dependencies and cloud resources as they found them.

## Enable scheduled AWS checks

Create a dedicated IAM role for GitHub OIDC. Require audience `sts.amazonaws.com` and the exact subject for `refs/heads/main`. This repository uses the immutable subject `repo:ZhengQ2@77452278/credit-card-manager@1463869487:ref:refs/heads/main`. For another repository, look up its configured subject prefix before creating the trust policy. [GitHub AWS OIDC setup](https://docs.github.com/en/actions/how-tos/secure-your-work/security-harden-deployments/oidc-in-aws)

Grant only the configuration operations below. The DynamoDB and KMS checks can be scoped to the target table and key ARNs. The EC2 and SSM listing operations require `Resource: "*"`. Limit them to the deployment Region with `aws:RequestedRegion`. The KMS key policy must also permit the role to describe the key and read rotation status.

| Service | IAM actions |
|---|---|
| EC2 | `ec2:DescribeInstances`, `ec2:DescribeVolumes`, `ec2:DescribeSecurityGroups` |
| DynamoDB | `dynamodb:DescribeTable`, `dynamodb:DescribeContinuousBackups`, `dynamodb:DescribeTimeToLive` |
| KMS | `kms:DescribeKey`, `kms:GetKeyRotationStatus` |
| Systems Manager | `ssm:DescribeParameters` |

The script verifies the AWS account with STS before reading any resources. SSM checks read the types of four named parameters. This role needs only configuration metadata permissions.

In **Settings → Secrets and variables → Actions → Secrets**, store `AWS_SCAN_ACCOUNT_ID`, `AWS_SCAN_INSTANCE_ID`, and `AWS_SCAN_ROLE_ARN` to keep resource identifiers out of public workflow logs. GitHub assumes the role with a short-lived OIDC token. Under **Variables**, set `AWS_SCAN_ENABLED` to `true`. Set optional variables if your deployment differs from the defaults below.

| Variable | Default |
|---|---|
| `AWS_SCAN_REGION` | `ca-central-1` |
| `AWS_SCAN_TABLE_NAME` | `card-ledger` |
| `AWS_SCAN_KMS_KEY_ID` | `alias/card-ledger-plaid-tokens` |
| `AWS_SCAN_SSM_PREFIX` | `/card-ledger/prod` |

For a local run, use a profile with the same read-only permissions and substitute your account and instance IDs.

```bash
python3 security/scan_aws_config.py --profile card-ledger-audit --region ca-central-1 \
  --aws-account 123456789012 --instance-id i-0123456789abcdef0
```
