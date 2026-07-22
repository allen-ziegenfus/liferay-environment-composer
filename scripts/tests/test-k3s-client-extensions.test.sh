#!/bin/bash

load helpers/setup

setup_file() {
	BATS_TEST_NAME_PREFIX="k3s Client Extensions: "
	export BATS_TEST_NAME_PREFIX

	common_setup_file
}

setup() {
	common_setup

	_writeProperty "lr.docker.environment.service.enabled[k3s]" "true"

	# Stage one fixture Client Extension per type into the workspace. These carry
	# only LCP.json (+ a client-extension config) so renderClientExtensions can
	# map them to manifests without a cluster, DXP image, or license.
	mkdir -p "${TEST_WORKSPACE_DIR}/client-extensions"

	cp -r "${WORKSPACE_DIR}/scripts/tests/fixtures/k3s/." \
		"${TEST_WORKSPACE_DIR}/client-extensions/"
}

teardown() {
	common_teardown
}

@test "renderClientExtensions maps each CX type to the right k8s workload" {
	_debug "RUNNING ${BATS_TEST_NAME}"

	run ./gradlew renderClientExtensions --quiet --console=plain

	assert_success

	# Serving CX (Deployment with a targetPort) -> Deployment + Service + Ingress.
	assert_output --partial '"kind": "Deployment"'
	assert_output --partial '"kind": "Service"'
	assert_output --partial '"kind": "Ingress"'

	# Batch CX -> Job; cron CX -> CronJob carrying its schedule.
	assert_output --partial '"kind": "Job"'
	assert_output --partial '"kind": "CronJob"'
	assert_output --partial '"schedule": "0 */6 * * *"'

	# OAuth CX -> socat native sidecar (initContainer + restartPolicy: Always).
	assert_output --partial 'alpine/socat'
	assert_output --partial '"restartPolicy": "Always"'

	# baseURL is address-type-aware: objectAction (server-side webhook) resolves
	# to the in-cluster NodePort, while browser-facing CX use the ingress host.
	assert_output --partial 'http://k3s:'
	assert_output --partial '.localtest.me'
}