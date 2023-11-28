"""Helm rules"""

load("//helm:providers.bzl", "HelmPackageInfo")
load("//helm/private:helm_utils.bzl", "is_stamping_enabled")

def safe_short_path(file_):
    """Like `File.short_path` but safe for use with files from external repositories.
    """
    # Note: "F" is "File", "FO": is "File.owner".  (Lifted from genpkg.bzl.)
    # | File type | Repo     | `F.path`                                                 | `F.root.path`                | `F.short_path`          | `FO.workspace_name` | `FO.workspace_root` |
    # |-----------|----------|----------------------------------------------------------|------------------------------|-------------------------|---------------------|---------------------|
    # | Source    | Local    | `dirA/fooA`                                              |                              | `dirA/fooA`             |                     |                     |
    # | Generated | Local    | `bazel-out/k8-fastbuild/bin/dirA/gen.out`                | `bazel-out/k8-fastbuild/bin` | `dirA/gen.out`          |                     |                     |
    # | Source    | External | `external/repo2/dirA/fooA`                               |                              | `../repo2/dirA/fooA`    | `repo2`             | `external/repo2`    |
    # | Generated | External | `bazel-out/k8-fastbuild/bin/external/repo2/dirA/gen.out` | `bazel-out/k8-fastbuild/bin` | `../repo2/dirA/gen.out` | `repo2`             | `external/repo2`    |

    # Beginning with `file_.path`, remove optional `F.root.path`.
    working_path = file_.path
    if not file_.is_source:
        working_path = working_path[len(file_.root.path) + 1:]
    return working_path

# buildifier: disable=function-docstring-args,function-docstring-return
def _short_path_dirname(path):
    """Returns the directory's name of the short path of an artifact."""
    sp = safe_short_path(path)
    last_pkg = sp.rfind("/")
    if last_pkg == -1:
        # Top-level BUILD file.
        return ""
    return sp[:last_pkg]

# buildifier: disable=function-docstring-args
# buildifier: disable=function-docstring-return
def dest_path(f, strip_prefix, data_path_without_prefix = ""):
    """Returns the short path of f, stripped of strip_prefix."""
    f_short_path = safe_short_path(f)
    if strip_prefix == None:
        # If no strip_prefix was specified, use the package of the
        # given input as the strip_prefix.
        strip_prefix = _short_path_dirname(f)
    if not strip_prefix:
        return f_short_path
    if f_short_path.startswith(strip_prefix):
        # Check that the last directory in strip_prefix is a complete
        # directory (so that we don't strip part of a dir name)
        prefix_last_dir_index = strip_prefix.rfind("/")
        prefix_last_dir = strip_prefix[prefix_last_dir_index + 1:]

        # Avoid stripping prefix if final directory is incomplete
        if prefix_last_dir not in f_short_path.split("/"):
            strip_prefix = data_path_without_prefix

        return f_short_path[len(strip_prefix):]
    return f_short_path

def compute_data_path(label, data_path):
    """Compute the relative data path prefix from the data_path attribute.

    Args:
        label: target label
        data_path: path to a file, relative to the package of the label.
    Returns:
        str
    """
    if data_path:
        # Strip ./ from the beginning if specified.
        # There is no way to handle .// correctly (no function that would make
        # that possible and Starlark is not turing complete) so just consider it
        # as an absolute path.
        if len(data_path) >= 2 and data_path[0:2] == "./":
            data_path = data_path[2:]
        if not data_path or data_path == ".":  # Relative to current package
            return label.package
        elif data_path[0] == "/":  # Absolute path
            return data_path[1:]
        else:  # Relative to a sub-directory
            tmp_short_path_dirname = label.package
            if tmp_short_path_dirname:
                return tmp_short_path_dirname + "/" + data_path
            return data_path
    else:
        return None

