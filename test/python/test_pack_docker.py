#!/usr/bin/python3

import pytest
import os
import re
import subprocess
import tarfile

from utils import basepath
from utils import tarantool_version
from utils import tarantool_enterprise_is_used
from utils import recursive_listdir
from utils import assert_distribution_dir_contents
from utils import assert_filemodes
from utils import run_command_and_get_output
from utils import Image, find_image, delete_image


# #######
# Helpers
# #######
def run_command_on_image(docker_client, image_name, command):
    command = '/bin/bash -c "{}"'.format(command.replace('"', '\\"'))
    output = docker_client.containers.run(
        image_name,
        command,
        remove=True
    )
    return output.decode("utf-8").strip()


# ########
# Fixtures
# ########
@pytest.fixture(scope="function")
def docker_image(tmpdir, light_project, request, docker_client):
    project = light_project

    cmd = [os.path.join(basepath, "cartridge"), "pack", "docker", project.path]
    process = subprocess.run(cmd, cwd=tmpdir)
    assert process.returncode == 0, \
        "Error during creating of docker image"

    image_name = find_image(docker_client, project.name)
    assert image_name is not None, "Docker image isn't found"

    request.addfinalizer(lambda: delete_image(docker_client, image_name))

    image = Image(image_name, project)
    return image


# #####
# Tests
# #####
def test_pack(docker_image, tmpdir, docker_client):
    project = docker_image.project
    image_name = docker_image.name

    container = docker_client.containers.create(docker_image.name)
    container_distribution_dir = '/usr/share/tarantool/{}'.format(project.name)

    # check if distribution dir was created
    command = '[ -d "{}" ] && echo true || echo false'.format(container_distribution_dir)
    output = run_command_on_image(docker_client, image_name, command)
    assert output == 'true'

    # get distribution dir contents
    arhive_path = os.path.join(tmpdir, 'distribution_dir.tar')
    with open(arhive_path, 'wb') as f:
        bits, _ = container.get_archive(container_distribution_dir)
        for chunk in bits:
            f.write(chunk)

    with tarfile.open(arhive_path) as arch:
        arch.extractall(path=os.path.join(tmpdir, 'usr/share/tarantool'))
    os.remove(arhive_path)

    assert_distribution_dir_contents(
        dir_contents=recursive_listdir(os.path.join(tmpdir, 'usr/share/tarantool/', project.name)),
        project=project,
    )

    assert_filemodes(project, tmpdir)
    container.remove()

    if not tarantool_enterprise_is_used():
        # check if tarantool was installed
        command = 'yum list installed 2>/dev/null | grep tarantool'
        output = run_command_on_image(docker_client, image_name, command)

        packages_list = output.split('\n')
        assert any(['tarantool' in package for package in packages_list])

        # check tarantool version
        command = 'tarantool --version'
        output = run_command_on_image(docker_client, image_name, command)

        m = re.search(r'Tarantool\s+(\d+.\d+)', output)
        assert m is not None
        installed_version = m.group(1)

        m = re.search(r'(\d+.\d+)', tarantool_version())
        assert m is not None
        expected_version = m.group(1)

        assert installed_version == expected_version


def test_base_runtime_dockerfile_with_env_vars(project_without_dependencies, module_tmpdir, tmpdir):
    # The main idea of this test is to check that using `${name}` constructions
    #   in the base Dockerfile doesn't break the `pack docker` command running.
    # So, it's not about testing that the ENV option works, it's about
    #   testing that `pack docker` command wouldn't fail if the base Dockerfile
    #   contains `${name}` constructions.
    # The problem is the `expand` function.
    # Base Dockerfile with `${name}` shouldn't be passed to this function,
    #   otherwise it will raise an error or substitute smth wrong.
    dockerfile_with_env_path = os.path.join(tmpdir, 'Dockerfile')
    with open(dockerfile_with_env_path, 'w') as f:
        f.write('''
            FROM centos:8
            # comment this string to use cached image
            # ENV TEST_VARIABLE=${TEST_VARIABLE}
        ''')

    cmd = [
        os.path.join(basepath, "cartridge"),
        "pack", "docker",
        "--from", dockerfile_with_env_path,
        project_without_dependencies.path,
    ]
    rc, output = run_command_and_get_output(cmd, cwd=module_tmpdir)
    assert rc == 0
    assert 'Detected base Dockerfile {}'.format(dockerfile_with_env_path) in output


def test_invalid_base_runtime_dockerfile(project_without_dependencies, module_tmpdir, tmpdir):
    invalid_dockerfile_path = os.path.join(tmpdir, 'Dockerfile')
    with open(invalid_dockerfile_path, 'w') as f:
        f.write('''
            # Invalid dockerfile
            FROM ubuntu:xenial
        ''')

    cmd = [
        os.path.join(basepath, "cartridge"),
        "pack", "docker",
        "--use-docker",
        "--from", invalid_dockerfile_path,
        project_without_dependencies.path,
    ]

    rc, output = run_command_and_get_output(cmd, cwd=module_tmpdir)
    assert rc == 1
    assert 'Base Dockerfile validation failed' in output
    assert 'base image must be centos:8' in output


def test_project_witout_runtime_dockerfile(project_without_dependencies, tmpdir):
    project = project_without_dependencies

    os.remove(os.path.join(project.path, 'Dockerfile.cartridge'))

    cmd = [
        os.path.join(basepath, "cartridge"),
        "pack", "docker",
        "--use-docker",
        project.path,
    ]

    process = subprocess.run(cmd, cwd=tmpdir)
    assert process.returncode == 0
