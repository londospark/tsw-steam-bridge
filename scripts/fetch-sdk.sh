#!/usr/bin/env bash
# Pulls the vendored Steamworks SDK into vendor/sdk/ from the private
# companion repo, instead of re-downloading and re-extracting
# steamworks_sdk.zip from the Steamworks partner site by hand.
#
# Requires SSH access to github.com/londospark/tsw-steam-bridge-vendor,
# which is private to the project owner (it holds Valve's SDK, not meant
# for public redistribution). On a new machine: `gh auth login` or an
# equivalent SSH key set up for GitHub, then run this script.
#
# If you're not the project owner, see README.md's "Vendoring the
# Steamworks SDK" section for the manual download instead.
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."

vendor_repo="git@github.com:londospark/tsw-steam-bridge-vendor.git"

if [ -d vendor/sdk/.git ]; then
    echo "vendor/sdk already present, pulling latest..."
    git -C vendor/sdk pull --ff-only
else
    echo "cloning Steamworks SDK into vendor/sdk..."
    rm -rf vendor/sdk
    mkdir -p vendor
    git clone "$vendor_repo" vendor/sdk
fi

echo "done: vendor/sdk/public and vendor/sdk/redistributable_bin should now exist."
