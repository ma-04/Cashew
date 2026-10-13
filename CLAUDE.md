# Rules for Claude in this repository

## Pull requests

- This repository is a fork of `jameskokoska/Cashew`. NEVER open a pull request to the upstream repository.
- Open pull requests only on the fork `ma-04/Cashew`. With `gh pr create`, always give `--repo ma-04/Cashew --base main`.

## Builds

- Do not build APKs on the build server (fly@167.235.51.86). Its disk is almost full.
- To get a test build, push the branch to `origin` and run the "CI Build" workflow: `gh workflow run build.yml -R ma-04/Cashew --ref <branch>`.
