Gitlab Merger
===

Try
---
```
docker run -d --name gitlab-merger \
    -e GITLAB_API_TOKEN=<TOKEN> \
    -e GITLAB_ENDPOINT=https://<HOST>/ \
    -e GIT_AUTO_MERGE='release/*:master hotfix/*:master feature/*:develop auto/*:master' \
    -e GIT_AUTO_TAG='release/*:master hotfix/*:master'
    -e GIT_PUT_FILE='auto/*' \
    -p 9999:80 \
    xiaopal/gitlab-merger:latest

docker exec gitlab-merger setup --webhook 'http://webhook-endpoint:9999/' <project>

```
