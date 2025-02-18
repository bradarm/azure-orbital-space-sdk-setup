#!/bin/bash

_app_prereqs_worker_pids=()
_app_prereqs_log_files=()
_app_prereqs_temp_dir=""
_app_prereqs_target_architecture="${ARCHITECTURE}"
_app_prereqs_dest_stage_dir=""

############################################################
# Install 3p apps to the target host
############################################################
function _app_prereqs_validate() {
    local need_apps_installed=false

    info_log "Checking if third party apps are installed and available..."

    is_cmd_available "yq" has_yq_cmd
    is_cmd_available "jq" has_jq_cmd
    is_cmd_available "regctl" has_regctl_cmd
    is_cmd_available "cfssl" has_cfssl_cmd
    is_cmd_available "cfssljson" has_cfssljson_cmd
    is_cmd_available "helm" has_helm_cmd

    if [[ $has_yq_cmd == true ]]; then
        debug_log "yq is installed.  Checking version..."
        run_a_script "yq --version" yq_version
        if [[ "${yq_version}" == *"${VER_YQ}"* ]]; then
            debug_log "yq version is correct. (${VER_YQ})"
        else
            debug_log "yq version is incorrect.  Expected: ${VER_YQ}.  Found: ${yq_version}.  Removing previous to trigger reinstall"
            run_a_script "which -a yq" yq_paths
            for yq_path in $yq_paths; do
                if [[ -f "$yq_path" ]]; then
                    debug_log "Removing yq at $yq_path"
                    run_a_script "sudo rm -f $yq_path"
                    debug_log "...successfull removed old version of yq at $yq_path"
                fi
            done
            debug_log "Successfully removed previous versions of yq"
            has_yq_cmd=false
        fi
    fi

    if [[ $has_yq_cmd == true ]] && [[ $has_jq_cmd == true ]] && [[ $has_regctl_cmd == true ]] && [[ $has_cfssl_cmd == true ]] && [[ $has_cfssljson_cmd == true ]] && [[ $has_helm_cmd == true ]]; then
        info_log "All third party apps are installed and available."
        return
    fi

    info_log "Detected missing third party apps.  Starting installation..."

    local VER_CFSSL_no_v="${VER_CFSSL:1}"
    _app_install --app "cfssl" --source "${SPACEFX_DIR}/bin/${HOST_ARCHITECTURE}/cfssl/${VER_CFSSL}/cfssl" --url "https://github.com/cloudflare/cfssl/releases/download/${VER_CFSSL}/cfssl_${VER_CFSSL_no_v}_linux_${HOST_ARCHITECTURE}" --destination "/usr/local/bin/cfssl"
    _app_install --app "cfssljson" --source "${SPACEFX_DIR}/bin/${HOST_ARCHITECTURE}/cfssl/${VER_CFSSL}/cfssljson" --url "https://github.com/cloudflare/cfssl/releases/download/${VER_CFSSL}/cfssljson_${VER_CFSSL_no_v}_linux_${HOST_ARCHITECTURE}" --destination "/usr/local/bin/cfssljson"
    _app_install --app "jq" --source "${SPACEFX_DIR}/bin/${HOST_ARCHITECTURE}/jq/${VER_JQ}/jq" --url "https://github.com/jqlang/jq/releases/download/jq-${VER_JQ:?}/jq-linux-${HOST_ARCHITECTURE:?}" --destination "/usr/local/bin/jq"
    _app_install --app "yq" --source "${SPACEFX_DIR}/bin/${HOST_ARCHITECTURE}/yq/${VER_YQ}/yq" --url "https://github.com/mikefarah/yq/releases/download/v${VER_YQ:?}/yq_linux_${HOST_ARCHITECTURE:?}" --destination "/usr/local/bin/yq"
    _app_install --app "regctl" --source "${SPACEFX_DIR}/bin/${HOST_ARCHITECTURE}/regctl/${VER_REGCTL}/regctl" --url "https://github.com/regclient/regclient/releases/download/${VER_REGCTL:?}/regctl-linux-${HOST_ARCHITECTURE:?}" --destination "/usr/local/bin/regctl"

    _app_install_for_helm
    _app_install_wait_for_background_processes

    info_log "Installation of third party apps successful."

    if [[ -d "${_app_prereqs_temp_dir}" ]]; then
        run_a_script "rm ${_app_prereqs_temp_dir} -rf" --disable_log
        _app_prereqs_temp_dir=""
    fi
}