def _helm_package_impl(ctx):
    values_yaml = ctx.file.values
    chart_yaml = ctx.file.chart

    args = ctx.actions.args()

    output = ctx.actions.declare_file(ctx.label.name + ".tgz")
    metadata_output = ctx.actions.declare_file(ctx.label.name + ".metadata.json")
    args.add("-output", output)
    args.add("-metadata_output", metadata_output)

    toolchain = ctx.toolchains[Label("//helm:toolchain_type")]
    args.add("-helm", toolchain.helm)

    args.add("-chart", chart_yaml)
    args.add("-values", values_yaml)

    # Compute the relative path
    data_path = compute_data_path(ctx.label, ".")

    data_manifest = ctx.actions.declare_file("{}/data_manifest.json".format(ctx.label.name))
    ctx.actions.write(
        output = data_manifest,
        content = json.encode_indent(
            {
                file.path: dest_path(file, data_path)
                for file in ctx.files.data
            },
            indent = " " * 4,
        ),
    )
    args.add("-data_manifest", data_manifest)

    deps = []
    if ctx.attr.deps:
        deps.extend([dep[HelmPackageInfo].chart for dep in ctx.attr.deps])
        deps_manifest = ctx.actions.declare_file("{}/deps_manifest.json".format(ctx.label.name))
        ctx.actions.write(
            output = deps_manifest,
            content = json.encode_indent([dep.path for dep in deps], indent = " " * 4),
        )
        args.add("-deps_manifest", deps_manifest)
        deps.append(deps_manifest)

    # Create documents for each image the package depends on
    image_inputs = []
    if ctx.attr.images:
        single_image_manifests = []
        for image in ctx.attr.images:
            single_image_manifest = ctx.actions.declare_file("{}/{}".format(
                ctx.label.name,
                str(image.label).strip("@").replace("/", "_").replace(":", "_") + ".image_manifest",
            ))
            push_info = image[DefaultInfo]
            ctx.actions.write(
                output = single_image_manifest,
                content = json.encode_indent(
                    struct(
                        label = str(image.label),
                        paths = [manifest.path for manifest in push_info.default_runfiles.files.to_list()],
                    ),
                ),
            )
            image_inputs.extend(push_info.default_runfiles.files.to_list())
            single_image_manifests.append(single_image_manifest)

        image_manifest = ctx.actions.declare_file("{}/image_manifest.json".format(ctx.label.name))
        ctx.actions.write(
            output = image_manifest,
            content = json.encode_indent([manifest.path for manifest in single_image_manifests], indent = " " * 4),
        )
        image_inputs.append(image_manifest)
        image_inputs.extend(single_image_manifests)
        args.add("-image_manifest", image_manifest)
    stamps = []
    if is_stamping_enabled(ctx.attr):
        args.add("-volatile_status_file", ctx.version_file)
        args.add("-stable_status_file", ctx.info_file)
        stamps.extend([ctx.version_file, ctx.info_file])

    args.add("-workspace_name", ctx.workspace_name)

    ctx.actions.run(
        executable = ctx.executable._packager,
        outputs = [output, metadata_output],
        inputs = depset(
            ctx.files.data + stamps + image_inputs + deps + [chart_yaml, values_yaml, data_manifest],
        ),
        tools = depset([toolchain.helm]),
        mnemonic = "HelmPackage",
        arguments = [args],
        progress_message = "Creating Helm Package for {}".format(
            ctx.label,
        ),
    )

    return [
        DefaultInfo(
            files = depset([output]),
            runfiles = ctx.runfiles([output]),
        ),
        HelmPackageInfo(
            chart = output,
            metadata = metadata_output,
            images = ctx.attr.images,
        ),
    ]

helm_package = rule(
    implementation = _helm_package_impl,
    doc = "",
    attrs = {
        "chart": attr.label(
            doc = "The `Chart.yaml` file of the helm chart",
            allow_single_file = ["Chart.yaml"],
        ),
        "deps": attr.label_list(
            doc = "Other helm packages this package depends on.",
            providers = [HelmPackageInfo],
        ),
        "images": attr.label_list(
            doc = "[@rules_oci//oci:defs.bzl%oci_push](https://github.com/bazel-contrib/rules_oci/blob/main/docs/push.md#oci_push_rule-remote_tags) targets.",
        ),
        "stamp": attr.int(
            doc = """\
                Whether to encode build information into the helm actions. Possible values:

                - `stamp = 1`: Always stamp the build information into the helm actions, even in \
                [--nostamp](https://docs.bazel.build/versions/main/user-manual.html#flag--stamp) builds. \
                This setting should be avoided, since it potentially kills remote caching for the target and \
                any downstream actions that depend on it.

                - `stamp = 0`: Always replace build information by constant values. This gives good build result caching.

                - `stamp = -1`: Embedding of build information is controlled by the \
                [--[no]stamp](https://docs.bazel.build/versions/main/user-manual.html#flag--stamp) flag.

                Stamped targets are not rebuilt unless their dependencies change.
            """,
            default = -1,
            values = [1, 0, -1],
        ),
        "data": attr.label_list(
            doc = "All data associated with the current helm chart. E.g., the `./templates` directory",
            allow_files = True,
        ),
        "values": attr.label(
            doc = "The `values.yaml` file for the current package.",
            allow_single_file = ["values.yaml"],
        ),
        "_packager": attr.label(
            doc = "A process wrapper for producing the helm package's `tgz` file",
            cfg = "exec",
            executable = True,
            default = Label("//helm/private/packager"),
        ),
        "_stamp_flag": attr.label(
            doc = "A setting used to determine whether or not the `--stamp` flag is enabled",
            default = Label("//helm/private:stamp"),
        ),
    },
    toolchains = [
        str(Label("@rules_helm//helm:toolchain_type")),
    ],
)
