"""Helm rules"""

load("//helm/private:helm_install.bzl", "helm_install", "helm_push", "helm_reinstall", "helm_uninstall")
load("//helm/private:helm_package.bzl", "helm_package")

def helm_chart(name, images = [], deps = None, tags = [], install_name = None, **kwargs):
    """Rules for producing a helm package and some convenience targets.

    | target | rule |
    | --- | --- |
    | `{name}` | [helm_package](#helm_package) |
    | `{name}.push` | [helm_push](#helm_push) |
    | `{name}.install` | [helm_install](#helm_install) |
    | `{name}.uninstall` | [helm_uninstall](#helm_uninstall) |
    | `{name}.reinstall` | [helm_reinstall](#helm_reinstall) |

    Args:
        name (str): The name of the [helm_package](#helm_package) target.
        images (list, optional): A list of [oci_push](https://github.com/bazel-contrib/rules_oci/blob/main/docs/push.md#oci_push_rule-remote_tags) targets
        deps (list, optional): A list of helm package dependencies.
        tags (list, optional): Tags to apply to all targets.
        install_name (str, optional): The `helm install` name to use. `name` will be used if unset.
        **kwargs (dict): Additional keyword arguments for `helm_package`.
    """
    helm_package(
        name = name,
        chart = "Chart.yaml",
        deps = deps,
        images = images,
        tags = tags,
        data = native.glob(["templates/**"]),
        values = "values.yaml",
        **kwargs
    )

    helm_push(
        name = name + ".push",
        package = name,
        tags = depset(tags + ["manual"]).to_list(),
    )

    if not install_name:
        install_name = name.replace("_", "-")

    helm_install(
        name = name + ".install",
        install_name = install_name,
        package = name,
        tags = depset(tags + ["manual"]).to_list(),
    )

    helm_uninstall(
        name = name + ".uninstall",
        install_name = install_name,
        tags = depset(tags + ["manual"]).to_list(),
    )

    helm_reinstall(
        name = name + ".reinstall",
        install_name = install_name,
        package = name,
        tags = depset(tags + ["manual"]).to_list(),
    )
