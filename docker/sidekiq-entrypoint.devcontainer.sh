#!/bin/sh

#unset BUNDLE_PATH
#unset BUNDLE_BIN

set -e

echo "⏳ Checking if gems are installed..."
# Loop until 'bundle check' succeeds
until bundle check > /dev/null 2>&1; do
  echo "📦 Gems are missing or being installed (bundle install)... waiting 5 seconds"
  sleep 5
done
echo "✅ Gems found! Proceeding with migrations..."

echo "⏳ Checking if node_modules are installed..."
# Loop until node_modules exists and is not empty
until [ -d "$APP_PATH/node_modules" ] && [ "$(ls -A $APP_PATH/node_modules 2>/dev/null)" ]; do
  echo "📦 node_modules missing or being installed (yarn install)... waiting 5 seconds"
  sleep 5
done
echo "✅ node_modules ready!"

echo "⚠️ Starting Sidekiq in $RAILS_ENV environment ⚠️"

# Parse DATABASE_URL if present, otherwise use individual variables
if [ -n "$DATABASE_URL" ]; then
  # Strip scheme (postgres:// or postgresql://)
  _db_url_stripped="${DATABASE_URL#*://}"
  # Split at '@' -> credentials @ host_path
  _db_credentials="${_db_url_stripped%%@*}"
  _db_host_path="${_db_url_stripped#*@}"
  # Extract username and password from credentials
  DATABASE_USERNAME="${_db_credentials%%:*}"
  DATABASE_PASSWORD="${_db_credentials#*:}"
  # Extract host_port and dbname from host_path
  _db_host_port="${_db_host_path%%/*}"
  DATABASE_NAME="${_db_host_path#*/}"
  # Split host and port (port may be absent)
  DATABASE_HOST="${_db_host_port%%:*}"
  if [ "$_db_host_port" != "$DATABASE_HOST" ]; then
    DATABASE_PORT="${_db_host_port#*:}"
  else
    DATABASE_PORT="5432"
  fi
fi

# Wait for the database to become available
echo "⏳ Waiting for database to be ready..."
until PGPASSWORD=$DATABASE_PASSWORD psql -h "$DATABASE_HOST" -p "$DATABASE_PORT" -U "$DATABASE_USERNAME" -d "$DATABASE_NAME" -c '\q'; do
  >&2 echo "Postgres is unavailable - retrying..."
  sleep 2
done
echo "✅ PostgreSQL is ready!"

# run sidekiq
# exec bundle exec sidekiq
#exec bundle exec rdbg --open --port 12346 --nonstop -c -- bundle exec sidekiq
export RUBY_DEBUG_OPEN=true
export RUBY_DEBUG_PORT=12346
export RUBY_DEBUG_HOST=0.0.0.0
export RUBY_DEBUG_NONSTOP=true

exec bundle exec sidekiq