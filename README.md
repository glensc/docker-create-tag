# Create Docker image tag using Registry v2 API

Creates docker registry tags without requiring locally running Docker Daemon using Docker Registry v2 API.

This is known to work within same registry server.

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
Alternatively, you can rely on `docker login` storing credentials to `~/.docker/config.json`

```yml
  script:
    - docker login -u gitlab-ci-token -p $CI_JOB_TOKEN $CI_REGISTRY
    - docker-create-tag $CONTAINER_BUILD_IMAGE $CONTAINER_PRODUCTION_IMAGE
```

## History

This project was created due [reg] tool [lacking the support][reg#88].

[reg]: https://github.com/genuinetools/reg
[reg#88]: https://github.com/genuinetools/reg/issues/88
