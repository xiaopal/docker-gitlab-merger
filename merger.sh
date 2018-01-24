#!/bin/bash

GITLAB_API_TOKEN="${GITLAB_API_TOKEN:-$GIT_API_TOKEN}" && \
	GITLAB_ENDPOINT="${GITLAB_ENDPOINT:-$GITLAB_URL}"
	[ ! -z "$GITLAB_API_TOKEN" ] && [ ! -z "$GITLAB_ENDPOINT" ] || {
	echo "ERROR - GITLAB_API_TOKEN and GITLAB_ENDPOINT required" >&2
	exit 1
}
GITLAB_MERGER_SECRET="${GITLAB_MERGER_SECRET:-$GITLAB_API_TOKEN}"

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
	[ ! -z "$MERGER_URI" ] && [ ! -z "$MERGER_TOKEN" ] && \
	secret_token --check "$MERGER_URI"<<<"$MERGER_TOKEN" || {
		echo "[ $(date -R) ] ERROR - Failed to verify secret token ( $MERGER_URI )" >&2
		return 1
	}
	[ ! -z "$MERGER_EVENT" ] || {
		echo "[ $(date -R) ] ERROR - Event required" >&2
		return 1
	}
	
	local EVENT_ACTION
	case "${MERGER_EVENT,,}" in
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
		echo "[ $(date -R) ] ERROR - Unknown event: $MERGER_EVENT" >&2
		return 1
		;;
	esac
	"$EVENT_ACTION" "${MERGER_URI#/}"
}

gitlab_api() {
    local METHOD="$1" URI="$2" && shift && shift
	[ ! -z "$GITLAB_API_DEBUG" ] && echo "Gitlab API: $METHOD $URI" >&2
	[[ "$(curl -sk -w '%{http_code}' -o /dev/fd/21 -H "PRIVATE-TOKEN: $GITLAB_API_TOKEN" \
		-X $METHOD "${GITLAB_ENDPOINT%/}$URI" "$@"\
		)" =~ ^[23] ]] 21>&1
}

match_merge_patterns(){
	# Eg. release/*:master hotfix/*:master feature/*:develop
	local TEXT="$1" DEFAULT_DEST="$2" PATTERN DEST && shift && shift
	while IFS=':' read -r PATTERN DEST<<<"$1" && shift; do
		[ ! -z "$PATTERN" ] && [[ "$TEXT" == $PATTERN ]] && {
			echo "${DEST:-$DEFAULT_DEST}"
			return 0
		}
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
	local PAYLOAD="$MERGER_PAYLOAD" ENDPOINT="$1"
	[ ! -z "$PAYLOAD" ] && [ -f "$PAYLOAD" ] && [ ! -z "$(jq 'objects|not|not' "$PAYLOAD")" ] || {
		echo "[ $(date -R) ] ERROR - Request body required" >&2
		return 1
	}
	[ "$(jq -r '.project.path_with_namespace//empty' "$PAYLOAD")" == "$ENDPOINT" ] || {
		echo "[ $(date -R) ] ERROR - Project missmatch" >&2
		return 1
	}

	local MERGE_FROM MERGE_TO MERGE_TO_DEFAULT
	MERGE_FROM="$(jq -r '.ref//empty' "$PAYLOAD")" && MERGE_FROM="${MERGE_FROM#refs/heads/}"
	[ ! -z "$GIT_AUTO_MERGE" ] && \
		[ "$(jq -r '.before//empty' "$PAYLOAD")" == "0000000000000000000000000000000000000000" ] && \
		MERGE_TO_DEFAULT="$(jq -r '.project.default_branch//"master"' "$PAYLOAD")" && \
		MERGE_TO="$(match_merge_patterns "$MERGE_FROM" "$MERGE_TO_DEFAULT" $GIT_AUTO_MERGE)" && \
		[ ! -z "$MERGE_TO" ] || return 0

	local PROJECT_ID="$(jq -r '.project_id//empty' "$PAYLOAD")"
	local FOUND_MR="$(export MERGE_FROM MERGE_TO
		gitlab_api GET "/api/v4/projects/$PROJECT_ID/merge_requests?state=opened" | \
		jq '.[]|select(.target_branch==env.MERGE_TO and .source_branch==env.MERGE_FROM)|.id//empty')"
	[ ! -z "$FOUND_MR" ] || {
		local CREATE_MR="$(uri_with_params \
			"/api/v4/projects/$PROJECT_ID/merge_requests" \
			source_branch "$MERGE_FROM" \
			target_branch "$MERGE_TO" \
			title "WIP: $MERGE_FROM" \
			remove_source_branch true )"
		local MR="$(gitlab_api POST "$CREATE_MR" | jq -r '.title//.id')"
		echo "[ $(date -R) ] INFO - Merge Request created: $MR"
	}
	return 0	
}

