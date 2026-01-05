#!/usr/bin/env bash
# This repo now includes an improved deployment script: deploy-robust-v1.sh
# Run the improved script with: sudo bash ./deploy-robust-v1.sh

if [ -f ./deploy-robust-v1.sh ]; then
    echo "Found deploy-robust-v1.sh. To run the improved deploy script execute: sudo bash ./deploy-robust-v1.sh"
else
    echo "deploy-robust-v1.sh not found. You can restore the original with: mv deploy.sh.bak deploy.sh && bash deploy.sh"
fi

exit 0
