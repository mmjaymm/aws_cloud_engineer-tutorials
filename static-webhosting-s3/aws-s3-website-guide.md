# AWS S3 Website Hosting — Beginner Guide and Sequential Scripts

Prepared for Mark Jay • 3 October 2026

## What you will build

A static portfolio website, first served directly by Amazon S3 over HTTP, then upgraded to HTTPS using CloudFront and a private S3 bucket.

S3 stores HTML, CSS, JavaScript, and images. It does not execute PHP, Node.js, or Python server applications. React works when you upload its static build output. This lab does not need EC2, a VPC, a load balancer, or a database.

## How to follow this guide

- Every step includes its **purpose**, **console equivalent**, and **script** where applicable.
- Choose either console actions or their matching commands; do not create the same resource twice.
- Run the Bash blocks in order, in the same terminal, from Step 1 onward. The commands share variables and generated JSON files.
- Recommended terminal: **AWS CloudShell**, opened from the AWS Console. It includes AWS CLI and uses your signed-in identity's permissions. These are Bash commands, not Windows CMD or PowerShell commands.
- CloudShell availability depends on your account and region. On WSL/Linux/macOS, install AWS CLI v2 and authenticate first, preferably with your organization's IAM Identity Center profile. See the official CLI setup link at the end.
- These commands are instructions for you to run. They have not been deployed to your AWS account.
- This guide targets the standard AWS commercial partition and uses Singapore (`ap-southeast-1`).

## Required resources

| Resource | Purpose | When needed |
|---|---|---|
| AWS account and MFA | Access and protect your account | Before starting |
| IAM identity | Authorize the operations | Before starting |
| S3 general-purpose bucket | Store the website | Main lab |
| `index.html` and `error.html` | Homepage and error page | Main lab |
| AWS Console / CloudShell | Configure resources / execute scripts | Main lab |
| AWS Budgets email alert | Monitor costs | Recommended |
| CloudFront distribution | Deliver HTTPS and cached content | Optional upgrade |
| Origin Access Control (OAC) | Authorize CloudFront to read private S3 files | Optional upgrade |
| Custom domain and DNS | Use your own website address | Optional future task |

## Permissions and billing preparation

**Purpose:** Confirm access and cost visibility before creating resources.

Use a non-root identity for daily work. Enable MFA on the root account. Your administrator should grant permissions scoped to this project where supported.

| Operation group | Relevant IAM actions |
|---|---|
| Bucket setup and cleanup | `s3:CreateBucket`, `s3:DeleteBucket`, `s3:ListBucket`, `s3:GetBucketLocation` |
| Website files | `s3:PutObject`, `s3:GetObject`, `s3:DeleteObject` |
| Website settings | `s3:PutBucketWebsite`, `s3:GetBucketWebsite`, `s3:DeleteBucketWebsite` |
| Bucket access | `s3:PutBucketPolicy`, `s3:GetBucketPolicy`, `s3:DeleteBucketPolicy`, `s3:PutBucketPublicAccessBlock`, `s3:GetBucketPublicAccessBlock` |
| CloudFront upgrade | Create/get/update/delete distribution, create/get/delete OAC, list cache policies, create/get invalidation |
| CloudShell | CloudShell environment and session permissions |

This is an action checklist, not a complete IAM policy. Resource ARNs, permission boundaries, service control policies, and account-level settings also affect authorization. Avoid granting blanket administrator access merely to complete this lab.

**Console:** Billing and Cost Management → inspect Free Tier eligibility and credits → Budgets → create a monthly cost budget (for example, USD 5), with actual and forecast email alerts. Budget alerts are notifications, not spending caps. Billing data and alerts can be delayed. Costs depend on storage, requests, transfer, and any CloudFront plan/options you select; check your account's current offers instead of assuming the lab is free.

## Main lab: direct S3 website

### Step 1 — Verify identity and initialize the project

**Purpose:** Confirm the AWS account you will modify, set the region, and give the bucket a unique name.

**Console equivalent:** Open CloudShell and check the account shown in the AWS Console.

