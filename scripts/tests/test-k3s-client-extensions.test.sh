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

	# homePageURL is consumed server-side (OAuth app audience + the address the
	# object-action catapult posts to), so it must resolve to the NodePort, never
	# the browser ingress host. (It is rendered inside the ext-provision ConfigMap
	# as escaped JSON, hence the loose match around the key.)
	assert_output --regexp 'homePageURL.{2,6}http://k3s:'
	refute_output --regexp 'homePageURL.{2,6}http://cxoauthaction'
}

@test "renderClientExtensions discovers a packaged (*.zip) CX like a source directory" {
	_debug "RUNNING ${BATS_TEST_NAME}"

	command -v zip > /dev/null || skip "zip not available"

	# A CX may be supplied either as a source directory (LCP.json at its root) or
	# as a built *.zip artifact -- the common LEC input form. Repackage the serving
	# fixture as a zip and drop the directory so only the archive remains.
	local ce="${TEST_WORKSPACE_DIR}/client-extensions"

	(cd "${ce}/cx-serving" && zip -qr "${ce}/cx-serving.zip" .)

	rm -rf "${ce}/cx-serving"

	run ./gradlew renderClientExtensions --quiet --console=plain

	assert_success

	# The archive materializes to the same Deployment + Service + Ingress trio.
	assert_output --partial '"kind": "Deployment"'
	assert_output --partial '"kind": "Service"'
	assert_output --partial '"kind": "Ingress"'
	assert_output --partial 'cxserving'
}

@test "renderClientExtensions honors a virtual-instance override (multi-tenant)" {
	_debug "RUNNING ${BATS_TEST_NAME}"

	run ./gradlew renderClientExtensions --quiet --console=plain \
		-PvirtualInstanceId=acme

	assert_success

	# The resolved vid flows into the ingress host, the LXC annotation, and the
	# CX's self-declared virtualInstanceId -- consistently, so a second instance
	# is addressable and registers under the intended tenant.
	assert_output --partial '.acme.localtest.me'
	assert_output --partial '"dxp.lxc.liferay.com/virtualInstanceId": "acme"'
	assert_output --regexp 'dxp.lxc.liferay.com.virtualInstanceId.{2,6}acme'
	refute_output --partial '.default.localtest.me'
}