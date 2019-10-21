#!/usr/bin/env bash
# Copyright 2014, Rackspace US, Inc.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

## Shell Opts ----------------------------------------------------------------
set -e -u -x

## Variables -----------------------------------------------------------------

# tempest and testr options, default is to run tempest in serial
export TESTR_OPTS=${TESTR_OPTS:-''}

# Disable the python output buffering so that jenkins gets the output properly
export PYTHONUNBUFFERED=1

# Extra options to pass to the AIO bootstrap process
export BOOTSTRAP_OPTS=${BOOTSTRAP_OPTS:-''}

# Ensure the terminal type is set
export TERM=linux

# Store the clone repo root location
export OSA_CLONE_DIR="$(readlink -f $(dirname ${0})/..)"

# The directory in which the ansible logs will be placed
export ANSIBLE_LOG_DIR="/openstack/log/ansible-logging"

# Set the scenario to execute based on the first CLI parameter
export SCENARIO=${1:-"aio_lxc"}

# Set the action base on the second CLI parameter
# Actions available: [ 'deploy', 'upgrade', 'varstest', 'linters' ]
export ACTION=${2:-"deploy"}

# Set the installation method for the OpenStack services
export INSTALL_METHOD=${3:-"source"}

# Set the source branch for upgrade tests
# Be sure to change this whenever a new stable branch
# is created. The checkout must always be N-1.
export UPGRADE_SOURCE_BRANCH=${UPGRADE_SOURCE_BRANCH:-'stable/rocky'}

# enable the ARA callback plugin
export SETUP_ARA=${SETUP_ARA:-true}

## Change branch for Upgrades ------------------------------------------------
# If the action is to upgrade, then store the current SHA,
# checkout the source SHA before executing the greenfield
# deployment.
# This needs to be done before the first "source" to ensure
# the correct functions are used for the branch.
if [[ "${ACTION}" == "upgrade" ]]; then
    # Store the target SHA/branch
    export UPGRADE_TARGET_BRANCH=$(git rev-parse HEAD)

    # Now checkout the source SHA/branch
    git checkout ${UPGRADE_SOURCE_BRANCH}
fi

## Functions -----------------------------------------------------------------
info_block "Checking for required libraries." 2> /dev/null || source "${OSA_CLONE_DIR}/scripts/scripts-library.sh"

## Main ----------------------------------------------------------------------

# Log some data about the instance and the rest of the system
log_instance_info

run_dstat || true

load_nodepool_pip_opts

# Bootstrap Ansible
source "${OSA_CLONE_DIR}/scripts/bootstrap-ansible.sh"

# Flush all the iptables rules set by openstack-infra
iptables -F
iptables -X
iptables -t nat -F
iptables -t nat -X
iptables -t mangle -F
iptables -t mangle -X
iptables -P INPUT ACCEPT
iptables -P FORWARD ACCEPT
iptables -P OUTPUT ACCEPT

# Bootstrap an AIO
if [[ -z "${SKIP_OSA_BOOTSTRAP_AIO+defined}" ]]; then
    source "${OSA_CLONE_DIR}/scripts/bootstrap-aio.sh"
fi

if [[ "${ACTION}" == "varstest" ]]; then
  pushd "${OSA_CLONE_DIR}/tests"
      openstack-ansible test-vars-overrides.yml
  popd
