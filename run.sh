#!/usr/bin/dumb-init /bin/bash

GITLAB_API_TOKEN="${GITLAB_API_TOKEN:-$GIT_API_TOKEN}" && \
	[ ! -z "$GITLAB_API_TOKEN" ] && [ ! -z "$GITLAB_URL" ] || {
	echo "ERROR - GITLAB_API_TOKEN and GITLAB_URL required" >&2
	exit 1
}
GITLAB_MERGER_SECRET="${GITLAB_MERGER_SECRET:-$GITLAB_API_TOKEN}"

run_server(){
	echo "[ $(date -R) ] INFO - Starting Webhook..." >&2
	trap 'cleanup_server INT'  INT
	trap 'cleanup_server TERM' TERM
	trap 'cleanup_server' EXIT
	local RAW_REQUEST REQUEST_INFO
	while read -r RAW_REQUEST; do
		REQUEST_INFO="$(jq -r '"\(.method) \(.uri) @\(.remote_addr) \(.event//"")"'<<<"$RAW_REQUEST")"
		handle_webhook_request "$RAW_REQUEST" || {
			echo "[ $(date -R) ] WARN - Illegal request: $REQUEST_INFO" >&2
			continue
		} 
	done < <(nginx -qc /webhook.conf)
}

cleanup_server() {
	[ ! -z "$1" ] \
		&& echo "[ $(date -R) ] WARN - Caught $1 signal! Shutting down..." >&2 \
		|| echo "[ $(date -R) ] INFO - Finishing..." >&2
	trap - EXIT INT TERM
	exit 0
}

secret_token(){
	local ENDPOINT SECRET_SALT SECRET_CHECK SECRET_TOKEN ARG
	while ARG="$1" && shift; do
		case "$ARG" in
		"-c"|"--check")
			IFS='.' read -r SECRET_SALT SECRET_CHECK _ && [ ! -z "$SECRET_CHECK" ] || return 1
			;;
		*)
			ENDPOINT="$ENDPOINT${ARG#/}"
			;;
		esac
	done
	[ ! -z "$SECRET_SALT" ] || SECRET_SALT="$(tr -dc 'a-zA-Z0-9/+' </dev/urandom | head -c 7)"
	SECRET_TOKEN="$SECRET_SALT.$(echo -n "$SECRET_SALT.$ENDPOINT" | openssl sha1 -hmac "$GITLAB_MERGER_SECRET" -binary | base64 | head -c 27)"
	[ ! -z "$SECRET_CHECK" ] && {
		[ "$SECRET_TOKEN" == "$SECRET_SALT.$SECRET_CHECK" ] && return 0
		return 1
	}
	echo "$SECRET_TOKEN"
	return 0	
}

handle_webhook_request(){
	local RAW_REQUEST="$1" REQUEST_BODY URI EVENT EVENT_ACTION
	URI="$(jq -r '.uri//empty'<<<"$RAW_REQUEST")" && [ ! -z "$URI" ] && \
		jq -r '.secret_token//empty'<<<"$RAW_REQUEST" | secret_token --check "$URI" || {
			echo "[ $(date -R) ] ERROR - Failed to verify secret token" >&2
			return 1
		}
	EVENT="$(jq -r '.event//empty'<<<"$RAW_REQUEST")" && [ ! -z "$EVENT" ] || {
		echo "[ $(date -R) ] ERROR - Event required" >&2
		return 1
	}
	case "${EVENT,,}" in
	"push hook")
		EVENT_ACTION='handle_push_event'
		;;
	"merge request hook")
		EVENT_ACTION='handle_mr_event'
		;;
	"put file")
		EVENT_ACTION='perform_put_file'
		;;
	*)
		echo "[ $(date -R) ] ERROR - Unknown event: $EVENT" >&2
		return 1
		;;
	esac
	[ ! -z "$GITLAB_WEBHOOK_DEBUG" ] && (
		echo "Gitlab Webhook: '$EVENT_ACTION' '${URI#/}' '$(jq -r '.args//empty'<<<"$RAW_REQUEST")' " 
		jq -r '.body//empty'<<<"$RAW_REQUEST"
	) >&2
	jq -r '.body//empty'<<<"$RAW_REQUEST" | \
		"$EVENT_ACTION" "${URI#/}" "$(jq -r '.args//empty'<<<"$RAW_REQUEST")"
}

gitlab_api() {
    local METHOD="$1" URI="$2" && shift && shift
    curl -sk -X $METHOD -H "PRIVATE-TOKEN: $GITLAB_API_TOKEN" "${GITLAB_URL%/}$URI" "$@"
	[ ! -z "$GITLAB_API_DEBUG" ] && echo "Gitlab API: $METHOD $URI" >&2
}

match_patterns(){
	local TEXT="$1" PATTERN && shift
	while PATTERN="$1" && shift; do
		[ ! -z "$PATTERN" ] && [[ "$TEXT" == $PATTERN ]] && return 0
	done
	return 1
}