```bash
# Stop subsequent pasted commands after an error; disable the CLI output pager.
set -euo pipefail
export AWS_PAGER=""
export AWS_DEFAULT_REGION="ap-southeast-1"
export AWS_REGION="$AWS_DEFAULT_REGION"

# Show your identity. Verify the Account value before continuing.
aws sts get-caller-identity

# This guide creates resources only under a new project name.
export ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text)"
export PROJECT_SUFFIX="$(date -u +%Y%m%d%H%M%S)"
export BUCKET_NAME="markjay-portfolio-${ACCOUNT_ID}-${PROJECT_SUFFIX}"
export PROJECT_DIR="$PWD/$BUCKET_NAME"
mkdir -p "$PROJECT_DIR/site"
cd "$PROJECT_DIR"

# Save non-secret identifiers so you can resume in a later terminal.
printf 'export AWS_DEFAULT_REGION=%q\nexport AWS_REGION=%q\nexport ACCOUNT_ID=%q\nexport BUCKET_NAME=%q\nexport PROJECT_DIR=%q\n' \
  "$AWS_DEFAULT_REGION" "$AWS_REGION" "$ACCOUNT_ID" "$BUCKET_NAME" "$PROJECT_DIR" > project.env
printf 'Bucket: %s\nWorking directory: %s\n' "$BUCKET_NAME" "$PROJECT_DIR"
```

**Expected result:** Your account identity and a unique bucket name. Keep `project.env`; it contains identifiers, not AWS credentials. If you resume later, `cd` to the printed project directory, run `source project.env`, and reapply `set -euo pipefail` and `export AWS_PAGER=""`. Do not rerun Step 1 unless you want a new project.

### Step 2 — Create the website files

**Purpose:** Produce the content visitors will see. Only files inside `site/` will be uploaded.

**Console equivalent:** Create these files with your text editor, then upload them in Step 4.

```bash
cat > site/index.html <<'HTML'
<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>My First AWS Website</title>
  <style>
    body { font-family: Arial, sans-serif; background: #0f172a;
      color: #f8fafc; max-width: 750px; margin: 80px auto; padding: 24px; }
    h1 { color: #38bdf8; }
    .card { background: #1e293b; padding: 24px; border-radius: 12px; }
  </style>
</head>
<body>
  <h1>Hello! I’m Mark Jay.</h1>
  <div class="card">
    <h2>My first AWS cloud project</h2>
    <p>This website is hosted on Amazon S3.</p>
    <p>I’m learning AWS Cloud and DevOps engineering.</p>
  </div>
</body>
</html>
HTML

cat > site/error.html <<'HTML'
<!DOCTYPE html>
<html lang="en">
<head><meta charset="UTF-8"><title>Page Not Found</title></head>
<body><h1>404 — Page not found</h1><a href="/">Return to homepage</a></body>
</html>
HTML

ls -l site/
```

**Expected result:** `site/index.html` and `site/error.html`. Names are case-sensitive.

### Step 3 — Create the S3 bucket

**Purpose:** Create the storage container for your website. ACLs remain disabled and default S3-managed encryption applies. This new bucket has versioning disabled by default.

**Console equivalent:** S3 → Create bucket → General purpose → enter the bucket name → Singapore → Object Ownership: ACLs disabled → keep SSE-S3 encryption → Create.

```bash
# LocationConstraint is required here because the region is Singapore.
aws s3api create-bucket \
  --bucket "$BUCKET_NAME" \
  --region "$AWS_REGION" \
  --create-bucket-configuration "LocationConstraint=$AWS_REGION" \
  --object-ownership BucketOwnerEnforced

# Explicitly keep the bucket private during setup.
aws s3api put-public-access-block \
  --bucket "$BUCKET_NAME" \
  --public-access-block-configuration \
  'BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true'
```

**Expected result:** A new private bucket. For `us-east-1`, omit `--create-bucket-configuration`; do not simply change the region variable and reuse this command unchanged.

### Step 4 — Upload the website

**Purpose:** Copy only the public website files into the bucket root.

**Console equivalent:** Bucket → Objects → Upload → select `index.html` and `error.html` → Upload.

```bash
aws s3 sync ./site/ "s3://$BUCKET_NAME/"
aws s3 ls "s3://$BUCKET_NAME/"
```

**Expected result:** Both HTML files appear directly at the bucket root. Do not upload `project.env`, policy files, credentials, `.env` secrets, or private documents. `sync` uploads new or changed files; this command does not delete remote files.

### Step 5 — Enable S3 website hosting

**Purpose:** Tell S3 which file is the homepage and which file is the error document.

**Console equivalent:** Bucket → Properties → Static website hosting → Edit → Enable → Host a static website → `index.html` / `error.html` → Save.

