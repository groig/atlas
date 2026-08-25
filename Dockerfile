# syntax=docker/dockerfile:1

# Development image for Track / Atlas.
#
# This is deliberately *not* a production release build: the working tree is
# bind-mounted over /app at run time and the app runs under `mix phx.server`,
# so code reloading and the esbuild/tailwind watchers work as they do on a
# host. Dependencies, build artefacts and node_modules are baked in here and
# then shadowed by named volumes, which Docker seeds from these image layers.

FROM hexpm/elixir:1.19.5-erlang-28.4.3-debian-bookworm-20260824-slim

# build-essential  some hex packages compile native code
# ca-certificates  hex.pm / GitHub over TLS
# curl             container health check against /health
# git              the heroicons dependency is a git dep (see mix.exs)
# inotify-tools    Phoenix live reload watches the bind-mounted source
# nodejs, npm      `mix assets.setup` runs `npm install` in assets/
RUN apt-get update -y \
  && apt-get install -y --no-install-recommends \
     build-essential \
     ca-certificates \
     curl \
     git \
     inotify-tools \
     nodejs \
     npm \
  && rm -rf /var/lib/apt/lists/*

ENV LANG=C.UTF-8 MIX_ENV=dev HOME=/home/dev

# MIX_HOME/HEX_HOME live outside /app because the bind mount would otherwise
# hide the installed hex. TMPDIR is where LiveView buffers .osf uploads before
# they are copied into storage, so it gets its own volume in docker-compose.yml.
ENV MIX_HOME=/opt/mix HEX_HOME=/opt/hex TMPDIR=/data/tmp

# Run as the invoking host user so files written into the bind-mounted working
# tree (ExUnit's tmp_dir, for instance) are not left owned by root.
ARG UID=1000
ARG GID=1000
RUN getent group ${GID} >/dev/null || groupadd --gid ${GID} dev \
  && getent passwd ${UID} >/dev/null \
     || useradd --uid ${UID} --gid ${GID} --no-create-home --shell /bin/bash dev \
  && mkdir -p /app /home/dev /opt/mix /opt/hex /data/track_analyzer /data/tmp \
  && chown -R ${UID}:${GID} /app /home/dev /opt/mix /opt/hex /data

COPY docker/dev-entrypoint.sh /usr/local/bin/dev-entrypoint
RUN chmod 0755 /usr/local/bin/dev-entrypoint

USER ${UID}:${GID}
WORKDIR /app

RUN mix local.hex --force && mix local.rebar --force

# Warm the caches in dependency order so day-to-day edits do not invalidate them.
COPY --chown=${UID}:${GID} mix.exs mix.lock ./
RUN mix deps.get

COPY --chown=${UID}:${GID} config config
RUN mix deps.compile

# Installs the standalone tailwind/esbuild binaries into _build and runs
# `npm install` in assets/ (see the assets.setup alias in mix.exs).
COPY --chown=${UID}:${GID} assets/package.json assets/package-lock.json assets/
RUN mix assets.setup

EXPOSE 4000

ENTRYPOINT ["dev-entrypoint"]
CMD ["mix", "phx.server"]