uri_with_params(){
	local URI="$1" PARAMS PARAM
	shift && while PARAM="$(NAME="$1" VALUE="$2" jq -nr '@uri "\(env.NAME)=\(env.VALUE)"')" && shift && shift; do
		PARAMS="${PARAMS:+$PARAMS&}$PARAM"
	done
	echo "$URI${PARAMS:+?$PARAMS}"
}

handle_push_event(){
	local REQUEST="$(jq -c .)" ENDPOINT="$1" MERGE_FROM
	[ ! -z "$REQUEST" ] || {
		echo "[ $(date -R) ] ERROR - Request body required" >&2
		return 1
	}
	[ "$(jq -r '.project.path_with_namespace//empty'<<<"$REQUEST")" == "$ENDPOINT" ] || {
		echo "[ $(date -R) ] ERROR - Project missmatch" >&2
		return 1
	}

	MERGE_FROM="$(jq -r '.ref//empty'<<<"$REQUEST")" && MERGE_FROM="${MERGE_FROM#refs/heads/}"
	[ ! -z "$GIT_AUTO_MERGE" ] && match_patterns "$MERGE_FROM" $GIT_AUTO_MERGE && \
		[ "$(jq -r '.before//empty'<<<"$REQUEST")" == "0000000000000000000000000000000000000000" ] || return 0

	local PROJECT_ID="$(jq -r '.project_id//empty'<<<"$REQUEST")" \
		MERGE_TO="${GIT_AUTO_MERGE_TO:-$(jq -r '.project.default_branch//"master"'<<<"$REQUEST")}"
	local FOUND_MR="$(export MERGE_FROM MERGE_TO
		gitlab_api GET "/api/v4/projects/$PROJECT_ID/merge_requests?state=opened" | \
		jq '.[]|select(.target_branch==env.MERGE_TO and .source_branch==env.MERGE_FROM)|.id//empty')"
	[ ! -z "$FOUND_MR" ] || {
		local CREATE_MR="$(uri_with_params \
			"/api/v4/projects/$PROJECT_ID/merge_requests" \
			source_branch "$MERGE_FROM" \
			target_branch "$MERGE_TO" \
			title "WIP:$MERGE_FROM" \
			remove_source_branch true )"
		local MR="$(gitlab_api POST "$CREATE_MR" | jq -r '.title//.id')"
		echo "[ $(date -R) ] INFO - Merge Request created: $MR"
	}
	return 0	
}

handle_mr_event(){
	local REQUEST="$(jq -c .)" ENDPOINT="$1"
	[ ! -z "$REQUEST" ] || {
		echo "[ $(date -R) ] ERROR - Request body required" >&2
		return 1
	}
	[ ! -z "$GIT_AUTO_TAG" ] || return 0
	GIT_AUTO_TAG_TO="${GIT_AUTO_TAG_TO:-$(jq -r '.merge_request.target.default_branch//"master"'<<<"$REQUEST")}"
	[ "$(jq -r '.merge_request.source.path_with_namespace//empty'<<<"$REQUEST")" == "$ENDPOINT" ] || return 0
	[ "$(jq -r '.merge_request.target.path_with_namespace//empty'<<<"$REQUEST")" == "$ENDPOINT" ] || return 0
	[ "$(jq -r '.merge_request.state//empty'<<<"$REQUEST")" == "merged" ] || return 0

	local TAG_FROM="$(jq -r '.merge_request.source_branch//empty'<<<"$REQUEST")" \
		TAG_TO="$(jq -r '.merge_request.target_branch//empty'<<<"$REQUEST")"
	[ "$TAG_TO" == "$GIT_AUTO_TAG_TO" ] && match_patterns "$MERGE_FROM" $GIT_AUTO_MERGE || return 0

	local PROJECT_ID="$(jq -r '.merge_request.target_project_id//empty'<<<"$REQUEST")" \
		TAG_NAME="${TAG_FROM##*/}"
	[ ! -z "$(gitlab_api GET "/api/v4/projects/$PROJECT_ID/repository/tags/$TAG_NAME" | jq -r ".name//empty")" ] || {
		local CREATE_TAG="$(uri_with_params \
			"/api/v4/projects/$PROJECT_ID/repository/tags" \
			tag_name "$TAG_NAME" \
			ref "$TAG_TO" \
			message "$TAG_FROM" )"
		[ ! -z "$(gitlab_api POST "$CREATE_TAG" | jq -r '.name//empty')" ] || {
			echo "[ $(date -R) ] ERROR - Failed to create tag" >&2
			return 1
		}
		echo "[ $(date -R) ] INFO - Tag created: $TAG_NAME" >&2
	}
	return 0
}

parse_flag(){
	[[ "${1,,}" =~ ^(y|yes|true|on|1)$ ]] && echo 'Y'
}

