#!/usr/bin/env bash
if [ -z "${OP_SERVICE_ACCOUNT_TOKEN:-}" ] && [ -r "$HOME/.config/op/service-account-token" ]; then
  IFS= read -r OP_SERVICE_ACCOUNT_TOKEN <"$HOME/.config/op/service-account-token" || :
  export OP_SERVICE_ACCOUNT_TOKEN
fi
