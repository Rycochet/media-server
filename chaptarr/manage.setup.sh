#!/bin/bash

# Use external authentication and save the API key in .env for homepage

exec bash "$(dirname "$MANAGE_SH")/servarr-setup.sh" "$@"