```bash
aws s3api put-bucket-website \
  --bucket "$BUCKET_NAME" \
  --website-configuration \
  '{"IndexDocument":{"Suffix":"index.html"},"ErrorDocument":{"Key":"error.html"}}'

aws s3api get-bucket-website --bucket "$BUCKET_NAME"
```

**Expected result:** The configured document names. Direct S3 website hosting supports HTTP rather than HTTPS.

### Step 6 — Allow public read access for this lab

**Purpose:** Let anonymous visitors download website objects. They receive no permission to upload, delete, or list the bucket.

**Console equivalent:** Permissions → Block public access → allow public bucket policies; then Bucket policy → paste the generated policy below.

The CLI keeps public ACL protections enabled and changes only the two settings that block public bucket policies. This is more specific than clearing all four options. Only use this on the dedicated website bucket.

```bash
aws s3api put-public-access-block \
  --bucket "$BUCKET_NAME" \
  --public-access-block-configuration \
  'BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=false,RestrictPublicBuckets=false'

cat > public-read-policy.json <<JSON
{
  "Version": "2012-10-17",
  "Statement": [{
    "Sid": "PublicReadWebsiteFiles",
    "Effect": "Allow",
    "Principal": "*",
    "Action": "s3:GetObject",
    "Resource": "arn:aws:s3:::${BUCKET_NAME}/*"
  }]
}
JSON

aws s3api put-bucket-policy \
  --bucket "$BUCKET_NAME" \
  --policy file://public-read-policy.json
```

**Expected result:** The policy saves successfully. Every object in this bucket is now publicly readable. If account or organization restrictions reject the policy, stop this public-access path and use the private CloudFront upgrade. Do not weaken organization-wide settings to finish the lab.

### Step 7 — Test the website

**Purpose:** Confirm the homepage and error behavior from an anonymous visitor's perspective.

**Console equivalent:** Properties → Static website hosting → open the Bucket website endpoint.

```bash
# This endpoint format is for the Singapore region used by this guide.
export WEBSITE_URL="http://${BUCKET_NAME}.s3-website-${AWS_REGION}.amazonaws.com"
printf 'Open in browser: %s\n' "$WEBSITE_URL"

# Homepage should return HTTP 200.
curl -i "$WEBSITE_URL/"

# Missing page should return HTTP 404 with your error document.
curl -i "$WEBSITE_URL/missing.html"
```

**Expected result:** Homepage loads; the missing page displays your error content. If you use another region, copy the authoritative endpoint from the Console because endpoint naming varies by region.

### Step 8 — Deploy an update

**Purpose:** Practice changing and redeploying website content.

**Console equivalent:** Edit your local file and upload it again with the same name.

```bash
# Edit site/index.html in your editor, then run:
aws s3 sync ./site/ "s3://$BUCKET_NAME/"
```

**Expected result:** Your edited page appears after refresh. A private browser window or hard refresh can help bypass browser caching.

## Optional upgrade: CloudFront + private S3 + HTTPS

Follow Steps 9–13 if you want a shareable HTTPS website. If Step 6 failed because public access is prohibited, this upgrade can still work with the private bucket created in Step 3. Account permissions must permit CloudFront and the restricted bucket policy.

The browser accesses CloudFront; CloudFront reads the private bucket using signed OAC requests. Use the S3 **REST endpoint**, not the S3 website endpoint. The CloudFront default certificate covers its generated `cloudfront.net` hostname, so a purchased domain is unnecessary.

### Step 9 — Remove public hosting access

**Purpose:** Make S3 private before using CloudFront. The previous HTTP website will stop working.

**Console equivalent:** Remove the public-read policy if present → enable all Block Public Access settings → disable Static website hosting.

```bash
# Only needed if Step 6 successfully installed the public-read policy.
# Skip this command if there is no bucket policy to remove.
aws s3api delete-bucket-policy --bucket "$BUCKET_NAME"

aws s3api put-public-access-block \
  --bucket "$BUCKET_NAME" \
  --public-access-block-configuration \
  'BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true'

aws s3api delete-bucket-website --bucket "$BUCKET_NAME"
```

### Step 10 — Create Origin Access Control

**Purpose:** Configure CloudFront to sign its requests to S3 using AWS Signature Version 4.

**Console equivalent:** CloudFront → Origin access controls → Create → origin type S3 → Sign requests.

