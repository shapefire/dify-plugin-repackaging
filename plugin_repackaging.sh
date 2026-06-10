#!/bin/bash
# author: Junjie.M

DEFAULT_GITHUB_API_URL=https://github.com
DEFAULT_MARKETPLACE_API_URL=https://marketplace.dify.ai
DEFAULT_PIP_MIRROR_URL=https://mirrors.aliyun.com/pypi/simple

GITHUB_API_URL="${GITHUB_API_URL:-$DEFAULT_GITHUB_API_URL}"
MARKETPLACE_API_URL="${MARKETPLACE_API_URL:-$DEFAULT_MARKETPLACE_API_URL}"
PIP_MIRROR_URL="${PIP_MIRROR_URL:-$DEFAULT_PIP_MIRROR_URL}"

CURR_DIR=`dirname $0`
cd $CURR_DIR || exit 1
CURR_DIR=`pwd`
USER=`whoami`
ARCH_NAME=`uname -m`
OS_TYPE=$(uname)
OS_TYPE=$(echo "$OS_TYPE" | tr '[:upper:]' '[:lower:]')

CMD_NAME="dify-plugin-${OS_TYPE}-amd64"
if [[ "arm64" == "$ARCH_NAME" || "aarch64" == "$ARCH_NAME" ]]; then
	CMD_NAME="dify-plugin-${OS_TYPE}-arm64"
fi

# Cross packaging / resolution controls
PIP_PLATFORM=""
RAW_PLATFORM=""    # raw value from -p, e.g. manylinux2014_x86_64
PACKAGE_SUFFIX="offline"
PRERELEASE_ALLOW=0

market(){
	if [[ -z "$2" || -z "$3" || -z "$4" ]]; then
		echo ""
		echo "Usage: "$0" market [plugin author] [plugin name] [plugin version]"
		echo "Example:"
		echo "	"$0" market junjiem mcp_sse 0.0.1"
		echo "	"$0" market langgenius agent 0.0.9"
		echo ""
		exit 1
	fi
	PLUGIN_AUTHOR=$2
	PLUGIN_NAME=$3
	PLUGIN_VERSION=$4
	PLUGIN_PACKAGE_PATH=${CURR_DIR}/${PLUGIN_AUTHOR}-${PLUGIN_NAME}_${PLUGIN_VERSION}.difypkg
	PLUGIN_DOWNLOAD_URL=${MARKETPLACE_API_URL}/api/v1/plugins/${PLUGIN_AUTHOR}/${PLUGIN_NAME}/${PLUGIN_VERSION}/download

	echo ""
	echo "=========================================="
	echo "Downloading from Dify Marketplace"
	echo "=========================================="
	echo "Author: ${PLUGIN_AUTHOR}"
	echo "Plugin: ${PLUGIN_NAME}"
	echo "Version: ${PLUGIN_VERSION}"
	echo "URL: ${PLUGIN_DOWNLOAD_URL}"

	curl -L -o ${PLUGIN_PACKAGE_PATH} ${PLUGIN_DOWNLOAD_URL}
	if [[ $? -ne 0 ]]; then
		echo "✗ Error: Download failed"
		echo "  Please check the plugin author, name, and version"
		exit 1
	fi

	DOWNLOADED_SIZE=$(du -h "${PLUGIN_PACKAGE_PATH}" | cut -f1)
	echo "✓ Downloaded successfully (${DOWNLOADED_SIZE})"

	repackage ${PLUGIN_PACKAGE_PATH}
}

