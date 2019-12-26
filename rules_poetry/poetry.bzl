load(":json_parser.bzl", "json_parse")

def _clean_name(name):
    return name.lower().replace("-", "_").replace(".", "_")

def _mapping(repository_ctx):
    result = repository_ctx.execute(
        [
            repository_ctx.path(repository_ctx.attr._script),
            "-i",
            repository_ctx.path(repository_ctx.attr.pyproject),
            "-o",
            "/dev/stdout",
            "--if",
            "toml",
            "--of",
            "json",
        ],
    )

    if result.return_code:
        fail("remarshal failed: %s (%s)" % (result.stdout, result.stderr))

    pyproject = json_parse(result.stdout)
    return {
        dep.lower(): "@%s//:library_%s" % (repository_ctx.name, _clean_name(dep))
        for dep in pyproject["tool"]["poetry"]["dependencies"].keys()
    }

def _impl(repository_ctx):
    mapping = _mapping(repository_ctx)

    result = repository_ctx.execute(
        [
            repository_ctx.path(repository_ctx.attr._script),
            "-i",
            repository_ctx.path(repository_ctx.attr.lockfile),
            "-o",
            "/dev/stdout",
            "--if",
            "toml",
            "--of",
            "json",
        ],
    )

    if result.return_code:
        fail("remarshal failed: %s (%s)" % (result.stdout, result.stderr))

    lockfile = json_parse(result.stdout)
    metadata = lockfile["metadata"]
    if "files" in metadata:  # Poetry 1.x format
        files = metadata["files"]

        # only the hashes are needed to build a requirements.txt
        hashes = {
            k: [x["hash"] for x in v]
            for k, v in files.items()
        }
    elif "hashes" in metadata:  # Poetry 0.x format
        hashes = ["sha256:" + h for h in metadata["hashes"]]
    else:
        fail("Did not find file hashes in poetry.lock file")

    # using a `dict` since there is no `set` type
    excludes = {x.lower(): True for x in repository_ctx.attr.excludes}
    for requested in mapping:
        if requested.lower() in excludes:
            fail("pyproject.toml dependency {} is also in the excludes list".format(requested))

    packages = []
    for package in lockfile["package"]:
        name = package["name"]

        if name.lower() in excludes:
            continue

        if "source" in package:
            # TODO: figure out how to deal with git and directory refs
            print("Skipping " + name)
            continue

        packages.append(struct(
            name = _clean_name(name),
            pkg = name,
            version = package["version"],
            hashes = hashes[name],
            marker = package.get("marker", None),
            dependencies = [
                _clean_name(name)
                for name in package.get("dependencies", {}).keys()
                if name.lower() not in excludes
            ],
        ))

    repository_ctx.file(
        "dependencies.bzl",
        """
_mapping = {mapping}

all_dependencies = _mapping.values()

def dependency(name):
    if name not in _mapping:
        fail("%s is not present in pyproject.toml" % name)

    return _mapping[name]
""".format(mapping = mapping),
    )

    repository_ctx.symlink(repository_ctx.path(repository_ctx.attr._rules), repository_ctx.path("defs.bzl"))

    poetry_template = """
download_wheel(
    name = "wheel_{name}",
    pkg = "{pkg}",
    version = "{version}",
    hashes = {hashes},
    marker = "{marker}",
    visibility = ["//visibility:private"],
    tags = ["no-remote-cache", "requires-network"],
)

pip_install(
    name = "install_{name}",
    wheel = ":wheel_{name}",
    tags = ["no-remote-cache"],
)

py_library(
    name = "library_{name}",
    srcs = glob(["{pkg}/**/*.py"]),
    data = glob(["{pkg}/**/*"], exclude=["**/*.py", "**/* *", "BUILD", "WORKSPACE"]),
    imports = ["{pkg}"],
    deps = {dependencies},
    visibility = ["//visibility:public"],
)
"""

    build_content = """
load("//:defs.bzl", "download_wheel")
load("//:defs.bzl", "noop")
load("//:defs.bzl", "pip_install")
"""

    for package in packages:
        build_content += poetry_template.format(
            name = _clean_name(package.name),
            pkg = package.pkg,
            version = package.version,
            hashes = package.hashes,
            marker = package.marker or "",
            dependencies = [":install_%s" % _clean_name(package.name)] +
                           [":library_%s" % _clean_name(dep) for dep in package.dependencies],
        )

    excludes_template = """
noop(
    name = "library_{name}",
)
    """

    for package in excludes:
        build_content += excludes_template.format(
            name = _clean_name(package),
        )

    repository_ctx.file("BUILD", build_content)

poetry = repository_rule(
    attrs = {
        "pyproject": attr.label(
            mandatory = True,
            allow_single_file = True,
        ),
        "lockfile": attr.label(
            mandatory = True,
            allow_single_file = True,
        ),
        "excludes": attr.string_list(
            mandatory = False,
            allow_empty = True,
            default = [],
            doc = "List of packages to exclude, useful for skipping invalid dependencies",
        ),
        "_rules": attr.label(
            default = ":defs.bzl",
        ),
        "_script": attr.label(
            executable = True,
            default = "//tools:remarshal.par",
            cfg = "host",
        ),
    },
    implementation = _impl,
    local = False,
)
