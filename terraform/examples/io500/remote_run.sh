#!/bin/bash

set -e
trap 'echo "Hit an unexpected and unchecked error. Exiting."' ERR

DAOS_CONTROLLER_VM_NAME="daos-controller"
DAOS_PROJECT_NAME="cloud-daos-perf-testing"

SCRIPT_NAME="$(basename "$0")"
SCRIPT_DIR="$( cd "$( dirname "$0" )" && pwd )"


PERF_SESSION_ID="$USER$(date +'%Y%m%d-%H%M')"
RESULTS_DIR="${SCRIPT_DIR}/results/${PERF_SESSION_ID}"
CONFIG_FILE="${SCRIPT_DIR}/results/${PERF_SESSION_ID}/config.sh"
CONFIG_TEMPLATE_FILE="${SCRIPT_DIR}/remote_run.config.template"

SSH_USER="daos-user"
RUN_SCRIPT="run_io500-isc22.sh"

# default parameter values
N_TIMES=1
DURATION_IN_SECONDS=60
DAOS_CONT_PROPS="rf:0"
IO500_INI="io500-isc22.config-template.daos-rf0.ini"


show_help() {
  cat <<EOF

Deploys DAOS cluster and clients in GCP, runs IO500 benchmark in repetition, collect results and cleans up.

Usage:
  ${SCRIPT_NAME} <options>

Options:
  [ -s --seconds  DURATION_IN_SECONDS ]	Duration of each IO500 benchmark in seconds
  [ -n --numberoftimes   N_TIMES ]	Number of times to repeat IO500 benchmark
  [ -p --properties  DAOS_CONT_PROPS ]  Comma-seperated list of DAOS container properties(property:value), such as erasure coding and checksum configuration
          For full DAOS property list, visit https://docs.daos.io/v2.0/user/container/#property-values
  [ -i --ini IO500_INI ]  io500 ini file name
  [ -h --help ]                   Show help

Examples:
  Deploys DAOS and runs IO500 with default duration and default number of repetition

    ${SCRIPT_NAME}

  Deploys DAOS and runs IO500 for 5 minutes and repeat 6 more times, with Redundancy Factor set to 1, checksum enabled with CRC64, and server verify enabled

    ${SCRIPT_NAME} -s 300  -n 7  -p rf:1,cksum:crc64,srv_cksum:true -i io500-isc22.config-template.daos-rf1.ini

EOF
}

log() {
  msg="$1"
  print_lines="$2"
  # shellcheck disable=SC2155,SC2183
  local line=$(printf "%80s" | tr " " "-")
  if [[ -t 1 ]]; then tput setaf 14; fi
  if [[ "${print_lines}" == 1 ]]; then
    printf -- "\n%s\n %-78s \n%s\n" "${line}" "${msg}" "${line}"
  else
    printf -- "\n%s\n\n" "${msg}"
  fi
  if [[ -t 1 ]]; then tput sgr0; fi
}

log_error() {
  # shellcheck disable=SC2155,SC2183
  if [[ -t 1 ]]; then tput setaf 160; fi
  printf -- "\n%s\n\n" "${1}" >&2;
  if [[ -t 1 ]]; then tput sgr0; fi
}

show_errors() {
  # If there are errors, print the error messages and exit
  if [[ ${#ERROR_MSGS[@]} -gt 0 ]]; then
    printf "\n" >&2
    log_error "${ERROR_MSGS[@]}"
    show_help
    exit 1
  fi
}

opts() {

  regexInt='^[0-9]+$'

  # shift will cause the script to exit if attempting to shift beyond the
  # max args.  So set +e to continue processing when shift errors.
  set +e
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --seconds|-s)
        DURATION_IN_SECONDS="$2"
        if [[ "${DURATION_IN_SECONDS}" == -* ]] || [[ "${DURATION_IN_SECONDS}" == "" ]] || [[ -z ${DURATION_IN_SECONDS} ]]; then
          ERROR_MSGS+=("ERROR: Missing DURATION_IN_SECONDS value for -s or --seconds")
          break
        elif ! [[ "${DURATION_IN_SECONDS}" =~ $regexInt ]] ; then
          ERROR_MSGS+=("ERROR: Specified value '${DURATION_IN_SECONDS}' is not a positive integer.")
        fi
        export DURATION_IN_SECONDS
        shift 2
      ;;
      --numberoftimes|-n)
        N_TIMES="$2"
        if [[ "${N_TIMES}" == -* ]] || [[ "${N_TIMES}" == "" ]] || [[ -z ${N_TIMES} ]]; then
          ERROR_MSGS+=("ERROR: Missing N_TIMES value for -n or --numberoftimes")
          break
        elif ! [[ "${N_TIMES}" =~ $regexInt ]] ; then
          ERROR_MSGS+=("ERROR: Specified value '${N_TIMES}' is not a positive integer.")
        fi
        export N_TIMES
        shift 2
      ;;
      --properties|-p)
        DAOS_CONT_PROPS="$2"
        if [[ "${DAOS_CONT_PROPS}" == -* ]] || [[ "${DAOS_CONT_PROPS}" == "" ]] || [[ -z ${DAOS_CONT_PROPS} ]]; then
          ERROR_MSGS+=("ERROR: Missing DAOS_CONT_PROPS value for -p or --properties")
          break
        fi
        export DAOS_CONT_PROPS
        shift 2
      ;;
      --ini|-i)
        IO500_INI="$2"
        if [[ "${IO500_INI}" == -* ]] || [[ "${IO500_INI}" == "" ]] || [[ -z ${IO500_INI} ]]; then
          ERROR_MSGS+=("ERROR: Missing IO500_INI value for -i or --ini")
          break
        fi
        export IO500_INI
        shift 2
      ;;
      --help|-h)
        show_help
        exit 0
      ;;
	    --*|-*)
        ERROR_MSGS+=("ERROR: Unrecognized option '${1}'")
        shift
        break
      ;;
	    *)
        ERROR_MSGS+=("ERROR: Unrecognized option '${1}'")
        shift
        break
      ;;
    esac
  done
  set -e

  show_errors
}

