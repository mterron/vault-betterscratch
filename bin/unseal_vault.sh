#!/bin/ash
VAULT_ADDR="https://${HOSTNAME}.node.${CONSUL_DOMAIN:-consul}:8200" su-exec vault: vault operator unseal

