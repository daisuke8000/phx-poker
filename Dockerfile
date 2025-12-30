# Build arguments
ARG ELIXIR_VERSION=1.17.3
ARG OTP_VERSION=27.1.1
ARG DEBIAN_VERSION=bullseye-20240926-slim

ARG BUILDER_IMAGE="hexpm/elixir:${ELIXIR_VERSION}-erlang-${OTP_VERSION}-debian-${DEBIAN_VERSION}"
ARG RUNNER_IMAGE="debian:${DEBIAN_VERSION}"

# =============================================================================
# Build stage
# =============================================================================
FROM ${BUILDER_IMAGE} AS builder

RUN apt-get update -y && apt-get install -y build-essential git \
    && apt-get clean && rm -rf /var/lib/apt/lists/*

WORKDIR /app

RUN mix local.hex --force && mix local.rebar --force

ENV MIX_ENV="prod"

# Install dependencies first (for Docker layer caching)
COPY mix.exs mix.lock ./
RUN mix deps.get --only $MIX_ENV
RUN mkdir config

# Copy config files
COPY config/config.exs config/${MIX_ENV}.exs config/
RUN mix deps.compile

# Copy assets and compile
COPY priv priv
COPY lib lib
COPY assets assets

# Compile first to generate colocated hooks
RUN mix compile
RUN mix assets.deploy

# Copy runtime config and build release
COPY config/runtime.exs config/
RUN mix release

# =============================================================================
# Runner stage
# =============================================================================
FROM ${RUNNER_IMAGE}

RUN apt-get update -y && apt-get install -y libstdc++6 openssl libncurses5 locales \
    && apt-get clean && rm -rf /var/lib/apt/lists/*

# Set locale
RUN sed -i '/en_US.UTF-8/s/^# //g' /etc/locale.gen && locale-gen

ENV LANG=en_US.UTF-8
ENV LANGUAGE=en_US:en
ENV LC_ALL=en_US.UTF-8

WORKDIR /app
RUN chown nobody /app

ENV MIX_ENV="prod"
ENV PHX_SERVER="true"

# Copy release from builder
COPY --from=builder --chown=nobody:root /app/_build/prod/rel/planning_poker ./

USER nobody

# Cloud Run uses PORT environment variable (default 8080)
EXPOSE 8080

CMD ["/app/bin/planning_poker", "start"]
