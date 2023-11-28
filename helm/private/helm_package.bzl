"""Helm rules"""

load("//helm:providers.bzl", "HelmPackageInfo")
load("//helm/private:helm_utils.bzl", "is_stamping_enabled")

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

    templates_manifest = ctx.actions.declare_file("{}/templates_manifest.json".format(ctx.label.name))
    ctx.actions.write(
        output = templates_manifest,
        content = json.encode_indent({file.path: file.short_path for file in ctx.files.data}, indent = " " * 4),
    )
    args.add("-templates_manifest", templates_manifest)

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
            ctx.files.data + stamps + image_inputs + deps + [chart_yaml, values_yaml, templates_manifest],
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
