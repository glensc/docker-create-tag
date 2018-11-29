#!/bin/sh
# Create Docker image tag using Registry v2 API.
#
# Author: Elan Ruusamäe <glen@pld-linux.org>
# URL: https://github.com/glensc/docker-create-tag
#
# Requires:
# - curl
# - jq
# - base64
#
# This is tested against GitLab Registry

set -eu

PROGRAM=${0##*/}

# defaults
: ${USERNAME=''}
: ${PASSWORD=''}
: ${SOURCE_IMAGE=''}
: ${TARGET_IMAGE=''}
: ${VERBOSE=0}

die() {
	echo >&2 "$PROGRAM: ERROR: $*"
	exit 1
}

print() {
	echo >&3 "$PS4$*"
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
	local method="$1" url="$2" rc out
	shift 2

	# try unauthenticated
	out=$(curl -sf -X "$method" "${url}" "$@") && rc=$? || rc=$?
	if [ "$rc" -eq "0" ]; then
		echo "$out"
		return 0
	fi

	# discover auth and retry
	local realm service scope token
	discover_auth "$url" -X "$method"

	token=$(get_token "$realm" "$service" "$scope")
	curl -sSf -m 10 -X "$method" -H "Authorization: Bearer ${token}" "${url}" "$@"
}

# https://devops.stackexchange.com/q/2731
# https://github.com/moby/moby/blob/v17.05.0-ce/contrib/download-frozen-image-v2.sh
download_layers() {
	local registry="$1" image="$2" manifest="$3" layersdir="$4"
	local digests digest url

	# download layers
	digests=$(jq -r '.layers[].digest' "$manifest")
	for digest in $digests; do
		url="https://$registry/v2/$image/blobs/$digest"
		print "Download digest: $url"
		request_url GET "$url" -o "$layersdir/${digest}.tgz" -L
		print "Done"
	done
	# download config
	digest=$(jq -r '.config.digest' "$manifest")
	request_url GET "https://$registry/v2/$image/blobs/$digest" \
		-o "$layersdir/config.json" -L
}

# https://docs.docker.com/registry/spec/api/#pushing-an-image
get_upload_url() {
	local uploads_url="$1" tmp

	tmp=$(mktemp)
	request_url POST "$uploads_url" -o "$tmp" -I
	upload_url=$(awk -v RS='\r\n' -F': ' 'tolower($1) == "location" { print $2 }' $tmp)
	rm $tmp

	# add '?' so could safely append parameters with '&'
	case "$upload_url" in
	*'?'*)
		:
		;;
	*)
		upload_url="$upload_url?"
		;;
	esac
}

get_filesize() {
	local filename="$1"

	stat -c "%s" "$filename"
}

upload_blob() {
	local digest="$1" file="$2"
	local url filesize status

	# HEAD /v2/<name>/blobs/<digest>
	url="https://$registry/v2/$image/blobs/$digest"
	print "Check HEAD $url"
	status=$(request_url HEAD "$url" -IL -w "%{http_code}" -o /dev/null 2>/dev/null) && rc=$? || rc=$?
	print "Status $status ($rc)"
	test "$status" = "200" && return

	get_upload_url "https://$registry/v2/$image/blobs/uploads/"
	url="$upload_url&digest=$digest"
	filesize=$(get_filesize "$file")
	print "[$digest] upload $file ($filesize bytes) to $url"
	request_url PUT "$url" --data-binary "@$file" \
		-m 900 \
		-H 'expect:' \
		-H 'connection: close' \
		-H 'content-type: application/octet-stream' \
		-H "content-length: $filesize"
}

upload_layers() {
	local registry="$1" image="$2" manifest="$3" layersdir="$4"
	local digests digest status url rc upload_url=''

	# upload layers
	digests=$(jq -r '.layers[].digest' "$manifest")
	for digest in $digests; do
		upload_blob "$digest" "$layersdir/$digest.tgz"
	done

	# upload config
	digest=$(jq -r '.config.digest' "$manifest")
	upload_blob "$digest" "$layersdir/config.json"
}

load_docker_credentials() {
	local registry="$1" config="${HOME}/.docker/config.json" token decoded

	# reset to globally provided values
	username="$USERNAME" password="$PASSWORD"

	test -f "$config" || return 0
	token=$(jq -er ".auths.\"${registry}\".auth" "$config") || return 0

	decoded=$(echo "$token" | base64 -d)

	# updates username, password which should be locally scoped from parent
	username=${decoded%%:*}
	password=${decoded#*:}
}

get_token() {
	local realm="$1" service="$2" scope="$3" response
	shift 3

	if [ -n "$username" ]; then
		set -- --user "$username:$password" "$@"
	fi

	response=$(curl -sSf "$@" "$realm?client_id=docker-create-tag&offline_token=true&service=$service&scope=$scope")
	echo "$response" | jq -r .token
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
	t=$(getopt -o u:p:hv --long user:,password:,help,verbose -n "$PROGRAM" -- "$@")
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
		-v|--verbse)
			VERBOSE=$((VERBOSE+1))
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

download_manifest() {
	local registry="$1" image="$2" tag="$3" url

	url="https://$registry/v2/$image/manifests/$tag"
	print "Download manifest: $url"
	request_url GET "$url" \
		-H 'accept: application/vnd.docker.distribution.manifest.v2+json' \
		|| die "Manifest download failed"
}

upload_manifest() {
	local registry="$1" image="$2" tag="$3" manifest="$4" url

	url="https://$registry/v2/$image/manifests/$tag"
	print "Upload manifest: $url"
	request_url PUT "$url" \
		-H 'content-type: application/vnd.docker.distribution.manifest.v2+json' \
		-d "@$manifest" || die "Manifest upload failed: $manifest"
}

main() {
	local source_image="${1}" target_image="${2}"
	local username password
	local registry image tag manifest layersdir

	if [ $VERBOSE -gt 0 ]; then
		exec 3>&1
	else
		exec 3>/dev/null
	fi

	manifest=$(mktemp)
	parse_image "$source_image"
	load_docker_credentials "$registry"
	download_manifest "$registry" "$image" "$tag" > "$manifest"
	layersdir=$(mktemp -d)
	download_layers "$registry" "$image" "$manifest" "$layersdir"

	parse_image "$target_image"
	load_docker_credentials "$registry"
	upload_layers "$registry" "$image" "$manifest" "$layersdir"
	upload_manifest "$registry" "$image" "$tag" "$manifest"

	rm -r "$layersdir"
	rm "$manifest"

	echo "Created tag: $source_image -> $target_image"
}

parse_options "$@"
main "$SOURCE_IMAGE" "$TARGET_IMAGE"
