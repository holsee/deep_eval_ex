# Matches .tool-versions (elixir 1.19.5 / erlang 28.4) and the CI matrix.
FROM hexpm/elixir:1.19.5-erlang-28.4-debian-bookworm-20260610

ARG DEEPEVAL_VERSION=4.3.1

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
       build-essential ca-certificates curl git inotify-tools \
       python3 python3-venv \
    && rm -rf /var/lib/apt/lists/*

# Reference Python deepeval, used only to generate export-format parity fixtures
# (see test/fixtures/deepeval and scripts/parity).
RUN python3 -m venv /opt/deepeval \
    && /opt/deepeval/bin/pip install --no-cache-dir "deepeval==${DEEPEVAL_VERSION}"
ENV PATH="/opt/deepeval/bin:${PATH}" \
    DEEPEVAL_TELEMETRY_OPT_OUT=1

RUN mix local.hex --force && mix local.rebar --force

WORKDIR /workspace
