FROM ruby:3.4.6-slim

ARG RAILS_ENV=development

ENV APP_PATH=/var/app
ENV BUNDLE_VERSION=2.5.21
ENV BUNDLE_PATH=/usr/local/bundle/gems
ENV GEM_HOME=/usr/local/bundle/gems
ENV RAILS_LOG_TO_STDOUT=true
ENV RAILS_PORT=3000
ENV PATH="${BUNDLE_PATH}/bin:${PATH}"

RUN apt-get update -qq \
    && DEBIAN_FRONTEND=noninteractive apt-get upgrade -y -qq \
    && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
    curl \
    wget \
    build-essential \
    git \
    postgresql-client \
    libpq-dev \
    libxml2-dev \
    libxslt-dev \
    libyaml-dev \
    libgeos-dev libgeos++-dev \
    imagemagick \
    tzdata \
    less \
    libjemalloc2 libjemalloc-dev \
    cmake \
    ca-certificates \
    && mkdir -p $APP_PATH \
    && rm -rf /var/lib/apt/lists/*

RUN if [ "$(uname -m)" = "x86_64" ]; then \
    echo "/usr/lib/x86_64-linux-gnu/libjemalloc.so.2" > /etc/ld.so.preload; \
    else \
    echo "/usr/lib/aarch64-linux-gnu/libjemalloc.so.2" > /etc/ld.so.preload; \
    fi

ENV RUBY_YJIT_ENABLE=1

WORKDIR $APP_PATH

COPY Gemfile Gemfile.lock .ruby-version /vendor ./

COPY ./docker/web-entrypoint.devcontainer.sh /usr/local/bin/web-entrypoint.sh
COPY ./docker/sidekiq-entrypoint.devcontainer.sh /usr/local/bin/sidekiq-entrypoint.sh
RUN chmod +x /usr/local/bin/*.sh

EXPOSE $RAILS_PORT

ENTRYPOINT [ "bundle", "exec" ]