############################################################
# Helper function to install app to local path
############################################################
function _app_install() {
    local app_name=""
    local source=""
    local destination=""
    local url=""

    while [[ "$#" -gt 0 ]]; do
        case $1 in
            --app)
                shift
                app_name=$1
                ;;
            --source)
                shift
                source=$1
                ;;
            --destination)
                shift
                destination=$1
                ;;
            --url)
                shift
                url=$1
                ;;
            *) echo "Unknown parameter '$1'"; show_help ;;
        esac
        shift
    done

    if [[ -z "${app_name}" ]] || [[ -z "${source}" ]] || [[ -z "${destination}" ]] || [[ -z "${url}" ]]; then
        exit_with_error "Missing required parameters.  Please use --app, --url, --source, and --destination.  Received app_name: '${app_name}', source: '${source}', destination: '${destination}', url: '${url}'"
    fi

    if [[ -f "${destination}" ]]; then
        info_log "App '${app_name}' already present at '${destination}'.  Nothing to do"
        return
    fi

    # Provision a temp directory if we don't have one already
    if [[ -z "${_app_prereqs_temp_dir}" ]]; then
        run_a_script "mktemp -d" _app_prereqs_temp_dir --disable_log
    fi

    run_a_script "chmod 777 ${_app_prereqs_temp_dir}" --disable_log

    # Spin up a background task that will download the file to the destination
    (
        set -e
        trap "" HUP
        exec 2> "${_app_prereqs_temp_dir}/${app_name}.log"
        exec 0< /dev/null
        exec 1> "${_app_prereqs_temp_dir}/${app_name}.log"

        create_directory "$(dirname ${destination})"

        echo "Checking for app '${app_name}' at '${source}'..."

        if [[ ! -f "${source}" ]]; then
            if [[ "${INTERNET_CONNECTED}" == false  ]]; then
                echo "App '${app_name}' not found at '${source}' and no internet connection available.  Please restage from an internet connected host and retry."
                exit 1
            else
                # We have internet connectivity.  Go ahead and download it
                echo "...app '${app_name}' not found at '${source}'.  Starting download from '${url}' to '${destination}'..."
                run_a_script "curl --silent --fail --create-dirs --output ${destination} -L ${url}" --disable_log
            fi
        else
            # App is already downloaded.  Copy it to the destination
            echo "...app '${app_name}' found at '${source}'.  Copying to '${destination}'..."
            run_a_script "cp ${source} ${destination}"
        fi

        run_a_script "chmod +x ${destination}" --disable_log
        run_a_script "chmod 755 ${destination}" --disable_log

        echo "Successfully deployed '${app_name}' to '${destination}'"
    ) &

    # Add the PID to the array so we can wait for it to finish
    _app_prereqs_worker_pids+=($!)

    # Add the log file name to the array so we can match it up with the worker pid
    _app_prereqs_log_files+=("${_app_prereqs_temp_dir}/${app_name}.log")
}


############################################################
# Wait for workers to finish
############################################################
function _app_install_wait_for_background_processes(){
    info_log "START: ${FUNCNAME[0]}"

    info_log "Background log files:"

    # Outputing the logs that we're tracking
    for logfile in "${_app_prereqs_log_files[@]}"; do
        debug_log "...log file '${logfile}'"
    done

    info_log "...waiting for background processes to finish..."

    worker_failed=false
    local index=0

    # Loop through the array of worker PIDs and wait for them to finish
    for pid in "${_app_prereqs_worker_pids[@]}"; do
        wait "$pid"
        RETURN_CODE=$?
        # An error was detected.  Write it out and the log file associated with it
        if [[ $RETURN_CODE -gt 0 ]]; then
            worker_failed=true
            error_log "Failure detected in background worker.  Return code: ${RETURN_CODE}.  Log File: '${_app_prereqs_log_files[$index]}'"
            run_a_script "cat ${_app_prereqs_log_files[$index]}" log_output
            error_log "${log_output}"
        fi
         ((index++))
    done


    if [[ "${worker_failed}" == true ]]; then
        exit_with_error "Failure detected in background processes.  See above errors and retry"
    fi

    info_log "...background processes finished successfully."

    info_log "FINISHED: ${FUNCNAME[0]}"
}


############################################################
# Check and download Helm
############################################################
function _app_install_for_helm(){
    info_log "START: ${FUNCNAME[0]}"

    local app_name="helm"
    source="${SPACEFX_DIR}/bin/${HOST_ARCHITECTURE}/helm/${VER_HELM}/helm"
    url="https://get.helm.sh/helm-${VER_HELM}-linux-${HOST_ARCHITECTURE}.tar.gz"

    run_a_script "mktemp -d" _helm_install_temp_dir --disable_log
    run_a_script "chmod 777 ${_helm_install_temp_dir}" --disable_log

    destination="/usr/local/bin/helm"


    if [[ -f "${destination}" ]]; then
        info_log "App '${app_name}' already present at '${destination}'.  Nothing to do"
        return
    fi

    if [[ ! -f "${source}" ]]; then
        if [[ "${INTERNET_CONNECTED}" == false  ]]; then
            echo "App '${app_name}' not found at '${source}' and no internet connection available.  Please restage from an internet connected host and retry."
            exit 1
        else
            # We have internet connectivity.  Go ahead and download it
            echo "...app '${app_name}' not found at '${source}'.  Starting download from '${url}' to '${destination}'..."
            run_a_script "curl --silent --fail --create-dirs --output ${_helm_install_temp_dir}/helm-${VER_HELM}-linux-${HOST_ARCHITECTURE}.tar.gz -L ${url}" --disable_log

            run_a_script "tar -xf '${_helm_install_temp_dir}/helm-${VER_HELM}-linux-${HOST_ARCHITECTURE}.tar.gz' --directory '${_helm_install_temp_dir}' linux-${ARCHITECTURE}/helm" --disable_log
            run_a_script "mv ${_helm_install_temp_dir}/linux-${HOST_ARCHITECTURE}/helm ${destination}" --disable_log
            run_a_script "rm ${_helm_install_temp_dir} -rf" --disable_log
        fi
    else
        # App is already downloaded.  Copy it to the destination
        echo "...app '${app_name}' found at '${source}'.  Copying to '${destination}'..."
        run_a_script "cp ${source} ${destination}" --disable_log
    fi

    run_a_script "chmod +x ${destination}" --disable_log
    run_a_script "chmod 755 ${destination}" --disable_log


    info_log "FINISHED: ${FUNCNAME[0]}"
}
