#!/usr/bin/env python3
#
# Description:  List all Unmatched and Incorrectly matched files.
# Author:       https://github.com/Rycochet
# Requires:     plexapi, python_dotenv, schedule
#
# Config via a .env file, PLEX_TOKEN, PLEX_URL (optional), PLEX_PATH<n> + PLEX_PATH<n>_REPLACE

import logging
import os
import schedule
import sys
import random

from dotenv import load_dotenv
from glob import glob
from plexapi.server import PlexServer
from time import sleep

load_dotenv()

TRUTHY = ["true", "1", "yes"]
isTTY = sys.stdout.isatty()

PLEX_TOKEN = os.getenv("PLEX_TOKEN")
PLEX_TOKEN_FILE = os.getenv("PLEX_TOKEN_FILE")
if PLEX_TOKEN_FILE:
    with open(PLEX_TOKEN_FILE) as f: PLEX_TOKEN = f.read().strip()
PLEX_URL = "https://plex.rycochet.net:443/"

LOG_LEVEL = os.getenv("LOG_LEVEL", "DEBUG").upper()

CHECK_LIBRARY = [library.strip() for library in os.getenv("CHECK_LIBRARY", "TV Shows").lower().split(",")]

CHECK_PATHS = {}
for i in range(9):
    if os.getenv(f'CHECK_PATH{i}') and os.getenv(f'CHECK_PATH{i}_REPLACE'):
        CHECK_PATHS[os.getenv(f'CHECK_PATH{i}')] = os.getenv(f'CHECK_PATH{i}_REPLACE')

logging.basicConfig(format='[%(asctime)s] [%(levelname)s] %(message)s')
logger = logging.getLogger(__name__)

if LOG_LEVEL == "DEBUG":
    logger.setLevel(logging.DEBUG)
elif LOG_LEVEL == "INFO":
    logger.setLevel(logging.INFO)
elif LOG_LEVEL == "WARN" or LOG_LEVEL == "WARNING":
    logger.setLevel(logging.WARNING)
elif LOG_LEVEL == "ERROR":
    logger.setLevel(logging.ERROR)

if not PLEX_TOKEN:
    logger.error("Error: You must supply a PLEX_TOKEN or PLEX_TOKEN_FILE env variable.")
    sys.exit(-1)

plex = PlexServer(PLEX_URL, PLEX_TOKEN)

for section in plex.library.sections():
    if not "*" in CHECK_LIBRARY and not section.title.lower() in CHECK_LIBRARY:
        continue

    # episodes = plex.search(filters = {"label": "overlay", "libtype": "episode"})
    episodes = section.search(label="overlay", libtype="episode")

    logger.info(f"Found {len(episodes)}")

    count = 0

    for episode in episodes:
        logger.info(f"Remove {episode.title}")

        episode.removeLabel("overlay")