```bash
cat > oac-config.json <<JSON
{
  "Name": "${BUCKET_NAME}-oac",
  "Description": "Signed access to portfolio bucket",
  "SigningProtocol": "sigv4",
  "SigningBehavior": "always",
  "OriginAccessControlOriginType": "s3"
}
JSON

export OAC_ID="$(aws cloudfront create-origin-access-control \
  --origin-access-control-config file://oac-config.json \
  --query 'OriginAccessControl.Id' --output text)"
printf 'export OAC_ID=%q\n' "$OAC_ID" >> project.env
```

### Step 11 — Create the CloudFront distribution

**Purpose:** Create a CDN endpoint with HTTPS redirects, an S3 REST origin, and `index.html` as the default root object.

**Console equivalent:** CloudFront → Create distribution → S3 bucket origin → attach OAC → redirect HTTP to HTTPS → default root object `index.html` → default CloudFront certificate. Review any optional paid features before enabling them.

This CLI example creates a standard distribution and uses AWS's managed `CachingOptimized` cache policy. It configures a custom error document for both S3 403 and 404 responses, preserving the corresponding status code. A private S3 origin can return 403 for a missing object.

```bash
# Resolve the AWS-managed policy instead of inventing its ID.
export CACHE_POLICY_ID="$(aws cloudfront list-cache-policies --type managed \
  --query "CachePolicyList.Items[?CachePolicy.CachePolicyConfig.Name=='Managed-CachingOptimized'].CachePolicy.Id | [0]" \
  --output text)"
test -n "$CACHE_POLICY_ID"
test "$CACHE_POLICY_ID" != "None"

cat > distribution-config.json <<JSON
{
  "CallerReference": "${BUCKET_NAME}",
  "Comment": "Mark Jay AWS portfolio lab",
  "Enabled": true,
  "DefaultRootObject": "index.html",
  "Origins": {
    "Quantity": 1,
    "Items": [{
      "Id": "portfolio-s3-origin",
      "DomainName": "${BUCKET_NAME}.s3.${AWS_REGION}.amazonaws.com",
      "OriginAccessControlId": "${OAC_ID}",
      "S3OriginConfig": {"OriginAccessIdentity": ""}
    }]
  },
  "DefaultCacheBehavior": {
    "TargetOriginId": "portfolio-s3-origin",
    "ViewerProtocolPolicy": "redirect-to-https",
    "AllowedMethods": {
      "Quantity": 2,
      "Items": ["GET", "HEAD"],
      "CachedMethods": {"Quantity": 2, "Items": ["GET", "HEAD"]}
    },
    "CachePolicyId": "${CACHE_POLICY_ID}",
    "Compress": true,
    "TrustedSigners": {"Enabled": false, "Quantity": 0},
    "TrustedKeyGroups": {"Enabled": false, "Quantity": 0}
  },
  "CustomErrorResponses": {
    "Quantity": 2,
    "Items": [
      {"ErrorCode": 403, "ResponsePagePath": "/error.html", "ResponseCode": "403", "ErrorCachingMinTTL": 10},
      {"ErrorCode": 404, "ResponsePagePath": "/error.html", "ResponseCode": "404", "ErrorCachingMinTTL": 10}
    ]
  },
  "ViewerCertificate": {"CloudFrontDefaultCertificate": true},
  "Restrictions": {"GeoRestriction": {"RestrictionType": "none", "Quantity": 0}},
  "PriceClass": "PriceClass_All",
  "HttpVersion": "http2",
  "IsIPV6Enabled": true
}
JSON

aws cloudfront create-distribution \
  --distribution-config file://distribution-config.json > distribution-result.json

export DISTRIBUTION_ID="$(python3 -c 'import json; print(json.load(open("distribution-result.json"))["Distribution"]["Id"])')"
export CF_DOMAIN="$(python3 -c 'import json; print(json.load(open("distribution-result.json"))["Distribution"]["DomainName"])')"
printf 'export DISTRIBUTION_ID=%q\nexport CF_DOMAIN=%q\n' \
  "$DISTRIBUTION_ID" "$CF_DOMAIN" >> project.env
```

**Expected result:** A distribution ID and hostname saved in `project.env`. Access will fail until Step 12 authorizes the distribution. Creation is not an update command; avoid rerunning Steps 10–11 after success.

### Step 12 — Authorize only your distribution to read S3

**Purpose:** Permit CloudFront's service principal to read objects, limited to your distribution ARN. The bucket remains private.

