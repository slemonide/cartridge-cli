local t = require('luatest')
local app = require('cartridge-cli')

local g = t.group('dockerfile_constructors')

local function remove_leading_spaces(s, spaces_num)
    spaces_num = spaces_num or 8
    local REMOVE_PATTERN = string.format('^%s', string.rep(' ', spaces_num))

    local res_lines = {}
    for _, line in ipairs(s:split('\n')) do
        local res_line = line:gsub(REMOVE_PATTERN, '')
        table.insert(res_lines, res_line)
    end

    return table.concat(res_lines, '\n')
end

local function get_install_tarantool_enterprise_layers(sdk_version)
    local layers = remove_leading_spaces([=[
        ### Install Tarantool Enterprise
        ARG DOWNLOAD_TOKEN

        RUN DOWNLOAD_URL=https://tarantool:${DOWNLOAD_TOKEN}@download.tarantool.io \
            && mkdir -p /usr/share/tarantool \
            && cd /usr/share/tarantool \
            && curl -O -L ${DOWNLOAD_URL}/enterprise/tarantool-enterprise-bundle-SDK_VERSION.tar.gz \
            && tar -xzf tarantool-enterprise-bundle-SDK_VERSION.tar.gz \
            && rm -rf tarantool-enterprise-bundle-SDK_VERSION.tar.gz

        ENV PATH="/usr/share/tarantool/tarantool-enterprise:${PATH}"
    ]=]):strip():gsub('SDK_VERSION', sdk_version)

    return layers
end

local function get_install_tarantool_opensource_layers(repo_version)
    local layers = remove_leading_spaces([=[
        ### Install opensource Tarantool
        RUN curl -s \
                https://packagecloud.io/install/repositories/tarantool/REPO_VERSION/script.rpm.sh | bash \
            && yum -y install tarantool tarantool-devel
    ]=]):strip():gsub('REPO_VERSION', repo_version)

    return layers
end

local function get_prepare_layers()
    local layers = remove_leading_spaces([=[
        ### Prepare
        SHELL ["/bin/bash", "-c"]

        RUN yum install -y git gcc make cmake unzip

        # create user and directories
        RUN groupadd -r tarantool \
            && useradd -M -N -g tarantool -r -d /var/lib/tarantool -s /sbin/nologin \
                -c "Tarantool Server" tarantool \
            &&  mkdir -p /var/lib/tarantool/ --mode 755 \
            && chown tarantool:tarantool /var/lib/tarantool \
            && mkdir -p /var/run/tarantool/ --mode 755 \
            && chown tarantool:tarantool /var/run/tarantool
    ]=]):strip()

    return layers
end

local function get_dockerfile_set_path_layers(app_name)
    local layers = string.gsub(
        'ENV PATH="/usr/share/tarantool/APP_NAME:${PATH}"\n',
        'APP_NAME', app_name
    )
    return layers
end

local function get_copy_code_layers(app_name)
    local layers = string.gsub(
        'COPY . /usr/share/tarantool/APP_NAME\n',
        'APP_NAME', app_name
    )
    return layers
end

local function get_dockerfile_runtime_layers(app_name)
    local layers = remove_leading_spaces([=[
        ### Application runtime
        RUN echo 'd /var/run/tarantool 0755 tarantool tarantool' > /usr/lib/tmpfiles.d/APP_NAME.conf \
        && chmod 644 /usr/lib/tmpfiles.d/APP_NAME.conf
        USER tarantool:tarantool
        CMD TARANTOOL_WORKDIR=/var/lib/tarantool/APP_NAME.${TARANTOOL_INSTANCE_NAME:-default} \
            TARANTOOL_PID_FILE=/var/run/tarantool/APP_NAME.${TARANTOOL_INSTANCE_NAME:-default}.pid \
            TARANTOOL_CONSOLE_SOCK=/var/run/tarantool/APP_NAME.${TARANTOOL_INSTANCE_NAME:-default}.control \
            tarantool /usr/share/tarantool/APP_NAME/init.lua
    ]=]):strip():gsub('APP_NAME', app_name)
    return layers
end

local function get_non_emply_lines(str)
    local lines = {}
    for _, line in ipairs(str:split('\n') or {}) do
        if line ~= '' then
            table.insert(lines, line)
        end
    end
    return lines
end

local function assert_lines_are_equal(str1, str2)
    t.assert_equals(
        get_non_emply_lines(str1:strip()),
        get_non_emply_lines(str2:strip())
    )
end

