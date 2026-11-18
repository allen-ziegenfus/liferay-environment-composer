#!/bin/bash

load helpers/setup

setup_file() {
	BATS_TEST_NAME_PREFIX="Elasticsearch: "
	export BATS_TEST_NAME_PREFIX

	common_setup_file
}

setup() {
	common_setup

	_writeProperty "lr.docker.environment.service.enabled[mysql]" "true"
	_writeProperty "lr.docker.environment.service.enabled[elasticsearch]" "true"
}

teardown() {
	common_teardown
}

@test "ES7 service and connector on a 2024.q release" {
	_debug "RUNNING ${BATS_TEST_NAME}"

	_writeProperty "liferay.workspace.product" "dxp-2024.q3.8"
	_writeProperty "lr.docker.environment.service.version[elasticsearch]" "7.17.9"

	_startup

	local esPort
	esPort="$(_getServicePort "elasticsearch" "9200")"

	run curl -s "http://localhost:${esPort}/"
	assert_success
	assert_output --regexp '"number" *: *"7\.17\.9"'

	run curl -s "http://localhost:${esPort}/_nodes/_local/settings?flat_settings=true"
	assert_success
	assert_output --partial '"xpack.monitoring.enabled":"false"'
	assert_output --partial '"xpack.sql.enabled":"false"'

	local liferayPort
	liferayPort="$(_getServicePort "liferay" "8080")"

	_assertHttpStatus "http://localhost:${liferayPort}"

	run curl -s "http://localhost:${esPort}/_cat/indices?h=index"
	assert_success
	assert_output --regexp 'liferay-[0-9]+'

	run docker compose logs liferay
	assert_success
	refute_line --regexp 'ERROR.*[Ee]lastic'
	refute_line --regexp 'ERROR.*[Ss]earch'
}

@test "ES8 service via the ES7 connector on a 2025.q release" {
	_debug "RUNNING ${BATS_TEST_NAME}"

	_writeProperty "liferay.workspace.product" "dxp-2025.q1.0-lts"
	_writeProperty "lr.docker.environment.service.version[elasticsearch]" "8.19.12"

	_startup

	local esPort
	esPort="$(_getServicePort "elasticsearch" "9200")"

	run curl -s "http://localhost:${esPort}/"
	assert_success
	assert_output --regexp '"number" *: *"8\.19\.12"'

	local liferayPort
	liferayPort="$(_getServicePort "liferay" "8080")"

	_assertHttpStatus "http://localhost:${liferayPort}"

	run curl -s "http://localhost:${esPort}/_cat/indices?h=index"
	assert_success
	assert_output --regexp 'liferay-[0-9]+'

	run docker compose logs liferay
	assert_success
	refute_line --regexp 'ERROR.*[Ee]lastic'
	refute_line --regexp 'ERROR.*[Ss]earch'
	refute_line --regexp 'Sidecar Elasticsearch .* started'
}