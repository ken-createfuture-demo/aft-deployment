#!/usr/bin/env bash
# ---------------------------------------------------------------------------
#  AFT clean-up helper - HARDENED VERSION
#  Repeatedly empties versioned buckets + waits for backup vault to clear
# ---------------------------------------------------------------------------

read -r -d '' BUCKETS <<'EOF'
aft-backend-149781123609-primary-region        aft-management
aft-backend-149781123609-secondary-region      aft-management
aft-customizations-pipeline-149781123609       aft-management
aws-aft-s3-access-logs-629830530842-eu-west-2  aft-log-acct
EOF

VAULT_NAME="aft-controltower-backup-vault"
REGION="eu-west-2"
VAULT_PROFILE="aft-management"

set -eo pipefail  # Removed -u flag
export AWS_PAGER=""

empty_bucket() {
  local bucket="$1"
  local profile="$2"

  echo -e "\n🗑  Emptying \e[1m$bucket\e[0m (profile: $profile)…"

  if ! aws s3api head-bucket --bucket "$bucket" --profile "$profile" 2>/dev/null; then
    echo "⚠️  Bucket $bucket does not exist or is not accessible"
    return 0
  fi

  # Delete all object versions and delete markers
  echo "  Removing all versions and delete markers..."
  local retry_count=0
  local max_retries=5

  while [ $retry_count -lt $max_retries ]; do
    local objects_found=false

    # Get and delete versions
    local versions
    versions=$(aws s3api list-object-versions --bucket "$bucket" --profile "$profile" \
      --query 'Versions[].{Key:Key,VersionId:VersionId}' --output json 2>/dev/null || echo "[]")

    local version_count
    version_count=$(echo "$versions" | jq 'length' 2>/dev/null || echo "0")

    if [ "$version_count" -gt 0 ]; then
      objects_found=true
      echo "  Deleting $version_count versions..."

      local delete_payload
      delete_payload=$(echo "$versions" | jq '{Objects: ., Quiet: true}' 2>/dev/null)

      if [ -n "$delete_payload" ]; then
        local tmp_file
        tmp_file=$(mktemp)
        echo "$delete_payload" > "$tmp_file"
        aws s3api delete-objects --bucket "$bucket" --profile "$profile" --delete "file://$tmp_file" >/dev/null 2>&1 || true
        rm -f "$tmp_file"
      fi
    fi

    # Get and delete delete markers
    local markers
    markers=$(aws s3api list-object-versions --bucket "$bucket" --profile "$profile" \
      --query 'DeleteMarkers[].{Key:Key,VersionId:VersionId}' --output json 2>/dev/null || echo "[]")

    local marker_count
    marker_count=$(echo "$markers" | jq 'length' 2>/dev/null || echo "0")

    if [ "$marker_count" -gt 0 ]; then
      objects_found=true
      echo "  Deleting $marker_count delete markers..."

      local delete_payload
      delete_payload=$(echo "$markers" | jq '{Objects: ., Quiet: true}' 2>/dev/null)

      if [ -n "$delete_payload" ]; then
        local tmp_file
        tmp_file=$(mktemp)
        echo "$delete_payload" > "$tmp_file"
        aws s3api delete-objects --bucket "$bucket" --profile "$profile" --delete "file://$tmp_file" >/dev/null 2>&1 || true
        rm -f "$tmp_file"
      fi
    fi

    if [ "$objects_found" = false ]; then
      break
    fi

    retry_count=$((retry_count + 1))
    sleep 2
  done

  # Try to delete the bucket
  echo "  Deleting bucket $bucket…"
  if aws s3api delete-bucket --bucket "$bucket" --profile "$profile" 2>/dev/null; then
    echo "✅  $bucket removed successfully"
  else
    echo "⚠️  Could not delete $bucket (may still contain objects or have other dependencies)"
  fi
}

purge_backup_vault() {
  echo -e "\n========== STEP 2: purge backup vault =========="
  echo "Vault: $VAULT_NAME | Region: $REGION | Profile: $VAULT_PROFILE"

  if ! aws backup describe-backup-vault --backup-vault-name "$VAULT_NAME" \
      --region "$REGION" --profile "$VAULT_PROFILE" >/dev/null 2>&1; then
    echo "⚠️  Vault not found"
    return 0
  fi

  local max_attempts=10
  local attempt=1

  while [ $attempt -le $max_attempts ]; do
    echo "  Attempt $attempt/$max_attempts to clear recovery points..."

    local recovery_points
    recovery_points=$(aws backup list-recovery-points-by-backup-vault \
      --backup-vault-name "$VAULT_NAME" --region "$REGION" \
      --profile "$VAULT_PROFILE" --query 'RecoveryPoints[].RecoveryPointArn' --output text 2>/dev/null || echo "")

    if [ -z "$recovery_points" ] || [ "$recovery_points" = "None" ]; then
      echo "  ✅ No recovery points left"
      break
    fi

    for arn in $recovery_points; do
      echo "  • deleting recovery point: $arn"
      aws backup delete-recovery-point \
        --backup-vault-name "$VAULT_NAME" --recovery-point-arn "$arn" \
        --region "$REGION" --profile "$VAULT_PROFILE" 2>/dev/null || echo "  ⚠️  Failed or already deleted: $arn"
    done

    echo "  Waiting 30 seconds for recovery point deletions to propagate..."
    sleep 30
    attempt=$((attempt + 1))
  done

  # Try to delete the vault
  echo "  Deleting backup vault..."
  if aws backup delete-backup-vault \
      --backup-vault-name "$VAULT_NAME" --region "$REGION" --profile "$VAULT_PROFILE" 2>/dev/null; then
    echo "✅  Vault deleted successfully"
  else
    echo "⚠️  Could not delete vault (may still contain recovery points - retry the script)"
  fi
}

echo "========== STEP 1: purge buckets =========="
while read -r bucket profile; do
  [ -z "$bucket" ] || [ -z "$profile" ] && continue
  empty_bucket "$bucket" "$profile" || echo "❌  Failed to empty $bucket"
done <<< "$BUCKETS"

purge_backup_vault
echo -e "\n🎉  Cleanup completed — you may need to run this script again if recovery points are still being deleted"
echo "After this completes, run: terraform destroy"