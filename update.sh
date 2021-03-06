#!/bin/bash
set -Eeuo pipefail
shopt -s nullglob

declare -A gpgKeys=(
	# gpg: key 18ADD4FF: public key "Benjamin Peterson <benjamin@python.org>" imported
	[2.7]='C01E1CAD5EA2C4F0B8E3571504C367C218ADD4FF'
	# https://www.python.org/dev/peps/pep-0373/#release-manager-and-crew

	# gpg: key 36580288: public key "Georg Brandl (Python release signing key) <georg@python.org>" imported
	[3.3]='26DEA9D4613391EF3E25C9FF0A5B101836580288'
	# https://www.python.org/dev/peps/pep-0398/#release-manager-and-crew

	# gpg: key F73C700D: public key "Larry Hastings <larry@hastings.org>" imported
	[3.4]='97FC712E4C024BBEA48A61ED3A5CA953F73C700D'
	# https://www.python.org/dev/peps/pep-0429/#release-manager-and-crew

	# gpg: key F73C700D: public key "Larry Hastings <larry@hastings.org>" imported
	[3.5]='97FC712E4C024BBEA48A61ED3A5CA953F73C700D'
	# https://www.python.org/dev/peps/pep-0478/#release-manager-and-crew

	# gpg: key AA65421D: public key "Ned Deily (Python release signing key) <nad@acm.org>" imported
	[3.6]='0D96DF4D4110E5C43FBFB17F2D347EA6AA65421D'
	# https://www.python.org/dev/peps/pep-0494/#release-manager-and-crew
)

cd "$(dirname "$(readlink -f "$BASH_SOURCE")")"

versions=( "$@" )
if [ ${#versions[@]} -eq 0 ]; then
	versions=( */ )
fi
versions=( "${versions[@]%/}" )

pipVersion="$(curl -fsSL 'https://pypi.org/pypi/pip/json' | jq -r .info.version)"

generated_warning() {
	cat <<-EOH
		#
		# NOTE: THIS DOCKERFILE IS GENERATED VIA "update.sh"
		#
		# PLEASE DO NOT EDIT IT DIRECTLY.
		#

	EOH
}

travisEnv=
appveyorEnv=
for version in "${versions[@]}"; do
	rcVersion="${version%-rc}"
	rcGrepV='-v'
	if [ "$rcVersion" != "$version" ]; then
		rcGrepV=
	fi

	possibles=( $(curl -fsSL 'https://www.python.org/ftp/python/' | grep '<a href="'"$rcVersion." | sed -r 's!.*<a href="([^"/]+)/?".*!\1!' | sort -rV) )
	fullVersion=
	for possible in "${possibles[@]}"; do
		possibleVersions=( $(curl -fsSL "https://www.python.org/ftp/python/$possible/" | grep '<a href="Python-'"$rcVersion"'.*\.tar\.xz"' | sed -r 's!.*<a href="Python-([^"/]+)\.tar\.xz".*!\1!' | grep $rcGrepV -E -- '[a-zA-Z]+' | sort -rV) )
		if [ "${#possibleVersions[@]}" -gt 0 ]; then
			fullVersion="${possibleVersions[0]}"
			break
		fi
	done

	if [ -z "$fullVersion" ]; then
		{
			echo
			echo
			echo "  error: cannot find $version (alpha/beta/rc?)"
			echo
			echo
		} >&2
		exit 1
	else
		if [[ "$version" != 2.* ]]; then
			for variant in \
				debian \
				alpine \
				slim \
				onbuild \
				windows/windowsservercore \
			; do
				if [ "$variant" = 'debian' ]; then
					dir="$version"
				else
					dir="$version/$variant"
					variant="$(basename "$variant")"
				fi
				[ -d "$dir" ] || continue
				template="Dockerfile-$variant.template"
				{ generated_warning; cat "$template"; } > "$dir/Dockerfile"
			done
			if [ -d "$version/wheezy" ]; then
				cp "$version/Dockerfile" "$version/wheezy/Dockerfile"
				# wheezy-only: dpkg-architecture: unknown option `--query'
				sed -ri \
					-e 's/:jessie/:wheezy/g' \
					-e 's/dpkg-architecture --query /dpkg-architecture -q/g' \
					"$version/wheezy/Dockerfile"
			fi
		fi
		(
			set -x
			sed -ri \
				-e 's/^(ENV GPG_KEY) .*/\1 '"${gpgKeys[$rcVersion]}"'/' \
				-e 's/^(ENV PYTHON_VERSION) .*/\1 '"$fullVersion"'/' \
				-e 's/^(ENV PYTHON_RELEASE) .*/\1 '"${fullVersion%%[a-z]*}"'/' \
				-e 's/^(ENV PYTHON_PIP_VERSION) .*/\1 '"$pipVersion"'/' \
				-e 's/^(FROM python):.*/\1:'"$version"'/' \
				"$version"/{,*/,*/*/}Dockerfile
		)
	fi
	if [ -d "$version/alpine3.6" ]; then
		cp "$version/alpine/Dockerfile" "$version/alpine3.6/Dockerfile"
		sed -ri \
			-e 's/(alpine):3.4/\1:3.6/g' \
			-e 's/openssl/libressl/g' \
			"$version/alpine3.6/Dockerfile"
	fi
	for variant in wheezy alpine3.6 alpine slim ''; do
		[ -d "$version/$variant" ] || continue
		travisEnv='\n  - VERSION='"$version VARIANT=$variant$travisEnv"
	done
	for winVariant in windowsservercore nanoserver; do
		if [ -d "$version/windows/$winVariant" ]; then
			appveyorEnv='\n    - version: '"$version"'\n      variant: '"$winVariant$appveyorEnv"
		fi
	done
done

travis="$(awk -v 'RS=\n\n' '$1 == "env:" { $0 = "env:'"$travisEnv"'" } { printf "%s%s", $0, RS }' .travis.yml)"
echo "$travis" > .travis.yml

appveyor="$(awk -v 'RS=\n\n' '$1 == "environment:" { $0 = "environment:\n  matrix:'"$appveyorEnv"'" } { printf "%s%s", $0, RS }' .appveyor.yml)"
echo "$appveyor" > .appveyor.yml