check_connection_to_daos_controller() {
   ssh -q $USER@$DAOS_CONTROLLER_VM_NAME exit
   if [ $? -eq 0 ]
   then
      log "SSH connectivity to ${DAOS_CONTROLLER_VM_NAME} :  OK " 
      return 0
   fi

   log "Setting up SSH to ${DAOS_CONTROLLER_VM_NAME}"

   gcp_ssh_setup $DAOS_CONTROLLER_VM_NAME --project $DAOS_PROJECT_NAME

   ssh -q $USER@$DAOS_CONTROLLER_VM_NAME exit
   if [ $? -ne 0 ]
   then
      log_error "Can't SSH connect to ${DAOS_CONTROLLER_VM_NAME}!"
      exit 1
   fi

   log "SSH connectivity to ${DAOS_CONTROLLER_VM_NAME} :  OK "
}

setup_working_folders() {
    # setup working subfolder under results folder    mkdir -p $RESULTS_DIR
    log "Working folder created: ${RESULTS_DIR}"

    ssh 
}

sync_to_daos_controller() {

}

generate_config() {
    # generate config.sh file
    sed -e "s/\${perf_session_id}/${PERF_SESSION_ID}/" -e "s/\${daos_cont_props}/${DAOS_CONT_PROPS}/" -e "s/\${io500_ini}/${IO500_INI}/" -e "s/\${duration_in_seconds}/${DURATION_IN_SECONDS}/" ${CONFIG_TEMPLATE_FILE} >  ${CONFIG_FILE}
    log "Config file generated: ${CONFIG_FILE}"
}

deploy_daos_cluster_n_clients() {
    # deploy DAOS cluster and client
    source ${SCRIPT_DIR}/start.sh -i -c ${CONFIG_FILE}
    log "Successfully deployed DAOS cluster and client with config file: ${CONFIG_FILE}."
}

run_n_collect_io500() {
      ITERATION_N_DIR="${RESULTS_DIR}/iteration$1"
      mkdir $ITERATION_N_DIR

      # run io500
      ssh -F "${SSH_CONFIG_FILE}" "${FIRST_CLIENT_IP}" "~/${RUN_SCRIPT}"

      # collect result
      scp -r -F "${SSH_CONFIG_FILE}" "${FIRST_CLIENT_IP}:~/io500-isc22/results/*" "${ITERATION_N_DIR}/"

      # reset the results folder in the first DAOS client
      ssh -F "${SSH_CONFIG_FILE}" "${FIRST_CLIENT_IP}" "rm -rf ~/io500-isc22/results/"
}



main() {
    opts "$@"

    check_connection_to_daos_controller

#    sync_to_daos_controller

#    setup_working_folders

#   generate_config

#    deploy_daos_cluster_n_clients


    SSH_CONFIG_FILE="${SCRIPT_DIR}/tmp/ssh_config"
    FIRST_CLIENT_IP=$(cat ${SSH_CONFIG_FILE} | awk '{print $2}' | grep 10)

    # repeat io500 and result collection for specified number of times
    for (( n=0; n<${N_TIMES};n++))
    do
      log "Iteration $n"

#      run_n_collect_io500 $n

    done

    # cleanup DAOS cluster and client
#   source ${SCRIPT_dir}/stop.sh
}

main "$@"

