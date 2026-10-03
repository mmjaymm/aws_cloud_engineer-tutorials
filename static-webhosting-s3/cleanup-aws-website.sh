#!/usr/bin/env bash
# Purpose: remove one S3 website lab and its optional standard CloudFront distribution/OAC.
# Requires Bash, AWS CLI v2, Python 3, and authenticated AWS credentials.
# Default: inspect and preview only. Add --delete to enable deletion with confirmation.
# Supports the unversioned bucket from the guide. Refuses versioned/suspended buckets.
# Does not remove domains, Route 53, certificates, budgets, logs, or other resources.
set -euo pipefail
export AWS_PAGER=""

usage() {
  cat <<'TEXT'
Usage:
  bash cleanup-aws-website.sh --bucket NAME --account ACCOUNT_ID [options]
Options:
  --region REGION          Default: ap-southeast-1
  --distribution ID        Optional CloudFront distribution belonging to this lab
  --oac ID                 Optional lab OAC; requires --distribution
  --delete                 Delete after entering the exact bucket name
  --help                   Show usage

Preview:
  bash cleanup-aws-website.sh --bucket YOUR_BUCKET --account YOUR_ACCOUNT_ID
Delete:
  bash cleanup-aws-website.sh --bucket YOUR_BUCKET --account YOUR_ACCOUNT_ID --delete
CloudFront + S3:
  bash cleanup-aws-website.sh --bucket YOUR_BUCKET --account YOUR_ACCOUNT_ID \
    --distribution YOUR_DISTRIBUTION_ID --oac YOUR_OAC_ID --delete

Deletion is permanent. Only use this with a dedicated lab bucket.
CloudFront deployment waits can take several minutes. Retry after a waiter timeout.
TEXT
}
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
BUCKET=""; EXPECTED_ACCOUNT=""; REGION="ap-southeast-1"
DIST=""; OAC=""; DELETE=false
while (($#)); do
  case "$1" in
    --bucket|--account|--region|--distribution|--oac)
      (($# >= 2)) || die "Missing value for $1"
      case "$1" in
        --bucket) BUCKET="$2";;
        --account) EXPECTED_ACCOUNT="$2";;
        --region) REGION="$2";;
        --distribution) DIST="$2";;
        --oac) OAC="$2";;
      esac
      shift 2;;
    --delete) DELETE=true; shift;;
    --help|-h) usage; exit 0;;
    *) die "Unknown argument: $1";;
  esac
done
[[ -n "$BUCKET" && "$EXPECTED_ACCOUNT" =~ ^[0-9]{12}$ ]] || { usage; exit 1; }
[[ "$BUCKET" =~ ^[a-z0-9][a-z0-9.-]{1,61}[a-z0-9]$ ]] || die "Invalid bucket name"
[[ -z "$OAC" || -n "$DIST" ]] || die "--oac requires --distribution"
for dep in aws python3; do command -v "$dep" >/dev/null || die "Install $dep first"; done
export AWS_DEFAULT_REGION="$REGION"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf -- "$TMP_DIR"' EXIT

# Step 1 purpose: verify the account and bucket ownership before any mutation.
ACTUAL_ACCOUNT="$(aws sts get-caller-identity --query Account --output text)"
[[ "$ACTUAL_ACCOUNT" = "$EXPECTED_ACCOUNT" ]] || die "Wrong account: signed in as $ACTUAL_ACCOUNT"
aws s3api head-bucket --bucket "$BUCKET" --expected-bucket-owner "$EXPECTED_ACCOUNT"
aws s3api get-bucket-versioning --bucket "$BUCKET" \
  --expected-bucket-owner "$EXPECTED_ACCOUNT" > "$TMP_DIR/versioning.json"
python3 - "$TMP_DIR/versioning.json" <<'PY'
import json, sys
if json.load(open(sys.argv[1])).get('Status') in ('Enabled', 'Suspended'):
    sys.exit('Refusing cleanup: bucket has versioning history. Use S3 Console Empty to remove all versions/delete markers first.')
PY