github(){
	if [[ -z "$2" || -z "$3" || -z "$4" ]]; then
		echo ""
		echo "Usage: "$0" github [Github repo] [Release title] [Assets name (include .difypkg suffix)]"
		echo "Example:"
		echo "	"$0" github junjiem/dify-plugin-tools-dbquery v0.0.2 db_query.difypkg"
		echo "	"$0" github https://github.com/junjiem/dify-plugin-agent-mcp_sse 0.0.1 agent-mcp_see.difypkg"
		echo ""
		exit 1
	fi
	GITHUB_REPO=$2
	if [[ "${GITHUB_REPO}" != "${GITHUB_API_URL}"* ]]; then
		GITHUB_REPO="${GITHUB_API_URL}/${GITHUB_REPO}"
	fi
	RELEASE_TITLE=$3
	ASSETS_NAME=$4
	PLUGIN_NAME="${ASSETS_NAME%.difypkg}"
	PLUGIN_PACKAGE_PATH=${CURR_DIR}/${PLUGIN_NAME}-${RELEASE_TITLE}.difypkg
	PLUGIN_DOWNLOAD_URL=${GITHUB_REPO}/releases/download/${RELEASE_TITLE}/${ASSETS_NAME}

	echo ""
	echo "=========================================="
	echo "Downloading from GitHub"
	echo "=========================================="
	echo "Repository: ${GITHUB_REPO}"
	echo "Release: ${RELEASE_TITLE}"
	echo "Asset: ${ASSETS_NAME}"
	echo "URL: ${PLUGIN_DOWNLOAD_URL}"

	curl -L -o ${PLUGIN_PACKAGE_PATH} ${PLUGIN_DOWNLOAD_URL}
	if [[ $? -ne 0 ]]; then
		echo "✗ Error: Download failed"
		echo "  Please check the GitHub repo, release title, and asset name"
		exit 1
	fi

	DOWNLOADED_SIZE=$(du -h "${PLUGIN_PACKAGE_PATH}" | cut -f1)
	echo "✓ Downloaded successfully (${DOWNLOADED_SIZE})"

	repackage ${PLUGIN_PACKAGE_PATH}
}

_local(){
	echo $2
	if [[ -z "$2" ]]; then
		echo ""
		echo "Usage: "$0" local [difypkg path]"
		echo "Example:"
		echo "	"$0" local ./db_query.difypkg"
		echo "	"$0" local /root/dify-plugin/db_query.difypkg"
		echo ""
		exit 1
	fi
	PLUGIN_PACKAGE_PATH=`realpath $2`
	repackage ${PLUGIN_PACKAGE_PATH}
}