elif [[ "${ACTION}" == "linters" ]]; then
  pushd "${OSA_CLONE_DIR}/playbooks"
    # Install linter tools
    ${PIP_COMMAND} install --isolated ${PIP_OPTS} -r ${OSA_CLONE_DIR}/test-requirements.txt
    # Disable Ansible color output
    export ANSIBLE_NOCOLOR=1
    # Create ansible logging directory
    mkdir -p ${ANSIBLE_LOG_DIR}

    # Prepare the hosts
    export ANSIBLE_LOG_PATH="${ANSIBLE_LOG_DIR}/ansible-syntax-check.log"

    # defining working directories
    VENV_BIN_DIR=$(dirname ${PIP_COMMAND})
    ROLE_DIR="/etc/ansible/roles/${SCENARIO}"

    ANSIBLE_LINT_EXCLUDES="204,metadata"
    # Check if we have test playbook and running checks
    if [[ -f "${ROLE_DIR}/examples/playbook.yml" ]]; then
      ${VENV_BIN_DIR}/ansible-lint ${ROLE_DIR}/examples/playbook.yml -x ${ANSIBLE_LINT_EXCLUDES}
      ${VENV_BIN_DIR}/ansible-playbook --syntax-check --list-tasks ${ROLE_DIR}/examples/playbook.yml
    else
      ${VENV_BIN_DIR}/ansible-lint ${ROLE_DIR} -x ${ANSIBLE_LINT_EXCLUDES}
      ${VENV_BIN_DIR}/ansible-playbook --syntax-check --list-tasks setup-everything.yml
    fi

    # Run bashate
    grep --recursive --binary-files=without-match \
      --files-with-match '^.!.*\(ba\)\?sh$' \
      --exclude-dir .tox \
      --exclude-dir .git \
      "${ROLE_DIR}" | xargs -r -n1 ${VENV_BIN_DIR}/bashate --error . --verbose --ignore=E003,E006,E040

    # Run pep8 check
    grep --recursive --binary-files=without-match \
      --files-with-match '^.!.*python$' \
      --exclude-dir .eggs \
      --exclude-dir .git \
      --exclude-dir .tox \
      --exclude-dir *.egg-info \
      --exclude-dir doc \
      "${ROLE_DIR}" | xargs -r ${VENV_BIN_DIR}/flake8 --verbose
  popd
else
  pushd "${OSA_CLONE_DIR}/playbooks"
    # Disable Ansible color output
    export ANSIBLE_NOCOLOR=1

    # Create ansible logging directory
    mkdir -p ${ANSIBLE_LOG_DIR}

    # Log some data about the instance and the rest of the system
    log_instance_info

    # First we gather facts about the hosts to populate the fact cache.
    # We can't gather the facts for all hosts yet because the containers
    # aren't built yet.
    ansible -m setup -a 'gather_subset=network,hardware,virtual' hosts 2>${ANSIBLE_LOG_DIR}/facts-hosts.log

    # Prepare the hosts
    export ANSIBLE_LOG_PATH="${ANSIBLE_LOG_DIR}/setup-hosts.log"
    openstack-ansible setup-hosts.yml -e osa_gather_facts=False

    # Log some data about the instance and the rest of the system
    log_instance_info

    # Once setup-hosts is complete, we should gather facts for everything
    # (now including containers) so that the fact cache is complete for the
    # remainder of the run.
    ansible -m setup -a 'gather_subset=network,hardware,virtual' all 1>${ANSIBLE_LOG_DIR}/facts-all.log

    # Prepare the infrastructure
    export ANSIBLE_LOG_PATH="${ANSIBLE_LOG_DIR}/setup-infrastructure.log"
    openstack-ansible setup-infrastructure.yml -e osa_gather_facts=False

    # Log some data about the instance and the rest of the system
    log_instance_info

    # Setup OpenStack
    export ANSIBLE_LOG_PATH="${ANSIBLE_LOG_DIR}/setup-openstack.log"
    openstack-ansible setup-openstack.yml -e osa_gather_facts=False

    # Log some data about the instance and the rest of the system
    log_instance_info

  popd
fi

# If the action is to upgrade, then checkout the original SHA for
# the checkout, and execute the upgrade.
if [[ "${ACTION}" == "upgrade" ]]; then

    # Checkout the original HEAD we started with
    git checkout ${UPGRADE_TARGET_BRANCH}

    # Unset environment variables used by the bootstrap-ansible
    # script to allow newer versions of Ansible and global
    # requirements to be installed.
    unset ANSIBLE_PACKAGE
    unset UPPER_CONSTRAINTS_FILE
    unset PIP_OPTS

    load_nodepool_pip_opts

    # Source the current scripts-library.sh functions
    source "${OSA_CLONE_DIR}/scripts/scripts-library.sh"

    # To execute the upgrade script we need to provide
    # an affirmative response to the warning that the
    # upgrade is irreversable.
    echo 'YES' | bash "${OSA_CLONE_DIR}/scripts/run-upgrade.sh"

fi

exit_success
