#!/usr/bin/python3

import subprocess
import pytest
import os

from project import Project
from utils import basepath
from utils import run_command_and_get_output


@pytest.fixture(scope="module")
def default_project(module_tmpdir):
    project = Project('default-project', module_tmpdir, 'cartridge')
    return project


def test_project(default_project):
    project = default_project

    process = subprocess.run(['tarantoolctl', 'rocks', 'make'], cwd=project.path)
    assert process.returncode == 0, "Error building project"

    process = subprocess.run(['./deps.sh'], cwd=project.path)
    assert process.returncode == 0, "Installing deps failed"

    process = subprocess.run(['.rocks/bin/luacheck', '.'], cwd=project.path)
    assert process.returncode == 0, "luacheck failed"

    process = subprocess.run(['.rocks/bin/luatest'], cwd=project.path)
    assert process.returncode == 0, "luatest failed"


def test_project_recreation(default_project):
    project = default_project

    # try to create project with the same name in the same place
    cmd = [
        os.path.join(basepath, "cartridge"), "create",
        "--name", project.name,
        "--template", project.template,
        project.basepath
    ]

    rc, output = run_command_and_get_output(cmd)
    assert rc == 1
    assert "directory '{}' already exists".format(project.path) in output

    # check that project directory wasn't deleted
    assert os.path.exists(project.path)