repackage(){
	local PACKAGE_PATH=$1
	PACKAGE_NAME_WITH_EXTENSION=`basename ${PACKAGE_PATH}`
	PACKAGE_NAME="${PACKAGE_NAME_WITH_EXTENSION%.*}"

	echo ""
	echo "=========================================="
	echo "Dify Plugin Repackaging Tool"
	echo "=========================================="
	echo "Source: ${PACKAGE_PATH}"
	echo "Work directory: ${CURR_DIR}/${PACKAGE_NAME}"

	# Extract plugin package
	echo ""
	echo "Extracting plugin package..."
	install_unzip
	unzip -o ${PACKAGE_PATH} -d ${CURR_DIR}/${PACKAGE_NAME}
	if [[ $? -ne 0 ]]; then
		echo "✗ Error: Failed to extract package"
		exit 1
	fi
	echo "✓ Package extracted successfully"

	cd ${CURR_DIR}/${PACKAGE_NAME} || exit 1
	if [ ! -f "pyproject.toml" ] && [ ! -f "requirements.txt" ]; then
		echo "⚠ Warning: No pyproject.toml or requirements.txt found"
	fi

	# Inject [tool.uv] offline config into pyproject.toml (runtime uses local wheels only)
	inject_uv_offline_into_pyproject() {
		local PYFILE="$1"
		[ -f "$PYFILE" ] || return 0
	awk '
		BEGIN { in_uv=0; saw_uv=0; saw_no=0; saw_find=0; saw_pre=0 }
		function print_missing(){ if (!saw_no) print "no-index = true"; if (!saw_find) print "find-links = [\"./wheels/\"]"; if (!saw_pre) print "prerelease = \"allow\"" }
		/^[ \t]*\[tool\.uv\][ \t]*$/ { saw_uv=1; in_uv=1; saw_no=0; saw_find=0; saw_pre=0; print; next }
		{ if (in_uv && $0 ~ /^[ \t]*\[/) { print_missing(); in_uv=0 } }
		{ if (in_uv && $0 ~ /^[ \t]*no-index[ \t]*=/) { print "no-index = true"; saw_no=1; next } }
		{ if (in_uv && $0 ~ /^[ \t]*find-links[ \t]*=/) { print "find-links = [\"./wheels/\"]"; saw_find=1; next } }
		{ if (in_uv && $0 ~ /^[ \t]*prerelease[ \t]*=/) { print "prerelease = \"allow\""; saw_pre=1; next } }
		{ print }
		END {
			if (in_uv) { print_missing() }
			if (!saw_uv) {
				print ""
				print "[tool.uv]"
				print "no-index = true"
				print "find-links = [\"./wheels/\"]"
				print "prerelease = \"allow\""
			}
		}
		' "$PYFILE" > "$PYFILE.tmp" && mv "$PYFILE.tmp" "$PYFILE"
		echo "Injected offline [tool.uv] into $PYFILE"
	}

	strip_dependency_groups() {
		local PYFILE="$1"
		[ -f "$PYFILE" ] || return 0
		if ! grep -q '^\[dependency-groups\]' "$PYFILE"; then
			return 0
		fi
		awk '
		BEGIN { skip=0 }
		/^\[dependency-groups\]/ { skip=1; next }
		/^\[/ { skip=0 }
		!skip { print }
		' "$PYFILE" > "$PYFILE.tmp" && mv "$PYFILE.tmp" "$PYFILE"
		echo "Removed [dependency-groups] from $PYFILE"
	}

	inject_uv_environments() {
		local PYFILE="$1"
		[ -f "$PYFILE" ] || return 0

		local sys_platform="linux"
		if [[ -n "$RAW_PLATFORM" ]]; then
			case "$RAW_PLATFORM" in
				*darwin*|*macos*) sys_platform="darwin" ;;
				*win*) sys_platform="win32" ;;
				*) sys_platform="linux" ;;
			esac
		else
			case "$OS_TYPE" in
				darwin) sys_platform="darwin" ;;
				linux) sys_platform="linux" ;;
				*) sys_platform="win32" ;;
			esac
		fi

		local env_line="environments = [\"sys_platform == '${sys_platform}' and python_version == '${UV_PY_VERSION}'\"]"
		awk -v env_line="$env_line" '
		BEGIN { in_uv=0; saw_uv=0; saw_env=0 }
		/^[ \t]*\[tool\.uv\][ \t]*$/ { saw_uv=1; in_uv=1; print; next }
		{
			if (in_uv && $0 ~ /^[ \t]*\[/) {
				if (!saw_env) print env_line
				in_uv=0
			}
		}
		{ if (in_uv && $0 ~ /^[ \t]*environments[ \t]*=/) { print env_line; saw_env=1; next } }
		{ print }
		END {
			if (in_uv && !saw_env) print env_line
			if (!saw_uv) {
				print ""
				print "[tool.uv]"
				print env_line
			}
		}
		' "$PYFILE" > "$PYFILE.tmp" && mv "$PYFILE.tmp" "$PYFILE"
		echo "Injected uv environments (${sys_platform}, python ${UV_PY_VERSION}) into $PYFILE"
	}

	resolve_requirements_with_uv() {
		if ! command -v uv &> /dev/null; then
			echo "✗ Error: uv is required when pyproject.toml exists"
			echo "  Install uv: https://docs.astral.sh/uv/getting-started/installation/"
			exit 1
		fi

		strip_dependency_groups "pyproject.toml"
		inject_uv_environments "pyproject.toml"

		echo "Generating uv.lock..."
		uv lock -p "${UV_PY_VERSION}" ${UV_PRERELEASE_FLAG}
		if [[ $? -ne 0 ]]; then
			echo "✗ Error: uv lock failed"
			exit 1
		fi
		echo "✓ uv.lock generated successfully"

		echo "Exporting requirements.txt from uv.lock..."
		uv export --frozen --no-hashes --no-dev -o requirements.txt -p "${UV_PY_VERSION}"
		if [[ $? -ne 0 ]]; then
			echo "✗ Error: uv export failed"
			exit 1
		fi
		echo "✓ requirements.txt generated via uv export"
	}

	verify_offline_uv_sync() {
		[ -f "pyproject.toml" ] || return 0
		if ! command -v uv &> /dev/null; then
			echo "⚠ uv not available, skipping offline verification"
			return 0
		fi
		if [[ -n "$RAW_PLATFORM" ]] && ! host_matches_target_platform; then
			echo "⚠ Skipping offline uv verification on non-target build host"
			return 0
		fi

		echo "Verifying offline dependency resolution with uv..."
		if uv sync --offline --no-dev --dry-run -p "${UV_PY_VERSION}"; then
			echo "✓ Offline uv sync verification passed"
		else
			echo "✗ Error: Offline uv sync verification failed"
			exit 1
		fi
	}

	verify_wheel_platforms() {
		[ -d "./wheels" ] || return 0
		local expected="linux"
		if [[ -n "$RAW_PLATFORM" ]]; then
			case "$RAW_PLATFORM" in
				*darwin*|*macos*) expected="macos" ;;
				*win*) expected="win" ;;
				*) expected="linux" ;;
			esac
		else
			case "$OS_TYPE" in
				darwin) expected="macos" ;;
				linux) expected="linux" ;;
				*) expected="win" ;;
			esac
		fi

		local wrong=0
		for whl in ./wheels/*.whl; do
			[ -f "$whl" ] || continue
			local name
			name="$(basename "$whl")"
			case "$name" in
				*-py3-none-any.whl|*-py2.py3-none-any.whl) continue ;;
			esac
			case "$expected" in
				linux)
					if [[ "$name" != *manylinux* && "$name" != *linux_* && "$name" != *musllinux* ]]; then
						echo "⚠ Unexpected wheel for Linux offline package: $name"
						wrong=1
					fi
					;;
				macos)
					if [[ "$name" != *macosx* && "$name" != *darwin* ]]; then
						echo "⚠ Unexpected wheel for macOS offline package: $name"
						wrong=1
					fi
					;;
				win)
					if [[ "$name" != *win_* ]]; then
						echo "⚠ Unexpected wheel for Windows offline package: $name"
						wrong=1
					fi
					;;
			esac
		done

		if [[ "$wrong" -ne 0 ]]; then
			echo "✗ Error: wheels/ contains packages for the wrong platform"
			exit 1
		fi
	}

	remove_from_ignore_files() {
		local entry="$1"
		for IGNORE_PATH in .difyignore .gitignore; do
			[ -f "$IGNORE_PATH" ] || continue
			if grep -qxF "$entry" "$IGNORE_PATH"; then
				grep -vxF "$entry" "$IGNORE_PATH" > "${IGNORE_PATH}.tmp" && mv "${IGNORE_PATH}.tmp" "$IGNORE_PATH"
				echo "Removed ${entry} from ${IGNORE_PATH}"
			fi
		done
	}

	if python3 -m pip --version &> /dev/null 2>&1; then
		PIP_CMD="python3 -m pip"
	elif command -v pip &> /dev/null && pip --version &> /dev/null 2>&1; then
		PIP_CMD=pip
	elif command -v pip3 &> /dev/null && pip3 --version &> /dev/null 2>&1; then
		PIP_CMD=pip3
	else
		echo "pip not found. Install: python3 -m ensurepip --upgrade"
		exit 1
	fi
	echo "✓ Using pip: ${PIP_CMD}"

	# ============================================
	# Step 1: Detect Python and platform configuration
	# ============================================
	echo ""
	echo "=========================================="
	echo "Step 1: Detecting Python and platform"
	echo "=========================================="

	# Detect Python version
	PYTHON_CMD_FOR_UV="python3"
	PY_VERSION_FULL=$(python3 --version 2>&1 | awk '{print $2}')
	PY_MAJOR=$(echo $PY_VERSION_FULL | cut -d. -f1)
	PY_MINOR=$(echo $PY_VERSION_FULL | cut -d. -f2)
	PYTHON_VERSION=$PY_VERSION_FULL

	echo "Detected Python: $PYTHON_VERSION"

	# If Python is 3.14+, try to use 3.12 or 3.13 for better compatibility
	if [ "$PY_MAJOR" -eq 3 ] && [ "$PY_MINOR" -ge 14 ]; then
		echo "⚠ Warning: Python $PYTHON_VERSION is too new for some packages"
		if command -v python3.12 &> /dev/null; then
			PYTHON_CMD_FOR_UV="python3.12"
			PYTHON_VERSION=$($PYTHON_CMD_FOR_UV --version 2>&1 | awk '{print $2}')
			echo "✓ Switched to python3.12 ($PYTHON_VERSION) for better compatibility"
		elif command -v python3.13 &> /dev/null; then
			PYTHON_CMD_FOR_UV="python3.13"
			PYTHON_VERSION=$($PYTHON_CMD_FOR_UV --version 2>&1 | awk '{print $2}')
			echo "✓ Switched to python3.13 ($PYTHON_VERSION) for better compatibility"
		else
			echo "⚠ Warning: No compatible Python version found, proceeding with $PYTHON_VERSION"
		fi
	else
		echo "✓ Python version $PYTHON_VERSION is compatible"
	fi

	# Extract Python major.minor for uv
	UV_PY_VERSION=$($PYTHON_CMD_FOR_UV - <<'PY'
import sys
print(f"{sys.version_info.major}.{sys.version_info.minor}")
PY
)

	# Determine uv target platform to avoid cross-platform dependency conflicts
	local UV_PLATFORM=""
	if [[ -n "$RAW_PLATFORM" ]]; then
		case "$RAW_PLATFORM" in
			*linux*|*manylinux* )
				UV_PLATFORM="linux"
				echo "Target platform: Linux (cross-compilation from $OS_TYPE)"
				;;
			*macos*|*darwin* )
				UV_PLATFORM="macos"
				echo "Target platform: macOS (cross-compilation from $OS_TYPE)"
				;;
			*win* )
				UV_PLATFORM="windows"
				echo "Target platform: Windows (cross-compilation from $OS_TYPE)"
				;;
			* )
				UV_PLATFORM=""
				echo "Target platform: current ($OS_TYPE)"
				;;
		esac
	else
		if [[ "$OS_TYPE" == "darwin" ]]; then
			UV_PLATFORM="macos"
		elif [[ "$OS_TYPE" == "linux" ]]; then
			UV_PLATFORM="linux"
		elif [[ "$OS_TYPE" == "windows" ]]; then
			UV_PLATFORM="windows"
		fi
		echo "Target platform: $UV_PLATFORM (current system)"
	fi

	# Set prerelease flag
	UV_PRERELEASE_FLAG=""
	if [[ "$PRERELEASE_ALLOW" -eq 1 ]]; then
		UV_PRERELEASE_FLAG="--prerelease allow"
		echo "Prerelease versions: allowed"
	else
		echo "Prerelease versions: disallowed"
	fi

	echo "✓ Configuration: platform=${UV_PLATFORM:-current}, python=$UV_PY_VERSION"

	# ============================================
	# Step 2: Generate requirements.txt from pyproject.toml
	# ============================================
	echo ""
	echo "=========================================="
	echo "Step 2: Processing dependencies"
	echo "=========================================="

	# Inject [tool.uv] config to enable offline wheel usage
	if [ -f "pyproject.toml" ]; then
		resolve_requirements_with_uv
	elif [ -f "requirements.txt" ]; then
		echo "✓ Using existing requirements.txt"
	else
		echo "✗ Error: pyproject.toml or requirements.txt not found"
		exit 1
	fi

	[ ! -f "requirements.txt" ] && echo "✗ Error: requirements.txt not found" && exit 1

	# ============================================
	# Step 3: Download Python dependencies as wheels
	# ============================================
	echo ""
	echo "=========================================="
	echo "Step 3: Downloading dependencies"
	echo "=========================================="
	echo "Index URL: ${PIP_MIRROR_URL}"
	[ -n "$RAW_PLATFORM" ] && echo "Platform: ${RAW_PLATFORM}"

	mkdir -p ./wheels
	echo "Downloading wheels to ./wheels/..."

	PIP_WHEEL_ARGS=(--prefer-binary -r requirements.txt -w ./wheels
		--index-url "${PIP_MIRROR_URL}")

	case "${PIP_MIRROR_URL}" in
		*mirrors.aliyun.com*) PIP_WHEEL_ARGS+=(--trusted-host mirrors.aliyun.com) ;;
		*pypi.org*) PIP_WHEEL_ARGS+=(--trusted-host pypi.org --trusted-host files.pythonhosted.org) ;;
	esac

	run_pip_wheel() {
		${PIP_CMD} wheel "$@"
	}

	run_pip_download() {
		${PIP_CMD} download "$@"
	}

	if host_matches_target_platform; then
		echo "Host matches target platform; using pip wheel (builds sdists when needed)"
		run_pip_wheel "${PIP_WHEEL_ARGS[@]}" || {
			echo "✗ Error: Failed to build/download dependency wheels"
			echo "  Some packages (e.g. pycairo) have no Linux wheels and must be compiled."
			echo "  Install native build deps first, e.g.:"
			echo "    sudo apt-get install -y libcairo2-dev pkg-config gcc g++ python3-dev"
			exit 1
		}
	elif [[ -n "$RAW_PLATFORM" ]]; then
		PIP_PY_VERSION="${PY_MAJOR}${PY_MINOR}"
		PIP_CROSS_ARGS=(--only-binary=:all:
			--python-version "${PIP_PY_VERSION}"
			--implementation cp
			--abi "cp${PY_MAJOR}${PY_MINOR}")

		MANYLINUX_ARCH="$(manylinux_arch_from_platform "${RAW_PLATFORM}")"
		if [[ -z "${MANYLINUX_ARCH}" ]]; then
			echo "✗ Error: Unsupported platform ${RAW_PLATFORM}"
			exit 1
		fi

		# PyPI wheels may be tagged manylinux_2_17 or manylinux_2_28; try both.
		DOWNLOAD_OK=0
		for MANYLINUX_TAG in "manylinux_2_17_${MANYLINUX_ARCH}" "manylinux_2_28_${MANYLINUX_ARCH}"; do
			echo "Downloading wheels for ${MANYLINUX_TAG}..."
			if run_pip_download --platform "${MANYLINUX_TAG}" "${PIP_CROSS_ARGS[@]}" \
				--prefer-binary -r requirements.txt -d ./wheels \
				--index-url "${PIP_MIRROR_URL}" \
				$(case "${PIP_MIRROR_URL}" in *mirrors.aliyun.com*) echo --trusted-host mirrors.aliyun.com ;; *pypi.org*) echo --trusted-host pypi.org --trusted-host files.pythonhosted.org ;; esac); then
				DOWNLOAD_OK=1
			else
				echo "⚠ Some packages unavailable for ${MANYLINUX_TAG}; continuing"
			fi
		done

		if [[ "${DOWNLOAD_OK}" -eq 0 ]]; then
			echo "✗ Error: Failed to download dependencies for ${RAW_PLATFORM}"
			exit 1
		fi

		echo "Verifying wheel cache covers requirements.txt..."
		if ! run_pip_download --dry-run --no-index --find-links=./wheels -r requirements.txt >/dev/null 2>&1; then
			echo "✗ Error: Wheel cache is incomplete for requirements.txt"
			exit 1
		fi
	else
		run_pip_wheel "${PIP_WHEEL_ARGS[@]}" || {
			echo "✗ Error: Failed to build/download dependency wheels"
			exit 1
		}
	fi

	# Count downloaded wheels
	WHEEL_COUNT=$(ls -1 ./wheels/*.whl 2>/dev/null | wc -l)
	echo "✓ Downloaded $WHEEL_COUNT wheel packages"
	verify_wheel_platforms

	# ============================================
	# Step 4: Update metadata for offline usage
	# ============================================
	echo ""
	echo "Updating plugin metadata for offline installation..."

	if [ -f "pyproject.toml" ]; then
		inject_uv_offline_into_pyproject "pyproject.toml"
		if [ -f "uv.lock" ]; then
			rm -f uv.lock
			echo "Removed uv.lock (dify-plugin-daemon must re-resolve from ./wheels/ offline)"
		fi
	fi

	if [ -f "requirements.txt" ]; then
		if ! grep -q '^--no-index' requirements.txt; then
			if [[ "linux" == "$OS_TYPE" ]]; then
				sed -i '1i\--no-index --find-links=./wheels/' requirements.txt
			elif [[ "darwin" == "$OS_TYPE" ]]; then
				sed -i ".bak" '1i\--no-index --find-links=./wheels/' requirements.txt && rm -f requirements.txt.bak
			fi
		fi
	fi

	remove_from_ignore_files "wheels/"
	remove_from_ignore_files "wheels"
	verify_offline_uv_sync
	echo "✓ Plugin metadata updated for offline mode"

	# ============================================
	# Step 5: Package the plugin
	# ============================================
	echo ""
	echo "=========================================="
	echo "Step 4: Packaging plugin"
	echo "=========================================="

	cd ${CURR_DIR} || exit 1
	chmod 755 ${CURR_DIR}/${CMD_NAME}

	OUTPUT_PACKAGE="${CURR_DIR}/${PACKAGE_NAME}-${PACKAGE_SUFFIX}.difypkg"
	echo "Packaging: ${PACKAGE_NAME}"
	echo "Output: ${OUTPUT_PACKAGE}"
	echo "Max size: 5120 MB"

	${CURR_DIR}/${CMD_NAME} plugin package ${CURR_DIR}/${PACKAGE_NAME} \
		-o ${OUTPUT_PACKAGE} --max-size 5120
	if [[ $? -ne 0 ]]; then
		echo "✗ Error: Packaging failed"
		exit 1
	fi

	# Get file size
	FILE_SIZE=$(du -h "${OUTPUT_PACKAGE}" | cut -f1)
	echo ""
	echo "=========================================="
	echo "✓ Package created successfully!"
	echo "=========================================="
	echo "Location: ${OUTPUT_PACKAGE}"
	echo "Size: ${FILE_SIZE}"
	echo "Platform: ${RAW_PLATFORM:-current}"
}

install_unzip(){
	if ! command -v unzip &> /dev/null; then
		echo "Installing unzip ..."
		yum -y install unzip
		if [ $? -ne 0 ]; then
			echo "Install unzip failed."
			exit 1
		fi
	fi
}

# Return 0 when the current host can natively produce wheels for -p platform.
host_matches_target_platform() {
	[[ -z "$RAW_PLATFORM" ]] && return 1
	case "$RAW_PLATFORM" in
		*x86_64*|*amd64*)
			[[ "$OS_TYPE" == "linux" && ( "$ARCH_NAME" == "x86_64" || "$ARCH_NAME" == "amd64" ) ]]
			;;
		*aarch64*|*arm64*)
			[[ "$OS_TYPE" == "linux" && ( "$ARCH_NAME" == "aarch64" || "$ARCH_NAME" == "arm64" ) ]]
			;;
		*)
			return 1
			;;
	esac
}

manylinux_arch_from_platform() {
	case "$1" in
		*aarch64*|*arm64*) echo "aarch64" ;;
		*x86_64*|*amd64*) echo "x86_64" ;;
		*) echo "" ;;
	esac
}

print_usage() {
	echo "usage: $0 [-p platform] [-s package_suffix] [-R] {market|github|local}"
	echo "-p platform: python packages' platform. Using for crossing repacking.
        For example: -p manylinux_2_17_x86_64 or -p manylinux_2_17_aarch64"
	echo "-s package_suffix: The suffix name of the output offline package.
        For example: -s linux-amd64 or -s linux-arm64"
	echo "-R: allow pre-release versions during uv resolution (maps to --prerelease=allow)"
	exit 1
}

while getopts "p:s:R" opt; do
	case "$opt" in
		p) RAW_PLATFORM="${OPTARG}" ;;
		s) PACKAGE_SUFFIX="${OPTARG}" ;;
		R) PRERELEASE_ALLOW=1 ;;
		*) print_usage; exit 1 ;;
	esac
done

shift $((OPTIND - 1))

echo "$1"
case "$1" in
	'market')
	market $@
	;;
	'github')
	github $@
	;;
	'local')
	_local $@
	;;
	*)

print_usage
exit 1
esac
exit 0