# Step 2 purpose: detect CloudFront references so the bucket is not removed by mistake.
# Listing requires cloudfront:ListDistributions even for an S3-only cleanup.
aws cloudfront list-distributions > "$TMP_DIR/distributions.json"
python3 - "$TMP_DIR/distributions.json" "$BUCKET" "$DIST" <<'PY'
import json, sys
data, bucket, selected = sys.argv[1:]
refs = []
for d in json.load(open(data)).get('DistributionList', {}).get('Items', []):
    if any(o['DomainName'].startswith(bucket + '.s3') for o in d['Origins']['Items']):
        refs.append(d['Id'])
other = [x for x in refs if x != selected]
if other:
    sys.exit('Bucket has CloudFront references not selected for cleanup: ' + ', '.join(other))
PY
if [[ -n "$DIST" ]]; then
  aws cloudfront get-distribution-config --id "$DIST" > "$TMP_DIR/distribution.json"
  # Refuse shared/mismatched distributions; this script is for the guide's single-origin lab.
  python3 - "$TMP_DIR/distribution.json" "$BUCKET" "$OAC" <<'PY'
import json, sys
path, bucket, oac = sys.argv[1:]
config = json.load(open(path))['DistributionConfig']
origins = config['Origins']['Items']
if len(origins) != 1 or not origins[0]['DomainName'].startswith(bucket + '.s3'):
    sys.exit('Refusing: distribution is not a single-origin distribution for this bucket.')
if oac and origins[0].get('OriginAccessControlId') != oac:
    sys.exit('Refusing: OAC does not match the selected distribution.')
PY
fi

# Step 3 purpose: show exactly what will be deleted and request typed confirmation.
printf 'Account: %s\nBucket: %s\nRegion: %s\n' "$ACTUAL_ACCOUNT" "$BUCKET" "$REGION"
printf 'CloudFront: %s\nOAC: %s\n' "${DIST:-none}" "${OAC:-none}"
printf 'All objects in this bucket will be permanently deleted.\n'
if [[ "$DELETE" = false ]]; then
  printf 'Preview only. Nothing changed. Add --delete to perform cleanup.\n'
  exit 0
fi
read -r -p 'Type the exact bucket name to confirm: ' CONFIRM
[[ "$CONFIRM" = "$BUCKET" ]] || die "Confirmation did not match; nothing deleted"

# Step 4 purpose: disable CloudFront and wait before deleting its distribution.
if [[ -n "$DIST" ]]; then
  # Refresh the configuration/ETag in case it changed during confirmation.
  aws cloudfront get-distribution-config --id "$DIST" > "$TMP_DIR/distribution.json"
  python3 - "$TMP_DIR/distribution.json" "$TMP_DIR/disabled.json" <<'PY'
import json, sys
data = json.load(open(sys.argv[1]))
data['DistributionConfig']['Enabled'] = False
with open(sys.argv[2], 'w') as f:
    json.dump(data['DistributionConfig'], f)
PY
  ETAG="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["ETag"])' "$TMP_DIR/distribution.json")"
  aws cloudfront update-distribution --id "$DIST" --if-match "$ETAG" \
    --distribution-config "file://$TMP_DIR/disabled.json" > /dev/null
  printf 'Waiting for CloudFront to finish disabling...\n'
  aws cloudfront wait distribution-deployed --id "$DIST"
  ETAG="$(aws cloudfront get-distribution-config --id "$DIST" --query ETag --output text)"
  aws cloudfront delete-distribution --id "$DIST" --if-match "$ETAG"
  printf 'CloudFront distribution deleted.\n'
fi

# Step 5 purpose: delete the optional OAC after its distribution is removed.
# AWS rejects deletion if another distribution still uses this OAC.
if [[ -n "$OAC" ]]; then
  ETAG="$(aws cloudfront get-origin-access-control --id "$OAC" --query ETag --output text)"
  if ! aws cloudfront delete-origin-access-control --id "$OAC" --if-match "$ETAG"; then
    printf 'OAC deletion failed (possibly still propagating/in use). Retry separately after checking CloudFront.\n' >&2
  fi
fi

# Step 6 purpose: permanently delete current objects and the unversioned bucket.
# head-bucket ownership was checked above; high-level rm has no owner flag.
aws s3 rm "s3://$BUCKET/" --recursive --only-show-errors
aws s3api delete-bucket --bucket "$BUCKET" --region "$REGION" \
  --expected-bucket-owner "$EXPECTED_ACCOUNT"
printf 'S3 bucket deleted. Lab cleanup complete.\n'
printf 'Existing billed usage is not refunded. Check Billing for other resources.\n'