perform_put_file(){
	local FILE_BASE64="$(base64 -d | base64 | tr -d '\n')" PROJECT="$1" QUERY="$2" NAME VALUE \
		FILE_PATH BRANCH BRANCH_FROM COMMIT_MESSAGE \
		CREATE_FILE='Y' UPDATE_FILE='' DELETE_FILE=''
	[ ! -z "$QUERY" ] && while IFS='=' read -r -d '&' NAME VALUE; do
		case "$NAME" in
		"path")
			FILE_PATH="$VALUE"
			;;
		"branch")
			BRANCH="$VALUE"
			;;
		"from")
			BRANCH_FROM="$VALUE"
			;;
		"create"|"new")
			CREATE_FILE="$(parse_flag "$VALUE")"
			;;
		"update"|"force")
			UPDATE_FILE="$(parse_flag "$VALUE")"
			;;
		"delete"|"remove")
			DELETE_FILE="$(parse_flag "$VALUE")"
			;;
		"commit")
			COMMIT_MESSAGE="$VALUE"
			;;
		esac
	done <<<"$QUERY&"
	[ ! -z "$FILE_PATH" ] && [ ! -z "$BRANCH" ] || {
		echo "[ $(date -R) ] ERROR - path and branch required" >&2
		return 1
	}
	[ ! -z "$(gitlab_api GET "/api/v4/projects/${PROJECT/\//%2F}/repository/branches/${BRANCH/\//%2F}" | jq -r ".name//empty")" ] || {
		[ ! -z "$BRANCH_FROM" ] || {
			echo "[ $(date -R) ] ERROR - Branch '$BRANCH' not found" >&2
			return 1
		}
		local CREATE_BRANCH="$(uri_with_params \
			"/api/v4/projects/${PROJECT/\//%2F}/repository/branches" \
			branch "$BRANCH" \
			ref "$BRANCH_FROM" )"
		[ ! -z "$(gitlab_api POST "$CREATE_BRANCH" | jq -r '.name//empty')" ] || {
			echo "[ $(date -R) ] ERROR - Failed to create branch: $BRANCH" >&2
			return 1
		}
		echo "[ $(date -R) ] INFO - Branch created: $BRANCH" >&2
	}

	local API_FILE="/api/v4/projects/${PROJECT/\//%2F}/repository/files/${FILE_PATH/\//%2F}"
	local FILE_DETAIL="$(gitlab_api GET "$(uri_with_params "$API_FILE" ref "$BRANCH")")"
	[ ! -z "$DELETE_FILE" ] && {
		[ ! -z "$(jq -r '.file_name//empty'<<<"$FILE_DETAIL")" ] || return 0
		gitlab_api DELETE "$(uri_with_params "$API_FILE" \
			branch "$BRANCH" \
			commit_message "${COMMIT_MESSAGE:-Delete $FILE_PATH}" \
			)"
		echo "[ $(date -R) ] INFO - File deleted: $FILE_PATH @$BRANCH" >&2				
		return 0
	}

	gitlab_upload_file(){
		local METHOD="$1" \
			PUT_FILE="$(uri_with_params "$API_FILE" \
				branch "$BRANCH" \
				commit_message "${COMMIT_MESSAGE:-Upload $FILE_PATH}" \
				encoding "base64" )" \
			PUT_FILE_DATA="$(mktemp)" && echo "content=${FILE_BASE64//+/%2B}" >"$PUT_FILE_DATA"
		local RESULT="$(gitlab_api "$METHOD" "$PUT_FILE" --data-binary "@$PUT_FILE_DATA" | jq -r '.branch//empty')"
		rm -f "$PUT_FILE_DATA"; [ ! -z "$RESULT" ] || return 1
		return 0
	}
	
	[ ! -z "$(jq -r '.file_name//empty'<<<"$FILE_DETAIL")" ] || {
		[ ! -z "$CREATE_FILE" ] || return 0
		gitlab_upload_file POST || {
			echo "[ $(date -R) ] ERROR - Failed to create file" >&2
			return 1
		}
		echo "[ $(date -R) ] INFO - File created: $FILE_PATH @$BRANCH" >&2				
		return 0
	}

	[ ! -z "$UPDATE_FILE" ] || return 0
	local NEW_MD5="$(base64 -d<<<"$FILE_BASE64" | md5sum)" \
			OLD_MD5="$(jq -r '.content//empty'<<<"$FILE_DETAIL" | base64 -d | md5sum)" \
		&& [ "$NEW_MD5" == "$OLD_MD5" ] || {
		gitlab_upload_file PUT || {
			echo "[ $(date -R) ] ERROR - Failed to update file" >&2				
			return 1
		}
		echo "[ $(date -R) ] INFO - File updated: $FILE_PATH @$BRANCH" >&2				
		return 0
	}
	return 0
}

ACTION='run_server'
ARGS=()
while ARG="$1" && shift; do
	case "$ARG" in
	"server")
		ACTION='run_server'	
		;;
	"secret")
		ACTION='secret_token'
		;;
	"api")
		ACTION='gitlab_api'
		;;
	*)
		ARGS=("${ARGS[@]}" "$ARG")
		;;
	esac
done
"$ACTION" "${ARGS[@]}"
