Gitlab Merger
===

Try
---
```
docker run -d --name gitlab-merger \
    -e GITLAB_API_TOKEN=<TOKEN> \
    -e GITLAB_ENDPOINT=https://<HOST>/ \
    -e GIT_AUTO_MERGE='release/*:master hotfix/*:master feature/*:develop' \
    -e GIT_AUTO_TAG='release/*:master hotfix/*:master'
    -e GIT_PUT_FILE='auto/*' \
    xiaopal/gitlab-merger:latest

docker exec gitlab-merger secret

```
