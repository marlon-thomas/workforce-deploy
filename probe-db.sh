#!/bin/bash
cd /opt/workforce-deploy
docker compose exec -T authentik-postgres psql -U authentik -d authentik -c "select slug from authentik_core_application" -c "select client_id from authentik_providers_oauth2_oauth2provider" 2>&1 | tail -6
