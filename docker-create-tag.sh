#!/bin/sh
# Create Docker image tag using Registry v2 API.
#
# Author: Elan Ruusamäe <glen@pld-linux.org>
# URL: https://gist.github.com/glensc/b14b4af29942fc2f22ea36682b860f8f
#
# Requires:
# - curl
# - jq
#
# This is tested against GitLab Registry

set -eu

PROGRAM=${0##*/}

# defaults
: ${DOCKER_REGISTRY_AUTH_TOKEN_URL='https://gitlab.example.net/jwt/auth'}
: ${USERNAME=''}
: ${PASSWORD=''}
: ${SOURCE_IMAGE=''}
: ${TARGET_IMAGE=''}

die() {
	echo >&2 "$PROGRAM: ERROR: $*"
	exit 1
}

usage() {
cat <<-EOF
$PROGRAM - Create Docker image tag using Registry v2 API

Usage: $PROGRAM <source_image> <target_image>

Flags:

  -u, --username       username for the registry (default: ${USERNAME:-<none>})
  -p, --password       password for the registry (default: ${PASSWORD:-<none>})
  --auth-url           url to auth token issuer (default: ${DOCKER_REGISTRY_AUTH_TOKEN_URL:-<none>})

Commands:

  tag       Create tag

Examples:

$PROGRAM registry.example.net/alpine:latest registry.example.net/alpine:recent

EOF
}

request_bearer() {
	local token="$1" url="$2"
	shift 2

	curl -sSf -H "Authorization: Bearer ${token}" "${url}" "$@"
}

get_token() {
	local scope="$1" response; shift

	if [ -n "$USERNAME" ]; then
		set -- --user "${USERNAME}:${PASSWORD}" "$@"
	fi

	response=$(curl -sSf "$@" "$DOCKER_REGISTRY_AUTH_TOKEN_URL?client_id=docker&offline_token=true&service=container_registry&scope=$scope")
	echo "$response" | jq -r .token
}

get_repo_token() {
	local repo="$1"

	get_token "repository:$repo:*"
}

# parses registry.example.net/alpine:latest into
# - registry
# - image
# - tag
parse_image() {
	local origin="$1"
	registry=${origin%%/*}
	image=${origin#$registry/}
	tag=${image##*:}
	image=${image%:$tag}
}

parse_options() {
	local t
	t=$(getopt -o u:p:h --long user:,password:,auth-url:,help -n "$PROGRAM" -- "$@")
	[ $? != 0 ] && exit $?
	eval set -- "$t"

	while :; do
		case "$1" in
		-h|--help)
			usage
			exit 0
			;;
		-u|--user)
			shift
			USERNAME="$1"
			;;
		-p|--password)
			shift
			PASSWORD="$1"
			;;
		--auth-url)
			shift
			DOCKER_REGISTRY_AUTH_TOKEN_URL="$1"
			;;
		--)
			shift
			break
			;;
		*)
			die "Internal error: [$1] not recognized!"
			;;
		esac
		shift
	done

	test "$#" -eq 2 || die "Images not specified or excess arguments"
	SOURCE_IMAGE="$1"
	TARGET_IMAGE="$2"
}

main() {
	local source_image="${1}" target_image="${2}"
	local registry image tag token manifest

	manifest=$(mktemp)

	parse_image "$source_image"
	token=$(get_repo_token "$image")
	request_bearer "$token" "https://$registry/v2/$image/manifests/$tag" \
		-H 'accept: application/vnd.docker.distribution.manifest.v2+json' \
		> $manifest

	parse_image "$target_image"
	token=$(get_repo_token "$image")
	request_bearer "$token" "https://$registry/v2/$image/manifests/$tag" \
		-H 'content-type: application/vnd.docker.distribution.manifest.v2+json' \
		-XPUT -d "@$manifest"

	rm $manifest

	echo "Created tag: $source_image -> $target_image"
}

parse_options "$@"
main "$SOURCE_IMAGE" "$TARGET_IMAGE"
