# Whichway public site

This folder is the content of the public repository
[`bdrumm/bdrumm.github.io`](https://github.com/bdrumm/bdrumm.github.io), the GitHub Pages user site
that serves the app's published data, the review site and the Atlas map at
**https://bdrumm.github.io/whichway/** after `bdrumm/whichway` went private (Nov 2026).

- `main` holds only `.github/workflows/pipeline.yml`, the hourly job that used to run in
  `bdrumm/whichway`. It checks out the private source with a deploy key, collects, builds and
  publishes. Public repositories run it without using paid Actions minutes.
- `gh-pages` is written by that job (force-pushed every hour, `live.json` every 6 minutes):
  `whichway/` is the site, `index.html` at the root redirects to it. Pages serves this branch.
- The `data` and `models` branches stay in the private `bdrumm/whichway`.

A user site serves `/whichway/` only while `bdrumm/whichway` has no Pages site of its own (a
project site wins over the user site's folder of the same name), so Pages stays off there.

## One-time setup (done Nov 2026)

```sh
gh repo create bdrumm/bdrumm.github.io --public --description "Whichway published data and map"
ssh-keygen -t ed25519 -N "" -C whichway-pipeline -f /tmp/whichway_deploy
gh repo deploy-key add /tmp/whichway_deploy.pub -R bdrumm/whichway --allow-write -t "public site pipeline"
gh secret set WHICHWAY_DEPLOY_KEY -R bdrumm/bdrumm.github.io < /tmp/whichway_deploy && rm /tmp/whichway_deploy*
# push this folder's .github/ to main, run the workflow once, then:
gh api -X POST repos/bdrumm/bdrumm.github.io/pages -f 'source[branch]=gh-pages' -f 'source[path]=/'
gh api -X DELETE repos/bdrumm/whichway/pages
```

To change the workflow, edit it here, merge, and copy it to `main` of the public repository.
