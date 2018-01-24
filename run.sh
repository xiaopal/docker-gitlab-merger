#!/usr/bin/dumb-init /bin/bash

echo "[ $(date -R) ] INFO - Starting Webhook..." >&2
nginx -qc /nginx.conf &
exec webhook -port 9999  -urlprefix '' -hooks /webhooks.yml