**Console equivalent:** Apply the restricted bucket policy CloudFront provides for OAC.

```bash
cat > cloudfront-read-policy.json <<JSON
{
  "Version": "2012-10-17",
  "Statement": [{
    "Sid": "AllowThisCloudFrontDistribution",
    "Effect": "Allow",
    "Principal": {"Service": "cloudfront.amazonaws.com"},
    "Action": "s3:GetObject",
    "Resource": "arn:aws:s3:::${BUCKET_NAME}/*",
    "Condition": {
      "StringEquals": {
        "AWS:SourceArn": "arn:aws:cloudfront::${ACCOUNT_ID}:distribution/${DISTRIBUTION_ID}"
      }
    }
  }]
}
JSON

aws s3api put-bucket-policy \
  --bucket "$BUCKET_NAME" \
  --policy file://cloudfront-read-policy.json

# This waiter can take several minutes. If it times out, check status and retry it.
aws cloudfront wait distribution-deployed --id "$DISTRIBUTION_ID"
printf 'HTTPS website: https://%s\n' "$CF_DOMAIN"
```

### Step 13 — Test HTTPS and update cached content

**Purpose:** Verify public access through CloudFront, private S3 access, and the redeployment process.

**Console equivalent:** Open the CloudFront hostname; for updates, use distribution → Invalidations → Create invalidation.

```bash
# Homepage should return 200 over HTTPS.
curl -I "https://$CF_DOMAIN/"

# HTTP should redirect to HTTPS.
curl -I "http://$CF_DOMAIN/"

# Anonymous access directly to S3 should return 403.
curl -I "https://${BUCKET_NAME}.s3.${AWS_REGION}.amazonaws.com/index.html"

# After editing your website, upload changes and refresh the cached homepage.
aws s3 sync ./site/ "s3://$BUCKET_NAME/"
aws cloudfront create-invalidation \
  --distribution-id "$DISTRIBUTION_ID" \
  --paths "/" "/index.html"
```

**Expected result:** CloudFront serves the homepage over HTTPS; anonymous direct S3 access is denied. Invalidations are asynchronous. For changed CSS/images, invalidate their paths too or use versioned filenames. Frequent invalidations can have charges beyond the applicable allowance.

## Cleanup — run only when you want to delete the lab

**Purpose:** Remove resources you created. The commands permanently delete objects in the specified bucket. Verify the name before continuing. This cleanup assumes the bucket contains only this lab and versioning was never enabled.

### Cleanup A — Remove CloudFront, if created

**Console equivalent:** Disable the distribution → wait until deployed → delete it → delete its unused OAC.

Run in the project directory with `project.env` loaded. Skip this entire block if you did not create CloudFront.

```bash
: "${DISTRIBUTION_ID:?Load project.env first}"
: "${OAC_ID:?Load project.env first}"

# Obtain the current configuration and concurrency token (ETag).
aws cloudfront get-distribution-config --id "$DISTRIBUTION_ID" > cf-current.json
export CF_ETAG="$(python3 -c 'import json; print(json.load(open("cf-current.json"))["ETag"])')"
python3 - <<'PY'
import json
from pathlib import Path
config = json.loads(Path("cf-current.json").read_text())["DistributionConfig"]
config["Enabled"] = False
Path("cf-disabled.json").write_text(json.dumps(config))
PY

aws cloudfront update-distribution \
  --id "$DISTRIBUTION_ID" --if-match "$CF_ETAG" \
  --distribution-config file://cf-disabled.json
aws cloudfront wait distribution-deployed --id "$DISTRIBUTION_ID"

# Fetch a fresh ETag after the update, then delete the disabled distribution.
export CF_ETAG="$(aws cloudfront get-distribution-config \
  --id "$DISTRIBUTION_ID" --query ETag --output text)"
aws cloudfront delete-distribution --id "$DISTRIBUTION_ID" --if-match "$CF_ETAG"

export OAC_ETAG="$(aws cloudfront get-origin-access-control \
  --id "$OAC_ID" --query ETag --output text)"
aws cloudfront delete-origin-access-control --id "$OAC_ID" --if-match "$OAC_ETAG"
```

Waiters can time out. If that happens, inspect the distribution in the Console and retry the waiter; do not recreate the distribution. If OAC deletion briefly reports it is in use after distribution deletion, retry after the deletion propagates.

### Cleanup B — Empty and delete S3