g.test_install_tarantool_constructor = function()
    local constructor = app.dockerfile_constructors.install_tarantool

    -- Tarantool Enterprise
    local sdk_version = 'SDK_VERSION'
    _G.app_state.tarantool_is_enterprise = true
    _G.app_state.sdk_version = sdk_version

    local expected_dockerfile = get_install_tarantool_enterprise_layers(sdk_version)
    assert_lines_are_equal(constructor(), expected_dockerfile)

    -- Tarantool 2.1
    _G.app_state.tarantool_is_enterprise = false
    _G.app_state.sdk_version = nil
    _G.app_state.tarantool_version = '2.1.42'

    local expected_dockerfile = get_install_tarantool_opensource_layers('2x')
    assert_lines_are_equal(constructor(), expected_dockerfile)

    -- Tarantool 1.10
    _G.app_state.tarantool_is_enterprise = false
    _G.app_state.sdk_version = nil
    _G.app_state.tarantool_version = '1.10.42'

    local expected_dockerfile = get_install_tarantool_opensource_layers('1_10')
    assert_lines_are_equal(constructor(), expected_dockerfile)
end

g.test_build_image_dockerfile_constructor = function()
    local constructor = app.dockerfile_constructors.build
    local sdk_version = 'SDK_VERSION'

    local build_base_dockerfile_layers = remove_leading_spaces([=[
        ### Base layers
        FROM centos:8
        RUN yum install -y zip
    ]=])

    -- Tarantool Enterprise
    _G.app_state.tarantool_is_enterprise = true
    _G.app_state.sdk_version = sdk_version
    _G.app_state.build_base_dockerfile_layers = build_base_dockerfile_layers

    local expected_dockerfile = table.concat({
        build_base_dockerfile_layers,
        get_prepare_layers(),
        get_install_tarantool_enterprise_layers(sdk_version)
    }, '\n')

    assert_lines_are_equal(constructor(), expected_dockerfile)

    -- Tarantool Opensource
    _G.app_state.tarantool_is_enterprise = false
    _G.app_state.sdk_version = nil
    _G.app_state.tarantool_version = '2.1.42'
    _G.app_state.build_base_dockerfile_layers = build_base_dockerfile_layers

    local expected_dockerfile = table.concat({
        build_base_dockerfile_layers,
        get_prepare_layers(),
        get_install_tarantool_opensource_layers('2x')
    }, '\n')

    assert_lines_are_equal(constructor(), expected_dockerfile)

    -- app_state.build_base_dockerfile_layers is required
    _G.app_state.tarantool_is_enterprise = false
    _G.app_state.sdk_version = nil
    _G.app_state.tarantool_version = '2.1.42'
    _G.app_state.build_base_dockerfile_layers = nil
    local ok, err = pcall(constructor)
    t.assert_equals(ok, false)
    t.assert_str_icontains(err, 'build base dockerfile layers should be set')
end

g.test_runtime_image_dockerfile_constructor = function()
    local constructor = app.dockerfile_constructors.runtime
    local sdk_version = 'SDK_VERSION'
    local app_name = 'myapp'

    local runtime_base_dockerfile_layers = remove_leading_spaces([=[
        ### Base layers
        FROM centos:8
        RUN yum install -y unzip
    ]=])

    -- Tarantool Enterprise
    _G.app_state.name = app_name
    _G.app_state.tarantool_is_enterprise = true
    _G.app_state.sdk_version = sdk_version
    _G.app_state.runtime_base_dockerfile_layers = runtime_base_dockerfile_layers

    local expected_dockerfile = table.concat({
        runtime_base_dockerfile_layers,
        get_prepare_layers(),
        get_copy_code_layers(app_name),
        get_dockerfile_set_path_layers(app_name),
        get_dockerfile_runtime_layers(app_name),
    }, '\n')

    assert_lines_are_equal(constructor(), expected_dockerfile)

    -- Tarantool Opensource
    _G.app_state.name = app_name
    _G.app_state.tarantool_is_enterprise = false
    _G.app_state.sdk_version = nil
    _G.app_state.tarantool_version = '2.1.42'
    _G.app_state.runtime_base_dockerfile_layers = runtime_base_dockerfile_layers

    local expected_dockerfile = table.concat({
        runtime_base_dockerfile_layers,
        get_prepare_layers(),
        get_install_tarantool_opensource_layers('2x'),
        get_copy_code_layers(app_name),
        get_dockerfile_runtime_layers(app_name),
    }, '\n')

    assert_lines_are_equal(constructor(), expected_dockerfile)

    -- app_state.runtime_base_dockerfile_layers is required
    _G.app_state.tarantool_is_enterprise = false
    _G.app_state.sdk_version = nil
    _G.app_state.tarantool_version = '2.1.42'
    _G.app_state.runtime_base_dockerfile_layers = nil
    local ok, err = pcall(constructor)
    t.assert_equals(ok, false)
    t.assert_str_icontains(err, 'runtime base dockerfile layers should be set')
end
