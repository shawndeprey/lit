# Release Cut
All releases must update the version in `addons/lit/plugin.cfg`

A release must be tagged prior to uploading to the Asset Library.
```
git tag -a v1.1.1 -m "Release v1.1.1"
git push origin --tags
```

For uploading to the asset store, we need an archive of the repo.
```
git archive --format=zip --output=release.zip HEAD
```