handle_mr_event(){
	local PAYLOAD="$MERGER_PAYLOAD" ENDPOINT="$1"
	[ ! -z "$PAYLOAD" ] && [ -f "$PAYLOAD" ] && [ ! -z "$(jq 'objects|not|not' "$PAYLOAD")" ] || {
		echo "[ $(date -R) ] ERROR - Request body required" >&2
		return 1
	}

	local TAG_FROM TAG_TO TAG_TO_TARGET TAG_NAME
	[ ! -z "$GIT_AUTO_TAG" ] && \
		[ "$(jq -r '.object_attributes.target.path_with_namespace//empty' "$PAYLOAD")" == "$ENDPOINT" ] && \
		[ "$(jq -r '.object_attributes.action//empty' "$PAYLOAD")" == "merge" ] && \
		TAG_FROM="$(jq -r '.object_attributes.source_branch//empty' "$PAYLOAD")" && \
		TAG_TO_TARGET="$(jq -r '.object_attributes.target_branch//empty' "$PAYLOAD")" && \
		TAG_TO="$(match_merge_patterns "$TAG_FROM" "$TAG_TO_TARGET" $GIT_AUTO_TAG)" && \
		TAG_NAME="${TAG_FROM##*/}" && [ ! -z "$TAG_NAME" ] && \
		[ ! -z "$TAG_TO" ] && [ "$TAG_TO" == "$TAG_TO_TARGET" ] || return 0

	local PROJECT_ID="$(jq -r '.object_attributes.target_project_id//empty' "$PAYLOAD")"
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

perform_put_file(){
	local PROJECT="$1" NAME VALUE \
		FILE_PATH BRANCH BRANCH_FROM COMMIT_MESSAGE \
		CREATE_FILE='Y' UPDATE_FILE='' DELETE_FILE='' LAZY='Y'
	parse_flag(){
		[[ "${1,,}" =~ ^(y|yes|true|on|1)$ ]] && echo 'Y'
	}
	[ ! -z "$MERGER_ARGS" ] && while IFS='=' read -r -d '&' NAME VALUE; do
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
		"lazy")
			LAZY="$(parse_flag "$VALUE")"
			;;
		"commit")
			COMMIT_MESSAGE="$VALUE"
			;;
		esac
	done <<<"$MERGER_ARGS&"
	[ ! -z "$FILE_PATH" ] && [ ! -z "$BRANCH" ] || {
		echo "[ $(date -R) ] ERROR - path and branch required" >&2
		return 1
	}
	[ ! -z "$GIT_PUT_FILE" ] && \
		local ACCEPTED_BRANCH_FROM="$(match_merge_patterns "$BRANCH" "${BRANCH_FROM:-$BRANCH}" $GIT_PUT_FILE)" && \
		[ ! -z "$ACCEPTED_BRANCH_FROM" ] || {
			echo "[ $(date -R) ] ERROR - Cannot put file to branch '$BRANCH'" >&2
			return 1
		}
	
	[ ! -z "$(gitlab_api GET "/api/v4/projects/${PROJECT/\//%2F}/repository/branches/${BRANCH/\//%2F}" | jq -r ".name//empty")" ] \
		&& BRANCH_FROM="$BRANCH" || {
		[ ! -z "$BRANCH_FROM" ] && [ "$BRANCH_FROM" == "$ACCEPTED_BRANCH_FROM" ] || {
			echo "[ $(date -R) ] ERROR - Branch '$BRANCH' not found" >&2
			return 1
		}
		[ ! -z "$LAZY" ] || {
			local CREATE_BRANCH="$(uri_with_params \
				"/api/v4/projects/${PROJECT/\//%2F}/repository/branches" \
				branch "$BRANCH" \
				ref "$BRANCH_FROM" )"
			[ ! -z "$(gitlab_api POST "$CREATE_BRANCH" | jq -r '.name//empty')" ] || {
				echo "[ $(date -R) ] ERROR - Failed to create branch: $BRANCH" >&2
				return 1
			}
			echo "[ $(date -R) ] INFO - Branch created: $BRANCH" >&2
			BRANCH_FROM="$BRANCH"
		}
	}

	local UPLOAD_STAGE="$(mktemp -d)"
	do_put_file(){
		local FILE_DETAIL="$UPLOAD_STAGE/detail.json" \
			API_FILE="/api/v4/projects/${PROJECT/\//%2F}/repository/files/${FILE_PATH/\//%2F}"

		gitlab_api GET "$(uri_with_params "$API_FILE" ref "$BRANCH_FROM")" >"$FILE_DETAIL"
		[ ! -z "$DELETE_FILE" ] && {
			[ ! -z "$(jq -r '.file_name//empty' "$FILE_DETAIL")" ] || return 0
			gitlab_api DELETE "$(uri_with_params "$API_FILE" \
				branch "$BRANCH" start_branch "$BRANCH_FROM" \
				commit_message "${COMMIT_MESSAGE:-Delete $FILE_PATH}" \
				)"
			echo "[ $(date -R) ] INFO - File deleted: $FILE_PATH @$BRANCH" >&2
			return 0
		}

		[ ! -z "$MERGER_PAYLOAD" ] && [ -f "$MERGER_PAYLOAD" ] || {
			echo "[ $(date -R) ] ERROR - Request body required" >&2
			return 1
		}

		local FILE_BASE64="$MERGER_PAYLOAD" FILE_DATA="$UPLOAD_STAGE/content.data"
		( echo -n "content=" && base64 -d <"$FILE_BASE64" | base64 \
			| sed 's/+/%2B/g' | tr -d '\n' ) >"$FILE_DATA"

		gitlab_upload_file(){
			local METHOD="$1" \
				PUT_FILE="$(uri_with_params "$API_FILE" \
					branch "$BRANCH" start_branch "$BRANCH_FROM" \
					commit_message "${COMMIT_MESSAGE:-Upload $FILE_PATH}" \
					encoding "base64" )"
			local RESULT="$(gitlab_api "$METHOD" "$PUT_FILE" --data-binary "@$FILE_DATA" | jq -r '.branch//empty')"
			[ ! -z "$RESULT" ] || return 1
			return 0
		}
		
		[ ! -z "$(jq -r '.file_name//empty' "$FILE_DETAIL")" ] || {
			[ ! -z "$CREATE_FILE" ] || return 0
			gitlab_upload_file POST || {
				echo "[ $(date -R) ] ERROR - Failed to create file" >&2
				return 1
			}
			echo "[ $(date -R) ] INFO - File created: $FILE_PATH @$BRANCH" >&2				
			return 0
		}

		[ ! -z "$UPDATE_FILE" ] || return 0
		local NEW_MD5="$(base64 -d "$FILE_BASE64" | md5sum)" \
				OLD_MD5="$(jq -r '.content//empty' "$FILE_DETAIL" | base64 -d | md5sum)" \
			&& [ "$NEW_MD5" == "$OLD_MD5" ] || {
			gitlab_upload_file PUT || {
				echo "[ $(date -R) ] ERROR - Failed to update file" >&2				
				return 1
			}
			echo "[ $(date -R) ] INFO - File updated: $FILE_PATH @$BRANCH" >&2				
			return 0
		}
		return 0

	} && do_put_file || {
		rm -fr "$UPLOAD_STAGE"
		return 1
	}
	rm -fr "$UPLOAD_STAGE";
}

gitlab_webhook_setup(){
	local ARG PROJECT WEBHOOK_ENDPOINT USAGE FORCE REMOVE VARIABLES=() VARIABLE \
		SECRET_TOKEN="$(secret_token "$PROJECT")"
	while ARG="$1" && shift; do
		case "$ARG" in
		"--help")
			USAGE='Y'
			;;
		"--webhook")
			WEBHOOK_ENDPOINT="$1" && shift
			;;
		"--variable")
			VARIABLES=("${VARIABLES[@]}" "$1") && shift
			;;
		"--token-variable")
			IFS='=' read -r VARIABLE _<<<"$1" && shift
			VARIABLES=("${VARIABLES[@]}" "$VARIABLE=$SECRET_TOKEN")
			;;
		"--force")
			FORCE='Y'
			;;
		"--remove")
			REMOVE='Y'
			;;
		*)
			[ ! -z "$PROJECT" ] && USAGE='Y' || PROJECT="$ARG"
			;;
		esac
	done
	[ ! -z "$PROJECT" ] && [ -z "$USAGE" ] && ( [ ! -z "$WEBHOOK_ENDPOINT" ] || [ ! -z "$VARIABLES" ] ) || {
		echo "Usage: ${PROG_NAME:-$0} --webhook http://<webhook_endpoint>/ [--token-variable NAME] [--variable NAME=VALUE] [--force] [--remove] <project_name>" >&2
		return 1
	}

	local PROJECT_ID="$(gitlab_api GET "/api/v4/projects/${PROJECT/\//%2F}" | jq -r '.id//empty')" && [ ! -z "$PROJECT_ID" ] || {
		echo "[ $(date -R) ] INFO - Project '$PROJECT' not exists" >&2
		return 1
	}
	setup_webhook(){
		local WEBHOOK_URL="${WEBHOOK_ENDPOINT%/}/$PROJECT" \
			WEBHOOK_API="/api/v4/projects/$PROJECT_ID/hooks"
		local METHOD='POST' API="$WEBHOOK_API" WEBHOOK_ID="$(gitlab_api GET "$WEBHOOK_API" \
			| URL="$WEBHOOK_URL" jq -r 'map(select(.url == env.URL))|.[0].id//empty')"
		[ ! -z "$WEBHOOK_ID" ] || [ ! -z "$REMOVE" ] && {
			[ ! -z "$REMOVE" ] && [ -z "$WEBHOOK_ID" ] && return 0
			[ ! -z "$REMOVE" ] && {
				gitlab_api DELETE "$WEBHOOK_API/$WEBHOOK_ID" || {
					echo "[ $(date -R) ] ERROR - failed to remove webhook: id=$WEBHOOK_ID project=$PROJECT" >&2
					return 1
				}
				echo "[ $(date -R) ] INFO - Webhook removed: id=$WEBHOOK_ID project=$PROJECT" >&2
				return 0
			}
			[ ! -z "$FORCE" ] && METHOD='PUT' && API="$WEBHOOK_API/$WEBHOOK_ID" || {
				echo "[ $(date -R) ] INFO - Webhook already exists: id=$WEBHOOK_ID project=$PROJECT" >&2		
				return 0
			}
		}
		WEBHOOK_ID="$(gitlab_api "$METHOD" "$(uri_with_params "$API" url "$WEBHOOK_URL" token "$SECRET_TOKEN" \
				push_events true merge_requests_events true)" | jq -r '.id//empty')" && [ ! -z "$WEBHOOK_ID" ] || {
			echo "[ $(date -R) ] ERROR - failed to register webhook: url=$WEBHOOK_URL project=$PROJECT" >&2
			return 1
		}
		echo "[ $(date -R) ] INFO - Webhook registered: id=$WEBHOOK_ID project=$PROJECT" >&2
	} && [ ! -z "$WEBHOOK_ENDPOINT" ] && setup_webhook

	setup_variable(){
		local VARIABLE_API="/api/v4/projects/$PROJECT_ID/variables" KEY VALUE
		IFS='=' read -r KEY VALUE<<<"$1" && [ ! -z "$KEY" ] || return 1
		local METHOD='POST' API="$VARIABLE_API" VARIABLE_FOUND="$(gitlab_api GET "$VARIABLE_API" \
			| KEY="$KEY" jq -r 'map(select(.key == env.KEY))|.[0].key//empty')"
		[ ! -z "$VARIABLE_FOUND" ] || [ ! -z "$REMOVE" ] && {
			[ ! -z "$REMOVE" ] && [ -z "$VARIABLE_FOUND" ] && return 0
			[ ! -z "$REMOVE" ] && {
				gitlab_api DELETE "$VARIABLE_API/$VARIABLE_FOUND" || {
					echo "[ $(date -R) ] ERROR - failed to remove variable: key=$VARIABLE_FOUND project=$PROJECT" >&2
					return 1
				}
				echo "[ $(date -R) ] INFO - Variable removed: key=$VARIABLE_FOUND project=$PROJECT" >&2
				return 0
			}
			[ ! -z "$FORCE" ] && METHOD='PUT' && API="$VARIABLE_API/$VARIABLE_FOUND" || {
				echo "[ $(date -R) ] INFO - Variable already exists: key=$VARIABLE_FOUND project=$PROJECT" >&2		
				return 0
			}
		}
		VARIABLE_FOUND="$(gitlab_api "$METHOD" "$(uri_with_params "$API" key "$KEY" value "$VALUE" protected true)" | jq -r '.key//empty')"
		[ ! -z "$VARIABLE_FOUND" ] || {
			echo "[ $(date -R) ] ERROR - failed to register variable: key=$KEY project=$PROJECT" >&2
			return 1
		}
		echo "[ $(date -R) ] INFO - Variable registered: key=$KEY project=$PROJECT" >&2
	} && for VARIABLE in "${VARIABLES[@]}"; do
		setup_variable "$VARIABLE" || return 1
	done
	return 0
}

ACTION='handle_webhook_request'
PROG_NAME="${0##*/}" && case "$PROG_NAME" in
"secret")
	ACTION='secret_token'
	;;
"api")
	ACTION='gitlab_api'
	;;
"setup")
	ACTION='gitlab_webhook_setup'
	;;
esac
"$ACTION" "$@"