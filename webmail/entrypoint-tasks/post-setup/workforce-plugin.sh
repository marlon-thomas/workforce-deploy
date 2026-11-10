#!/bin/sh
# Our workforce_identities plugin, into the web root the image has just filled or updated (compose.yaml mounts this
# folder as the image's entrypoint tasks). It runs at every start, as www-data, before Apache: the image copies
# Roundcube in itself, and its copy leaves out anything mounted into its source, so the plugin goes in after it.
set -eu
rm -rf /var/www/html/plugins/workforce_identities
cp -R /opt/workforce/plugins/workforce_identities /var/www/html/plugins/
