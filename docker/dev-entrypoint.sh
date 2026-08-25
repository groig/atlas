#!/usr/bin/env bash
# Prepares the container on every start, then runs the given command.
# Each step is idempotent and cheap once the named volumes are warm.
set -euo pipefail

echo "==> mix deps.get"
mix deps.get

echo "==> mix assets.setup"
mix assets.setup

# Not `mix ecto.setup`: priv/repo/seeds.exs is empty scaffolding.
echo "==> mix ecto.create"
mix ecto.create

echo "==> mix ecto.migrate"
mix ecto.migrate

echo "==> $*"
exec "$@"
