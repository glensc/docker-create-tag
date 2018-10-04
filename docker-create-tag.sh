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

Examples:

$PROGRAM registry.example.net/alpine:latest registry.example.net/alpine:recent

EOF
}

get_param() {
	local header="$1" param="$2"

	echo "$header" | sed -r -ne 's,.*'"$param"'="([^"]+)".*,\1,p'
}

discover_auth() {
	local url="$1" headers header
	shift

	headers=$(curl -sI "$url" "$@")
	header=$(echo "$headers" | grep -i '^Www-Authenticate:')

	# Need to extract realm, service and scope from "Www-Authenticate" header:
	# Www-Authenticate: Bearer realm="https://gitlab.example.net/jwt/auth",service="container_registry",scope="repository:ed/php:pull"
	realm=$(get_param "$header" realm)
	service=$(get_param "$header" service)
	scope=$(get_param "$header" scope)
}

request_url() {
	local method="$1" url="$2" rc
	shift 2

	# try unauthenticated
	curl -sf -X "$method" "${url}" "$@" && rc=$? || rc=$?
	if [ "$rc" -eq "0" ]; then
		return 0
	fi

	# discover auth and retry
	local realm service scope
	discover_auth "$url" -X "$method"

	token=$(get_token "$realm" "$service" "$scope")
	curl -sSf -X "$method" -H "Authorization: Bearer ${token}" "${url}" "$@"
}

get_token() {
	local realm="$1" service="$2" scope="$3"
	shift 3

	if [ -n "$USERNAME" ]; then
		set -- --user "${USERNAME}:${PASSWORD}" "$@"
	fi

	response=$(curl -sSf "$@" "$realm?client_id=docker-create-tag&offline_token=true&service=$service&scope=$scope")
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
	t=$(getopt -o u:p:h --long user:,password:,help -n "$PROGRAM" -- "$@")
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
	local registry image tag manifest

	manifest=$(mktemp)

	parse_image "$source_image"
	request_url GET "https://$registry/v2/$image/manifests/$tag" \
		-H 'accept: application/vnd.docker.distribution.manifest.v2+json' \
		> $manifest

	parse_image "$target_image"
	request_url PUT "https://$registry/v2/$image/manifests/$tag" \
		-H 'content-type: application/vnd.docker.distribution.manifest.v2+json' \
		-d "@$manifest"

	rm $manifest

	echo "Created tag: $source_image -> $target_image"
}

parse_options "$@"
main "$SOURCE_IMAGE" "$TARGET_IMAGE"
