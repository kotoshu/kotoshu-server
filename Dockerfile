# syntax=docker/dockerfile:1.7

ARG RUBY_VERSION=3.4
FROM ruby:${RUBY_VERSION}-slim AS builder

ARG KOTOSHU_SERVER_VERSION=""
ARG KOTOSHU_PREWARM_LANGS="en"

RUN apt-get update \
    && apt-get install -y --no-install-recommends git ca-certificates \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /build
COPY . .

RUN if [ -n "$KOTOSHU_SERVER_VERSION" ]; then \
      gem install kotoshu-server --version "$KOTOSHU_SERVER_VERSION" --no-document; \
    else \
      gem install kotoshu-server --no-document; \
    fi

# kotoshu 1.0.2+ resolves the precompiled x86_64-linux platform gem,
# so this slim builder carries the Rust engine with no toolchain.
# Assert it: a silent fallback to a source install would mean the
# platform gem stopped resolving (plan 133's docker gate).
RUN ruby -e 'require "kotoshu"; abort "native engine missing - platform gem not resolved" unless Kotoshu::Native.available?'

RUN mkdir -p /root/.cache/kotoshu \
    && for lang in $KOTOSHU_PREWARM_LANGS; do \
         ruby -e "require 'kotoshu'; Kotoshu.setup(:$lang)" || echo "pre-warm $lang failed"; \
       done


FROM ruby:${RUBY_VERSION}-slim AS runtime

COPY --from=builder /usr/local/bundle /usr/local/bundle
COPY --from=builder /root/.cache/kotoshu /root/.cache/kotoshu

WORKDIR /app

ENV KOTOSHU_OFFLINE=1 \
    XDG_CACHE_HOME=/root/.cache \
    KOTOSHU_SERVER_PORT=9292 \
    KOTOSHU_SERVER_BIND=0.0.0.0 \
    LANG=C.UTF-8

EXPOSE 9292

HEALTHCHECK --interval=30s --timeout=3s --start-period=5s --retries=3 \
    CMD ruby -rnet/http -e \
      'exit Net::HTTP.get(URI("http://127.0.0.1:9292/v1/health")).include?("ok") ? 0 : 1' \
    || exit 1

ENTRYPOINT ["kotoshu-server"]
CMD []
