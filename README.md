# Create Docker image tag using Registry v2 API

Creates docker registry tags without requiring locally running Docker Daemon using Docker Registry v2 API.

The layers need to exist, otherwise this won't work, the script pushes only manifest.

Tested with GitLab CI:

```yml
variables:
  CONTAINER_BUILD_IMAGE: $CI_REGISTRY_IMAGE/builds:$CI_PIPELINE_ID-$CI_COMMIT_REF_SLUG
  CONTAINER_PRODUCTION_IMAGE: $CI_REGISTRY_IMAGE/production:$CI_PIPELINE_ID-$CI_COMMIT_REF_SLUG

deploy:
  when: manual
  script:
    - docker-create-tag -u gitlab-ci-token -p $CI_JOB_TOKEN $CONTAINER_BUILD_IMAGE $CONTAINER_PRODUCTION_IMAGE
```
