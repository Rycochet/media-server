# Notes for AI assistants

This folder is a checkout of https://github.com/Rycochet/media-server, and is
also a live install. Keep the two apart: `git status` should stay clean unless
the change is meant to be submitted to GitHub as a pull request.

## Files that belong to the repository

Only change these when the change is intended for a pull request:

- Top level files, like `compose.yaml`, `compose.extend.yaml`, `manage.sh`,
  `.env.example`, `compose.override.yaml.template` and `README.md`.
- Anything directly inside a service folder (`<folder>/*`), like its
  `compose*.yaml`, `manage.*.sh`, `*.template` and other scripts.

## Local changes

Changes for this install only go here, as they are ignored by `.gitignore`:

- `compose.override.yaml` - which services are turned on (the `include:` block,
  normally changed with `./manage.sh`), and settings for this install under
  `services:`.
- `.env` - the settings and secrets for this install. Never print its values.
- `.secret.*.txt` - the secrets from `.env`, written by `./manage.sh secrets` for
  the compose files to mount. Never print their contents.
- Subfolders of a service folder (`<folder>/*/*`), like `config/` or `data/`.

Before relying on a path being ignored, check it with
`git check-ignore -v <path>` - only the subfolders are ignored, not files
directly in `<folder>/`.

## Adding a service for this install only

Define it in `compose.override.yaml` under `services:` with an `x-` prefix on
the service name and `container_name` (like `x-example`), and keep its files in
a matching `x-<name>/` folder (like `x-example/config/`), which is ignored as a
whole. That way it never clashes with a service of the same name that is added
to the repository later.
