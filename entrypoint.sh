#!/bin/sh -l

set -ex

if [ -n "$INPUT_PATH" ]; then
  # Allow user to change directories in which to run Fly commands.
  cd "$INPUT_PATH" || exit
fi

PR_NUMBER=$(jq -r .number /github/workflow/event.json)
if [ -z "$PR_NUMBER" ]; then
  echo "This action only supports pull_request actions."
  exit 1
fi

REPO_NAME=$(echo $GITHUB_REPOSITORY | tr "/" "-")
EVENT_TYPE=$(jq -r .action /github/workflow/event.json)

# Default the Fly app name to pr-{number}-{repo_name}
app="${INPUT_NAME:-pr-$PR_NUMBER-$REPO_NAME}"
# Default the Fly DB app name to pr-{number}-{repo_name}-db
db_app="$app-db"
org="${INPUT_ORG:-${FLY_ORG:-personal}}"
image="$INPUT_IMAGE"
config="${INPUT_CONFIG:-fly.toml}"

if ! echo "$app" | grep "$PR_NUMBER"; then
  echo "For safety, this action requires the app's name to contain the PR number."
  exit 1
fi

# PR was closed - remove the Fly app and DB app if one exists and exit.
if [ "$EVENT_TYPE" = "closed" ]; then
  flyctl apps destroy "$app" -y || true
  flyctl apps destroy "$db_app" -y || true
  exit 0
fi

# Check if the app already exists.
if flyctl status --app "$app"; then
  existing_app=true
else
  existing_app=false
  # Backup the original config file since 'flyctl launch' messes up the [build.args] section
  cp "$config" "$config.bak"
  flyctl launch --no-deploy --copy-config --name "$app" --image "$image" --org "$org"
  # Restore the original config file
  cp "$config.bak" "$config"
fi

# Always attach postgres so DATABASE_URL is set, even if a prior run failed
# before reaching this step. Safe to run repeatedly — errors are suppressed.
if [ -n "$INPUT_POSTGRES" ]; then
  flyctl postgres attach --app "$app" "$INPUT_POSTGRES" || true
fi

# Always import secrets on every deploy so that new or rotated secrets are
# present before the release command runs.
if [ -n "$INPUT_SECRETS" ]; then
  echo $INPUT_SECRETS | tr " " "\n" | flyctl secrets import --app "$app"
fi

# Deploy: always for new apps, respects INPUT_UPDATE for existing ones.
if [ "$existing_app" = "false" ] || [ "$INPUT_UPDATE" != "false" ]; then
  flyctl deploy --config "$config" --app "$app" --strategy immediate --ha=false
fi

# Scale the VM
if [ -n "$INPUT_VM" ]; then
  flyctl scale --app "$app" vm "$INPUT_VM"
fi
if [ -n "$INPUT_MEMORY" ]; then
  flyctl scale --app "$app" memory "$INPUT_MEMORY"
fi
if [ -n "$INPUT_COUNT" ]; then
  flyctl scale --app "$app" count "$INPUT_COUNT"
fi

# Make some info available to the GitHub workflow.
flyctl status --app "$app" --json >status.json
hostname=$(jq -r .Hostname status.json)
appid=$(jq -r .ID status.json)
echo "hostname=$hostname" >> $GITHUB_OUTPUT
echo "url=https://$hostname" >> $GITHUB_OUTPUT
echo "id=$appid" >> $GITHUB_OUTPUT
echo "name=$app" >> $GITHUB_OUTPUT