**Console equivalent:** S3 → select the lab bucket → Empty → Delete.

```bash
: "${BUCKET_NAME:?Load project.env first}"
printf 'This will permanently delete all objects in bucket: %s\n' "$BUCKET_NAME"
read -r -p "Type the exact bucket name to confirm: " CONFIRM_BUCKET
if [ "$CONFIRM_BUCKET" = "$BUCKET_NAME" ]; then
  aws s3 rm "s3://$BUCKET_NAME/" --recursive
  aws s3api delete-bucket --bucket "$BUCKET_NAME" --region "$AWS_REGION"
else
  printf 'Cleanup cancelled.\n'
fi
```

If versioning was enabled later, `s3 rm` does not remove historical versions or delete markers; use the Console's Empty operation and verify the bucket is empty before deletion. Also remove optional paid resources you separately created, such as a Route 53 hosted zone. Domain registration has its own renewal settings.

## Troubleshooting

| Symptom | Likely cause / next check |
|---|---|
| AccessDenied while creating/configuring | Wrong identity, missing IAM action, permission boundary, or organization restrictions |
| Bucket name already exists | Bucket names are globally unique; initialize a new project name |
| Public policy rejected | Account/organization Block Public Access; use private CloudFront |
| S3 homepage returns 403 | Public policy/settings, missing homepage, or wrong endpoint |
| S3 returns 404 | Case-sensitive filename, index setting, or file uploaded under a folder |
| HTTPS fails on S3 website URL | Use the CloudFront HTTPS hostname |
| CloudFront returns 403 | OAC not attached, wrong origin, bucket policy ARN, missing object, or deployment incomplete |
| Homepage works but nested routes fail | This lab uses plain HTML paths; SPA fallback routing requires additional configuration |
| CloudFront displays old content | Cached content; invalidate changed paths and wait for completion |
| Missing page has status 403 after upgrade | Private S3 may hide object existence; the guide preserves that status with the error page |
| CLI variables disappear | Resume from the project directory with `source project.env` |
| CloudFront waiter times out | Check deployment status, then rerun the waiter |

## Optional next projects

1. Add a custom domain, a DNS record, and an ACM certificate for CloudFront (request that certificate in `us-east-1`).
2. Track the website in Git.
3. Automate deployment with GitHub Actions and AWS OIDC instead of stored access keys.
4. Recreate the infrastructure using Terraform or CloudFormation.

## Completion checklist

- [ ] Confirmed the target AWS account and configured cost alerts.
- [ ] Created and uploaded the homepage and error page.
- [ ] Tested direct S3 hosting, if account policies permit it.
- [ ] Can explain `s3:GetObject` and why public read does not permit writes.
- [ ] Deployed a content update.
- [ ] Optional: CloudFront HTTPS works while S3 remains private.
- [ ] Recorded the resource IDs and cleaned up when finished.

## Official references

- [S3 static website tutorial](https://docs.aws.amazon.com/AmazonS3/latest/userguide/HostingWebsiteOnS3Setup.html)
- [S3 website permissions](https://docs.aws.amazon.com/AmazonS3/latest/userguide/WebsiteAccessPermissionsReqd.html)
- [S3 website endpoints and HTTP limitation](https://docs.aws.amazon.com/AmazonS3/latest/userguide/WebsiteEndpoints.html)
- [AWS CLI setup](https://docs.aws.amazon.com/cli/latest/userguide/getting-started-quickstart.html)
- [CloudShell getting started](https://docs.aws.amazon.com/cloudshell/latest/userguide/getting-started.html)
- [S3 Block Public Access CLI](https://docs.aws.amazon.com/cli/latest/reference/s3api/put-public-access-block.html)
- [CloudFront OAC and restricted bucket policy](https://docs.aws.amazon.com/AmazonCloudFront/latest/DeveloperGuide/private-content-restricting-access-to-s3.html)
- [CloudFront create-distribution CLI](https://docs.aws.amazon.com/cli/latest/reference/cloudfront/create-distribution.html)
- [AWS Budgets](https://docs.aws.amazon.com/cost-management/latest/userguide/budgets-managing-costs.html)
- [S3 pricing](https://aws.amazon.com/s3/pricing/)
- [CloudFront pricing](https://aws.amazon.com/cloudfront/pricing/)

Validation: Bash blocks were checked locally for shell syntax. No AWS resources were created and no live account deployment was tested.
