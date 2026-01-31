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

set -euo pipefail
export AWS_PAGER=""

empty_bucket() {
  local bucket=$1 profile=$2
  echo -e "\n🗑  Emptying \e[1m$bucket\e[0m (profile: $profile)…"

  if ! aws s3api head-bucket --bucket "$bucket" --profile "$profile" 2>/dev/null; then
    echo "⚠️  Bucket $bucket does not exist or is not accessible"
    return 0
  fi

  while true; do
    # Paginate results (max 1000 per page)
    token=""
    objects_deleted=false

    while :; do
      resp=$(aws s3api list-object-versions --bucket "$bucket" --profile "$profile" \
        --max-items 1000 ${token:+--starting-token "$token"} --output json)

      versions=$(jq '.Versions // []' <<<"$resp")
      markers=$(jq '.DeleteMarkers // []' <<<"$resp")
      all_objects=$(jq -s 'add' <<<"$versions $markers")
      count=$(jq 'length' <<<"$all_objects")

      [[ "$count" -eq 0 ]] && break

      echo "  Deleting $count objects (page)…"
      delete_payload=$(jq '{Objects: ., Quiet: true}' <<<"$all_objects")
      tmp=$(mktemp)
      echo "$delete_payload" > "$tmp"
      aws s3api delete-objects --bucket "$bucket" --profile "$profile" --delete "file://$tmp" >/dev/null
      rm -f "$tmp"
      objects_deleted=true

      # Get next pagination token
      token=$(jq -r '.NextToken // empty' <<<"$resp")
      [[ -z "$token" ]] && break
    done

    # If no objects deleted in this full pass → bucket is empty
    [[ "$objects_deleted" == false ]] && break
    sleep 1
  done

  echo "  Deleting bucket $bucket…"
  aws s3api delete-bucket --bucket "$bucket" --profile "$profile" && \
    echo "✅  $bucket removed successfully"
}

purge_backup_vault() {
  echo -e "\n========== STEP 2: purge backup vault =========="
  echo "Vault: $VAULT_NAME | Region: $REGION | Profile: $VAULT_PROFILE"

  if ! aws backup describe-backup-vault --backup-vault-name "$VAULT_NAME" \
      --region "$REGION" --profile "$VAULT_PROFILE" >/dev/null 2>&1; then
    echo "⚠️  Vault not found"
    return 0
  fi

  while true; do
    recovery_points=$(aws backup list-recovery-points-by-backup-vault \
      --backup-vault-name "$VAULT_NAME" --region "$REGION" \
      --profile "$VAULT_PROFILE" --query 'RecoveryPoints[].RecoveryPointArn' --output text)

    if [[ -z "$recovery_points" || "$recovery_points" == "None" ]]; then
      echo "  ✅ No recovery points left"
      break
    fi

    for arn in $recovery_points; do
      echo "  • deleting recovery point: $arn"
      aws backup delete-recovery-point \
        --backup-vault-name "$VAULT_NAME" --recovery-point-arn "$arn" \
        --region "$REGION" --profile "$VAULT_PROFILE" || echo "  ❌ Failed: $arn"
      sleep 2
    done

    echo "  Waiting for recovery point deletions to propagate..."
    sleep 15
  done

  echo "  Deleting backup vault..."
  aws backup delete-backup-vault \
    --backup-vault-name "$VAULT_NAME" --region "$REGION" --profile "$VAULT_PROFILE" && \
    echo "✅  Vault deleted successfully"
}

echo "========== STEP 1: purge buckets =========="
while read -r bucket profile; do
  [[ -z "$bucket" || -z "$profile" ]] && continue
  empty_bucket "$bucket" "$profile" || echo "❌  Failed to empty $bucket"
done <<< "$BUCKETS"

purge_backup_vault
echo -e "\n🎉  Cleanup completed — safe to rerun terraform destroy"