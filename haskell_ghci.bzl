# Copyright (c) Meta Platforms, Inc. and affiliates.
#
# This source code is licensed under both the MIT license found in the
# LICENSE-MIT file in the root directory of this source tree and the Apache
# License, Version 2.0 found in the LICENSE-APACHE file in the root directory
# of this source tree.

load("@prelude//:paths.bzl", "paths")
load("@prelude//cxx:cxx_context.bzl", "get_cxx_toolchain_info")
load("@prelude//cxx:cxx_toolchain_types.bzl", "PicBehavior")
load(
    "@prelude//cxx:link.bzl",
    "cxx_link_shared_library",
)
load(
    "@prelude//cxx:link_types.bzl",
    "link_options",
)
load("@prelude//linking:execution_preference.bzl", "LinkExecutionPreference")
load(
    "@prelude//linking:link_info.bzl",
    "LinkArgs",
    "LinkInfo",
    "LinkStyle",
    "get_lib_output_style",
    "set_linkable_link_whole",
    "to_link_strategy",
)
load(
    "@prelude//linking:linkable_graph.bzl",
    "LinkableGraph",
    "LinkableRootInfo",
    "create_linkable_graph",
    "get_deps_for_link",
    "get_link_info",
)
load(
    "@prelude//linking:shared_libraries.bzl",
    "SharedLibraryInfo",
    "create_shlib_symlink_tree",
    "traverse_shared_library_info",
    "with_unique_str_sonames",
)
load("@prelude//linking:types.bzl", "Linkage")
load(
    "@prelude//cxx:linker.bzl",
    "get_rpath_origin",
)
load(
    "@prelude//utils:graph_utils.bzl",
    "depth_first_traversal",
    "depth_first_traversal_by",
)
load("@prelude//utils:argfile.bzl", "at_argfile")
load("@prelude//utils:utils.bzl", "flatten")
load(
    ":compile.bzl",
    "PackagesInfo",
    "compile",
    "get_packages_info",
    "target_metadata",
)
load(
    ":ghc_plugin.bzl",
    "GhcPluginInfo",
    "compute_plugin_flags",
    "validate_plugins_attrs",
)
load(
    ":library_info.bzl",
    "HaskellLibraryInfo",
    "HaskellLibraryInfoTSet",
    "HaskellLibraryProvider",
    "HaskellPackageConfInfo",
    "HaskellSourceInfo",
)
load(":link_info.bzl", "HaskellLinkInfo")
load(
    ":toolchain.bzl",
    "DynamicHaskellToolchainPackageDbInfo",
    "HaskellToolchainInfo",
    "HaskellToolchainLibrary",
    "HaskellToolchainPackageDbTSet",
)
load(
    ":util.bzl",
    "attr_deps",
    "attr_deps_haskell_lib_infos",
    "attr_deps_haskell_link_group_infos",
    "attr_deps_haskell_link_infos",
    "get_artifact_suffix",
    "make_haskell_names_from_label",
)

GHCiPreloadDepsInfo = record(
    preload_symlinks = dict[str, Artifact],
    preload_deps_root = Artifact,
)

USER_GHCI_PATH = "user_ghci_path"
BINUTILS_PATH = "binutils_path"
GHCI_LIB_PATH = "ghci_lib_path"
CC_PATH = "cc_path"
CPP_PATH = "cpp_path"
CXX_PATH = "cxx_path"
GHCI_PACKAGER = "ghc_pkg_path"
GHCI_GHC_PATH = "ghc_path"

HaskellOmnibusData = record(
    omnibus = Artifact,
    so_symlinks_root = Artifact,
)

def _write_final_ghci_script(
        ctx: AnalysisContext,
        omnibus_data: HaskellOmnibusData,
        packages_info: PackagesInfo,
        packagedb_args: cmd_args,
        prebuilt_packagedb_args: cmd_args,
        iserv_script: Artifact,
        start_ghci_file: Artifact,
        ghci_bin: Artifact,
        haskell_toolchain: HaskellToolchainInfo,
        ghci_script_template: Artifact,
        enable_profiling: bool,
        srcs_override: [str, None] = None,
        ghci_exposed_package_args: [cmd_args, None] = None,
        dep_srcs_flag: [str, None] = None) -> Artifact:
    # When srcs are pre-compiled as a package, pass None to omit them from
    # the GHCi script (they'll be loaded via -package instead).
    if srcs_override != None:
        srcs = srcs_override
    else:
        srcs = " ".join(
            [
                paths.normalize(paths.join(str(ctx.label.path), str(s)))
                for s in ctx.attrs.srcs
            ],
        )

    # Collect compiler flags
    compiler_flags = cmd_args(
        # TODO(gustavoavena): do I need to filter these flags?
        filter(lambda x: x == "-O", haskell_toolchain.compiler_flags),
        delimiter = " ",
    )

    compiler_flags.add([
        "-fPIC",
        "-fexternal-dynamic-refs",
        "-hide-all-packages",
        "-package-env=-",
    ])

    if enable_profiling:
        compiler_flags.add([
            "-prof",
            "-osuf p_o",
            "-hisuf p_hi",
        ])

    compiler_flags.add(ctx.attrs.compiler_flags)
    omnibus_so = omnibus_data.omnibus

    effective_exposed_package_args = (
        ghci_exposed_package_args if ghci_exposed_package_args != None
        else packages_info.exposed_package_args
    )

    final_ghci_script = _replace_macros_in_script_template(
        ctx,
        script_template = ghci_script_template,
        haskell_toolchain = haskell_toolchain,
        ghci_bin = ghci_bin,
        exposed_package_args = effective_exposed_package_args,
        packagedb_args = packagedb_args,
        prebuilt_packagedb_args = prebuilt_packagedb_args,
        start_ghci = start_ghci_file,
        iserv_script = iserv_script,
        squashed_so = omnibus_so,
        compiler_flags = compiler_flags,
        srcs = srcs,
        dep_srcs_flag = dep_srcs_flag,
        output_name = ctx.label.name,
    )

    return final_ghci_script

def _build_haskell_omnibus_so(ctx: AnalysisContext, omnibus_roots: list[Dependency] | None = None) -> HaskellOmnibusData:
    link_style = LinkStyle("static_pic")
    if False:
        # TODO(nga): typechecker raises issue here.
        def unknown():
            pass

        link_style = unknown()

    # pic_behavior = PicBehavior("always_enabled")
    pic_behavior = PicBehavior("supported")
    preload_deps = ctx.attrs.preload_deps

    if omnibus_roots == None:
        omnibus_roots = attr_deps(ctx) + preload_deps + ctx.attrs.template_deps

    linkable_graph_ = create_linkable_graph(
        ctx,
        deps = omnibus_roots,
    )

    # Keep only linkable nodes
    graph_nodes = {
        n.label: n.linkable
        for n in linkable_graph_.nodes.traverse()
        if n.linkable
    }

    # Map node label to its dependencies' labels
    dep_graph = {
        nlabel: get_deps_for_link(n, to_link_strategy(link_style), pic_behavior)
        for nlabel, n in graph_nodes.items()
    }

    all_direct_deps = []
    for dep in omnibus_roots:
        graph = dep.get(LinkableGraph)
        if graph:
            all_direct_deps.append(graph.label)
    dep_graph[ctx.label] = all_direct_deps

    # Need to exclude all transitive deps of excluded deps
    all_nodes_to_exclude = depth_first_traversal(
        dep_graph,
        [dep.label for dep in preload_deps],
    )

    # Body nodes should support haskell omnibus (e.g. cxx_library)
    # and can't be prebuilt tp dependencies
    body_nodes = {}

    # Prebuilt (i.e. third-party) nodes shouldn't be statically linked on
    # the omnibus, but we need to keep track of them because they're a
    # dependency of it and are linked dynamically.
    prebuilt_so_deps = {}

    # Helper to get body nodes and prebuilt dependencies of the
    # omnibus SO (which should dynamically linked) during BFS traversal
    def find_deps_for_body(node_label: Label):
        deps = dep_graph[node_label]

        final_deps = []
        for node_label in deps:
            node = graph_nodes[node_label]

            # We process these libs even if they're excluded, as they need to
            # be added to the link line.
            if "prebuilt_so_for_haskell_omnibus" in node.labels:
                # If the library is marked as force-static, then it won't provide
                # shared libs and we'll have to link is statically.
                if node.preferred_linkage == Linkage("static"):
                    body_nodes[node_label] = None
                else:
                    prebuilt_so_deps[node_label] = None

            if node_label in all_nodes_to_exclude:
                continue

            if "supports_haskell_omnibus" in node.labels and "prebuilt_so_for_haskell_omnibus" not in node.labels:
                body_nodes[node_label] = None

            final_deps.append(node_label)

        return final_deps

    # This is not the final set of body nodes, because it still includes
    # nodes that don't support omnibus (e.g. haskell_library nodes)
    depth_first_traversal_by(
        dep_graph,
        [ctx.label],
        find_deps_for_body,
    )

    # After collecting all the body nodes, get all their linkables (e.g. `.a`
    # files) that will be part of the omnibus SO.
    body_link_infos = {}

    for node_label in body_nodes.keys():
        node = graph_nodes[node_label]

        node_target = node_label.raw_target()
        if (node_target in body_link_infos):
            # Not skipping these leads to duplicate symbol errors
            continue

        output_style = get_lib_output_style(
            to_link_strategy(link_style),
            node.preferred_linkage,
            pic_behavior = pic_behavior,
        )

        li = get_link_info(node, output_style)
        linkables = [
            # All symbols need to be included in the omnibus so, even if
            # they're not being referenced yet, so we should enable
            # link_whole which passes the `--whole-archive` linker flag.
            set_linkable_link_whole(linkable)
            for linkable in li.linkables
        ]
        new_li = LinkInfo(
            name = li.name,
            pre_flags = li.pre_flags,
            post_flags = li.post_flags,
            linkables = linkables,
            external_debug_info = li.external_debug_info,
        )
        body_link_infos[node_target] = new_li

    # Handle third-party dependencies of the omnibus SO
    tp_deps_shared_link_infos = {}
    prebuilt_shlibs = []

    for node_label in prebuilt_so_deps.keys():
        node = graph_nodes[node_label]

        output_style = get_lib_output_style(
            to_link_strategy(LinkStyle("shared")),
            node.preferred_linkage,
            pic_behavior = pic_behavior,
        )

        shared_li = node.link_infos.get(output_style, None)
        if shared_li != None:
            tp_deps_shared_link_infos[node_label] = shared_li.default
        prebuilt_shlibs.extend(node.shared_libs.libraries)

    # Create symlinks to the TP dependencies' SOs
    so_symlinks_root_path = ctx.label.name + ".so-symlinks"
    so_symlinks_root = create_shlib_symlink_tree(
        actions = ctx.actions,
        out = so_symlinks_root_path,
        shared_libs = prebuilt_shlibs,
    )

    linker_info = get_cxx_toolchain_info(ctx).linker_info
    soname = "libghci_dependencies.so"
    extra_ldflags = [
        "-rpath",
        "{}/{}".format(get_rpath_origin(linker_info.type), so_symlinks_root_path)
    ]
    link_result = cxx_link_shared_library(
        ctx,
        soname,
        opts = link_options(
            links = [
                LinkArgs(flags = cmd_args(cmd_args(extra_ldflags, delimiter=","), format="-Wl,{}")),
                LinkArgs(infos = body_link_infos.values()),
                LinkArgs(infos = tp_deps_shared_link_infos.values()),
            ],
            category_suffix = "omnibus",
            link_weight = linker_info.link_weight,
            identifier = soname,
            link_execution_preference = LinkExecutionPreference("any"),
        ),
    )
    omnibus = link_result.linked_object.output

    return HaskellOmnibusData(
        omnibus = omnibus,
        so_symlinks_root = so_symlinks_root,
    )

def _get_default_output(dependency: Dependency | None) -> Artifact | None:
    if dependency == None:
        return None
    return dependency.get(DefaultInfo).default_outputs[0]

# Use the script_template_processor.py script to generate a script from a
# script template.
def _replace_macros_in_script_template(
        ctx: AnalysisContext,
        script_template: Artifact,
        haskell_toolchain: HaskellToolchainInfo,
        # Optional artifacts
        ghci_bin: Artifact | None = None,
        start_ghci: Artifact | None = None,
        iserv_script: Artifact | None = None,
        squashed_so: Artifact | None = None,
        # Optional cmd_args
        exposed_package_args: [cmd_args, None] = None,
        packagedb_args: [cmd_args, None] = None,
        prebuilt_packagedb_args: [cmd_args, None] = None,
        compiler_flags: [cmd_args, None] = None,
        # Optional string args
        srcs: [str, None] = None,
        output_name: [str, None] = None,
        ghci_iserv_path: [Artifact, None] = None,
        preload_libs: [str, None] = None,
        dep_srcs_flag: [str, None] = None) -> Artifact:
    toolchain_paths = {
        BINUTILS_PATH: haskell_toolchain.ghci_binutils_path,
        GHCI_LIB_PATH: _get_default_output(haskell_toolchain.ghci_lib_path),
        CC_PATH: haskell_toolchain.ghci_cc_path,
        CPP_PATH: haskell_toolchain.ghci_cpp_path,
        CXX_PATH: haskell_toolchain.ghci_cxx_path,
        GHCI_PACKAGER: _get_default_output(haskell_toolchain.ghci_packager),
        GHCI_GHC_PATH: _get_default_output(haskell_toolchain.ghci_ghc_path),
    }

    if ghci_bin != None:
        toolchain_paths[USER_GHCI_PATH] = ghci_bin.short_path

    final_script = ctx.actions.declare_output(
        script_template.basename if not output_name else output_name,
    )
    script_template_processor = haskell_toolchain.script_template_processor[RunInfo]

    replace_args = cmd_args()
    replace_args.add(cmd_args(script_template, format = "--script_template={}"))
    for name, path in toolchain_paths.items():
        if path:
            replace_args.add(cmd_args(path, format = "--{}={{}}".format(name)))

    replace_args.add(cmd_args(
        final_script.as_output(),
        format = "--output={}",
    ))

    replace_args.add(cmd_args(
        ctx.label.name,
        format = "--target_name={}",
    ))

    exposed_package_args = exposed_package_args if exposed_package_args != None else ""
    replace_args.add(cmd_args(
        cmd_args(exposed_package_args, delimiter = " "),
        format = "--exposed_packages={}",
    ))

    if packagedb_args != None:
        replace_args.add(cmd_args(
            packagedb_args,
            format = "--package_dbs={}",
        ))
    if prebuilt_packagedb_args != None:
        replace_args.add(cmd_args(
            prebuilt_packagedb_args,
            format = "--prebuilt_package_dbs={}",
        ))

    # Tuple containing orig value (for null check), macro value and flag name
    optional_flags = [
        (
            start_ghci,
            start_ghci.short_path if start_ghci != None else "",
            "--start_ghci",
        ),
        (iserv_script, "iserv", "--iserv_path"),
        (
            squashed_so,
            squashed_so.short_path if squashed_so != None else "",
            "--squashed_so",
        ),
        (compiler_flags, compiler_flags, "--compiler_flags"),
        (srcs, srcs, "--srcs"),
        (ghci_iserv_path, ghci_iserv_path, "--ghci_iserv_path"),
        (preload_libs, preload_libs, "--preload_libs"),
        (dep_srcs_flag, dep_srcs_flag, "--dep_srcs_flag"),
    ]

    for (orig_val, macro_value, flag) in optional_flags:
        if orig_val != None:
            replace_args.add(cmd_args(
                macro_value,
                format = flag + "={}",
            ))

    replace_cmd = cmd_args(script_template_processor)
    replace_cmd.add(at_argfile(
        actions = ctx.actions,
        name = "ghci_script_args_{}".format(
            output_name if output_name else script_template.basename,
        ),
        args = replace_args,
        allow_args = True,
    ))

    ctx.actions.run(
        replace_cmd,
        category = "replace_template_{}".format(
            script_template.basename.replace("-", "_"),
        ),
        local_only = True,
    )

    return final_script

def _write_iserv_script(
        ctx: AnalysisContext,
        preload_deps_info: GHCiPreloadDepsInfo,
        haskell_toolchain: HaskellToolchainInfo,
        enable_profiling: bool) -> Artifact:
    ghci_iserv_template = haskell_toolchain.ghci_iserv_template

    if (not ghci_iserv_template):
        fail("ghci_iserv_template missing in haskell_toolchain")

    preload_libs = ":".join(
        [paths.join(
            "${DIR}",
            preload_deps_info.preload_deps_root.short_path,
            so,
        ) for so in sorted(preload_deps_info.preload_symlinks)],
    )

    if enable_profiling:
        ghci_iserv_path = haskell_toolchain.ghci_iserv_prof_path
    else:
        ghci_iserv_path = haskell_toolchain.ghci_iserv_path

    iserv_script_name = "iserv"
    if enable_profiling:
        iserv_script_name += "-prof"

    iserv_script = _replace_macros_in_script_template(
        ctx,
        script_template = ghci_iserv_template,
        output_name = iserv_script_name,
        haskell_toolchain = haskell_toolchain,
        ghci_iserv_path = _get_default_output(ghci_iserv_path),
        preload_libs = preload_libs,
    )
    return iserv_script

def _build_preload_deps_root(
        ctx: AnalysisContext,
        haskell_toolchain: HaskellToolchainInfo) -> GHCiPreloadDepsInfo:
    preload_deps = ctx.attrs.preload_deps

    preload_symlinks = {}
    preload_libs_root = ctx.label.name + ".preload-symlinks"

    for preload_dep in preload_deps:
        if SharedLibraryInfo in preload_dep:
            slib_info = preload_dep[SharedLibraryInfo]

            shlib = traverse_shared_library_info(slib_info)

            for soname, shared_lib in with_unique_str_sonames(shlib).items():
                preload_symlinks[soname] = shared_lib.lib.output

        # TODO(T150785851): build or get SO for direct preload_deps
        # TODO(T150785851): find out why the only SOs missing are the ones from
        # the preload_deps themselves, even though the ones from their deps are
        # already there.
        if LinkableRootInfo in preload_dep:
            linkable_root_info = preload_dep[LinkableRootInfo]
            preload_so_name = linkable_root_info.name

            linkables = map(lambda x: x.objects, linkable_root_info.link_infos.default.linkables)

            object_file = flatten(linkables)[0]

            preload_so = ctx.actions.declare_output(preload_so_name)
            link = cmd_args(haskell_toolchain.linker)
            link.add(haskell_toolchain.linker_flags)
            link.add(ctx.attrs.linker_flags)
            link.add("-o", preload_so.as_output())

            link.add(
                "-shared",
                "-dynamic",
                "-optl",
                "-Wl,-soname",
                "-optl",
                "-Wl," + preload_so_name,
            )
            link.add(object_file)

            ctx.actions.run(
                link,
                category = "haskell_ghci_link",
                identifier = preload_so_name,
            )

            preload_symlinks[preload_so_name] = preload_so

    preload_deps_root = ctx.actions.symlinked_dir(preload_libs_root, preload_symlinks)
    return GHCiPreloadDepsInfo(
        preload_deps_root = preload_deps_root,
        preload_symlinks = preload_symlinks,
    )

# Symlink the ghci binary that will be used, e.g. the internal fork in Haxlsh
def _symlink_ghci_binary(ctx, ghci_bin: Artifact, haskell_toolchain: HaskellToolchainInfo):
    ghci_bin_dep = ctx.attrs.ghci_bin_dep
    if ghci_bin_dep:
        src = ghci_bin_dep[DefaultInfo].default_outputs[0]
    elif haskell_toolchain.ghci_ghc_path:
        src = _get_default_output(haskell_toolchain.ghci_ghc_path)
    else:
        fail("GHC binary path not specified: set ghci_bin_dep on the target or ghci_ghc_path in the toolchain")

    ctx.actions.symlink_file(ghci_bin.as_output(), src)

def _first_order_haskell_deps(
        ctx: AnalysisContext,
        enable_profiling: bool) -> list[HaskellLibraryInfo]:
    libs = []
    for dep in attr_deps(ctx):
        if HaskellLibraryProvider in dep:
            if enable_profiling:
                libs.append(dep[HaskellLibraryProvider].prof_lib.values())
            else:
                libs.append(dep[HaskellLibraryProvider].lib.values())

    return dedupe(flatten(libs))

# Creates the start.ghci script used to load the packages during startup
def _write_start_ghci(
        ctx: AnalysisContext,
        script_file: Artifact,
        enable_profiling: bool):
    start_cmd = cmd_args()

    # Reason for unsetting `LD_PRELOAD` env var obtained from D6255224:
    # "Certain libraries (like allocators) cannot be loaded after the process
    # has started. When needing to use these libraries, send them to a
    # user-supplied script for handling them appropriately. Running the real
    # iserv with these libraries under LD_PRELOAD accomplishes this.
    # To ensure the LD_PRELOAD env doesn't make it to subsequently forked
    # processes, the very first action of start.ghci is to unset the variable."
    start_cmd.add("System.Environment.unsetEnv \"LD_PRELOAD\"")

    set_cmd = cmd_args(":set", delimiter = " ")
    first_order_deps = list(map(
        lambda dep: dep.name + "-" + dep.version,
        _first_order_haskell_deps(ctx, enable_profiling),
    ))
    deduped_deps = {pkg: 1 for pkg in first_order_deps}.keys()
    package_list = cmd_args(
        deduped_deps,
        format = "-package {}",
        delimiter = " ",
    )
    set_cmd.add(package_list)
    set_cmd.add("\n")
    start_cmd.add(set_cmd)

    header_ghci = ctx.actions.declare_output("header.ghci")

    ctx.actions.write(header_ghci.as_output(), start_cmd)

    if ctx.attrs.ghci_init:
        append_ghci_init = cmd_args()
        append_ghci_init.add(
            ["sh", "-c", 'cat "$1" "$2" > "$3"', "--", header_ghci, ctx.attrs.ghci_init, script_file.as_output()],
        )
        ctx.actions.run(append_ghci_init, category = "append_ghci_init")
    else:
        ctx.actions.copy_file(script_file, header_ghci)

def _ghci_resolve_toolchain_pkgs_impl(
        actions: AnalysisActions,
        pkg_deps: ResolvedDynamicValue,
        output: OutputArtifact,
        arg) -> list[Provider]:
    toolchain_package_db = pkg_deps.providers[DynamicHaskellToolchainPackageDbInfo].toolchain_packages

    toolchain_package_db_tset = actions.tset(
        HaskellToolchainPackageDbTSet,
        children = [toolchain_package_db[name] for name in arg.toolchain_libs if name in toolchain_package_db],
    )

    pkg_db_args = cmd_args(
        toolchain_package_db_tset.project_as_args("toolchain_package_db"),
        format = "-package-db {}",
    )
    actions.write(output, pkg_db_args, with_inputs = True)
    return []

_ghci_resolve_toolchain_pkgs = dynamic_actions(
    impl = _ghci_resolve_toolchain_pkgs_impl,
    attrs = {
        "pkg_deps": dynattrs.dynamic_value(),
        "output": dynattrs.output(),
        "arg": dynattrs.value(typing.Any),
    },
)

# Forces all toolchain package-db artifacts to be materialized on disk by
# creating a symlinked directory that points to each package's out.link dir.
# This is needed for haskell_ghci_global where no Haskell compilation step runs
# (so the packages would otherwise never be built/downloaded locally).
def _ghci_force_toolchain_pkgs_impl(
        actions: AnalysisActions,
        pkg_deps: ResolvedDynamicValue,
        pkgdbs_dir: OutputArtifact,
        arg) -> list[Provider]:
    toolchain_package_db = pkg_deps.providers[DynamicHaskellToolchainPackageDbInfo].toolchain_packages

    pkg_symlinks = {}
    for name in arg.toolchain_libs:
        if name in toolchain_package_db:
            pkg = toolchain_package_db[name].reduce("toolchain_root")
            if pkg != None:
                pkg_symlinks[name] = pkg.path

    actions.symlinked_dir(pkgdbs_dir, pkg_symlinks)
    return []

_ghci_force_toolchain_pkgs = dynamic_actions(
    impl = _ghci_force_toolchain_pkgs_impl,
    attrs = {
        "pkg_deps": dynattrs.dynamic_value(),
        "pkgdbs_dir": dynattrs.output(),
        "arg": dynattrs.value(typing.Any),
    },
)

def _write_ghci_src_package_conf_impl(
        actions: AnalysisActions,
        md_file: ArtifactValue,
        pkg_conf: OutputArtifact,
        db: OutputArtifact,
        arg) -> list[Provider]:
    md = md_file.read_json()
    modules = [m for m in md["module_graph"].keys() if not m.endswith("-boot")]

    # ${pkgroot} expands to the parent of the .conf.d db dir. In the symlink
    # tree under name.packages/<pkgname>/, mod-<suffix>/ and lib-<suffix>/ are
    # siblings of packagedb/, so ${pkgroot} resolves correctly to that dir.
    interface_dir = '"${pkgroot}/mod-' + arg.artifact_suffix + '"'
    library_dir = '"${pkgroot}/lib-' + arg.artifact_suffix + '"'

    dep_ids = [lib.id for lib in arg.hlis]

    conf = cmd_args(
        "name: " + arg.pkgname,
        "version: 1.0.0",
        "id: " + arg.pkgname,
        "key: " + arg.pkgname,
        "exposed: True",
        "exposed-modules: " + ", ".join(modules),
        "import-dirs: " + interface_dir,
        "library-dirs: " + library_dir,
        "hs-libraries: " + arg.libname,
    )
    if dep_ids:
        conf.add("depends: " + ", ".join(dep_ids))

    pkg_conf_art = actions.write(pkg_conf, conf, with_inputs = True)

    register_cmd = cmd_args(arg.registerer)
    register_cmd.add("--ghc-pkg", arg.packager)
    register_cmd.add("--output", db)
    register_cmd.add("--package-conf", pkg_conf_art)
    actions.run(
        register_cmd,
        category = "haskell_ghci_src_package",
        allow_cache_upload = arg.allow_cache_upload,
    )
    return []

_write_ghci_src_package_conf = dynamic_actions(
    impl = _write_ghci_src_package_conf_impl,
    attrs = {
        "md_file": dynattrs.artifact_value(),
        "pkg_conf": dynattrs.output(),
        "db": dynattrs.output(),
        "arg": dynattrs.value(typing.Any),
    },
)

def _ghci_link_src_lib_impl(
        actions: AnalysisActions,
        pkg_deps: ResolvedDynamicValue,
        lib: OutputArtifact,
        arg) -> list[Provider]:
    toolchain_package_db = pkg_deps.providers[DynamicHaskellToolchainPackageDbInfo].toolchain_packages

    all_pkg_names = arg.toolchain_libs + arg.transitive_dep_packages
    toolchain_db_tset = actions.tset(
        HaskellToolchainPackageDbTSet,
        children = [toolchain_package_db[n] for n in all_pkg_names if n in toolchain_package_db],
    )

    link_cmd = cmd_args(arg.haskell_toolchain.linker)
    link_cmd.add(arg.haskell_toolchain.linker_flags)
    link_cmd.add("-hide-all-packages")
    link_cmd.add(cmd_args(arg.local_packagedb_args, prepend = "-package-db"))
    link_cmd.add(cmd_args(
        toolchain_db_tset.project_as_args("toolchain_package_db"),
        prepend = "-package-db",
    ))
    link_cmd.add(arg.exposed_package_args)
    link_cmd.add("-shared", "-dynamic")
    link_cmd.add(cmd_args(arg.libfile, format = "-optl-Wl,-soname,{}"))
    link_cmd.add("-o", lib)
    link_cmd.add(arg.objects)
    link_cmd.add(arg.linker_flags)

    actions.run(
        link_cmd,
        category = "haskell_ghci_src_link",
        allow_cache_upload = arg.allow_cache_upload,
    )
    return []

_ghci_link_src_lib = dynamic_actions(
    impl = _ghci_link_src_lib_impl,
    attrs = {
        "pkg_deps": dynattrs.dynamic_value(),
        "lib": dynattrs.output(),
        "arg": dynattrs.value(typing.Any),
    },
)

def haskell_ghci_impl(ctx: AnalysisContext) -> list[Provider]:
    enable_profiling = ctx.attrs.enable_profiling

    # Validate plugin attrs (plugins not yet supported in ghci).
    # ghci plugin support is deferred since the ghci infrastructure is broken.

    start_ghci_file = ctx.actions.declare_output("start.ghci")
    _write_start_ghci(ctx, start_ghci_file, enable_profiling)

    haskell_toolchain = ctx.attrs._haskell_toolchain[HaskellToolchainInfo]

    ghci_bin = ctx.actions.declare_output(ctx.attrs.name + ".bin/ghci")
    _symlink_ghci_binary(ctx, ghci_bin, haskell_toolchain)
    preload_deps_info = _build_preload_deps_root(ctx, haskell_toolchain)

    ghci_script_template = haskell_toolchain.ghci_script_template

    if (not ghci_script_template):
        fail("ghci_script_template missing in haskell_toolchain")

    iserv_script = _write_iserv_script(
        ctx,
        preload_deps_info,
        haskell_toolchain,
        enable_profiling,
    )

    link_style = LinkStyle("shared")
    #link_style = LinkStyle("static_pic")

    haskell_direct_deps_lib_infos = attr_deps_haskell_lib_infos(
        ctx,
        link_style,
        enable_profiling,
        skip_missing_link_style = True,
    )

    packages_info = get_packages_info(
        actions = ctx.actions,
        deps = [],
        direct_deps_link_info = attr_deps_haskell_link_infos(ctx),
        haskell_toolchain = haskell_toolchain,
        haskell_direct_deps_lib_infos = haskell_direct_deps_lib_infos,
        link_style = link_style,
        specify_pkg_version = True,
        enable_profiling = enable_profiling,
        use_empty_lib = False,
        pkg_deps = None,
    )

    link_group_libs = attr_deps_haskell_link_group_infos(ctx, link_style)
    all_link_group_ids = [l.id for lg in link_group_libs for l in lg.libraries]

    toolchain_libs = packages_info.transitive_deps.reduce("packages")
    toolchain_pkg_args_file = ctx.actions.declare_output("toolchain_pkgdbs.args")
    if haskell_toolchain.packages:
        ctx.actions.dynamic_output_new(_ghci_resolve_toolchain_pkgs(
            pkg_deps = haskell_toolchain.packages.dynamic,
            output = toolchain_pkg_args_file.as_output(),
            arg = struct(toolchain_libs = toolchain_libs),
        ))
    else:
        ctx.actions.write(toolchain_pkg_args_file.as_output(), "")

    for lib in packages_info.transitive_deps.reduce("toolchain_packages"):
        packages_info.exposed_package_args.add("-package", lib.name)

    # Collect source file artifacts from non-Haskell deps (e.g. export_file
    # targets that provide .hs files across package boundaries). These are
    # added to a symlink tree and exposed to GHCi as an extra -i import path
    # so that GHCi can find and compile them interactively.
    dep_src_files = {}
    for dep in attr_deps(ctx):
        if HaskellLibraryProvider not in dep and DefaultInfo in dep:
            for out in dep[DefaultInfo].default_outputs:
                _, ext = paths.split_extension(out.short_path)
                if ext in [".hs", ".lhs", ".hsc", ".chs"]:
                    dep_src_files[out.short_path] = out

    dep_srcs_root = None
    dep_srcs_flag = None
    if dep_src_files:
        dep_srcs_root = ctx.actions.symlinked_dir(
            ctx.label.name + ".dep-srcs",
            dep_src_files,
        )
        dep_srcs_flag = '-i"${DIR}/' + dep_srcs_root.short_path + '"'

    # Compile target's own sources and register as a pre-compiled package so
    # that `buck2 build` produces cacheable artifacts and GHCi starts without
    # recompiling anything.
    src_compiled = None
    src_pkg_db = None
    src_pkg_lib = None
    src_pkgname = None

    if ctx.attrs.srcs:
        validate_plugins_attrs(ctx)
        worker = ctx.attrs._worker[WorkerInfo] if ctx.attrs._worker else None
        compile_link_style = LinkStyle("shared")

        # Mirrors haskell_library_impl's plugin-flag plumbing so that the
        # `plugins` / `srcs_plugins` attrs apply when haskell_ghci's own srcs
        # are pre-compiled as a package.
        plugin_flags = compute_plugin_flags(ctx, compile_link_style)
        plugin_tool_paths = []
        for plugin_dep in ctx.attrs.plugins:
            for tool in plugin_dep[GhcPluginInfo].tools:
                plugin_tool_paths.append(tool[RunInfo])
        for plugin_list in ctx.attrs.srcs_plugins.values():
            for plugin_dep in plugin_list:
                for tool in plugin_dep[GhcPluginInfo].tools:
                    plugin_tool_paths.append(tool[RunInfo])

        src_md_file = target_metadata(
            ctx,
            link_style = compile_link_style,
            enable_profiling = enable_profiling,
            enable_haddock = False,
            main = None,
            sources = ctx.attrs.srcs,
            worker = worker,
        )

        (src_pkgname, src_libname) = make_haskell_names_from_label(ctx.label, False)

        src_compiled = compile(
            ctx,
            compile_link_style,
            incremental = ctx.attrs.incremental,
            enable_profiling = enable_profiling,
            enable_haddock = False,
            md_file = src_md_file,
            worker = worker,
            pkgname = src_pkgname,
            is_haskell_binary = False,
            unit_plugin_flags = plugin_flags.unit,
            srcs_plugin_flags = plugin_flags.srcs,
            extra_tool_paths = plugin_tool_paths,
        )

        src_artifact_suffix = get_artifact_suffix(compile_link_style, enable_profiling)
        compiler_suffix = (
            "-ghc{}".format(haskell_toolchain.compiler_major_version)
            if haskell_toolchain.compiler_major_version
            else ""
        )
        src_libfile = "lib" + src_libname + compiler_suffix + ".so"
        src_pkg_lib = ctx.actions.declare_output(
            "lib-{}/{}".format(src_artifact_suffix, src_libfile),
        )

        dyn_objects = [o for o in src_compiled.objects if o.short_path.endswith(".dyn_o")]

        toolchain_libs_for_src = [
            dep[HaskellToolchainLibrary].name
            for dep in attr_deps(ctx)
            if HaskellToolchainLibrary in dep
        ]
        transitive_dep_packages = packages_info.transitive_deps.reduce("packages")

        if haskell_toolchain.packages:
            ctx.actions.dynamic_output_new(_ghci_link_src_lib(
                pkg_deps = haskell_toolchain.packages.dynamic,
                lib = src_pkg_lib.as_output(),
                arg = struct(
                    haskell_toolchain = haskell_toolchain,
                    local_packagedb_args = packages_info.local_packagedb_args,
                    exposed_package_args = packages_info.exposed_package_args,
                    objects = dyn_objects,
                    libfile = src_libfile,
                    linker_flags = ctx.attrs.linker_flags,
                    toolchain_libs = toolchain_libs_for_src,
                    transitive_dep_packages = transitive_dep_packages,
                    allow_cache_upload = ctx.attrs.allow_cache_upload,
                ),
            ))
        else:
            link_cmd = cmd_args(haskell_toolchain.linker)
            link_cmd.add(haskell_toolchain.linker_flags)
            link_cmd.add("-hide-all-packages")
            link_cmd.add(cmd_args(packages_info.local_packagedb_args, prepend = "-package-db"))
            link_cmd.add(packages_info.exposed_package_args)
            link_cmd.add("-shared", "-dynamic")
            link_cmd.add(cmd_args(src_libfile, format = "-optl-Wl,-soname,{}"))
            link_cmd.add("-o", src_pkg_lib.as_output())
            link_cmd.add(dyn_objects)
            ctx.actions.run(link_cmd, category = "haskell_ghci_src_link_simple")

        src_pkg_conf = ctx.actions.declare_output(
            "ghci-pkg-{}.conf".format(src_artifact_suffix),
        )
        src_pkg_db = ctx.actions.declare_output(
            "ghci-pkg-{}.conf.d".format(src_artifact_suffix),
            dir = True,
        )
        ctx.actions.dynamic_output_new(_write_ghci_src_package_conf(
            md_file = src_md_file,
            pkg_conf = src_pkg_conf.as_output(),
            db = src_pkg_db.as_output(),
            arg = struct(
                pkgname = src_pkgname,
                libname = src_libname + compiler_suffix,
                artifact_suffix = src_artifact_suffix,
                hlis = haskell_direct_deps_lib_infos,
                registerer = ctx.attrs._ghc_pkg_registerer[RunInfo],
                packager = haskell_toolchain.packager,
                allow_cache_upload = ctx.attrs.allow_cache_upload,
            ),
        ))

    # Create package db symlinks
    package_symlinks = []

    package_symlinks_root = ctx.label.name + ".packages"

    packagedb_args = cmd_args(delimiter = " ")
    prebuilt_packagedb_args_set = {}

    for lib in packages_info.transitive_deps.traverse():
        if lib.is_prebuilt:
            prebuilt_packagedb_args_set[lib.db] = None
        else:
            lib_symlinks_root = paths.join(
                package_symlinks_root,
                lib.name,
            )
            pkg_db = lib.empty_db if lib.name in all_link_group_ids and lib.empty_db else lib.db
            lib_symlinks = {
                "packagedb": pkg_db,
            }

            for prof, import_dir in lib.interfaces.items():
                artifact_suffix = get_artifact_suffix(link_style, prof)
                for imp in import_dir:
                    lib_symlinks["mod-" + artifact_suffix + "/" + imp.short_path] = imp

            for o in lib.libs:
                lib_symlinks[o.short_path] = o

            symlinked_things = ctx.actions.symlinked_dir(
                lib_symlinks_root,
                lib_symlinks,
            )

            package_symlinks.append(symlinked_things)

            packagedb_args.add(
                paths.join(
                    lib_symlinks_root,
                    "packagedb",
                ),
            )
    prebuilt_packagedb_args = cmd_args(prebuilt_packagedb_args_set.keys(), delimiter = " ")

    for lg in link_group_libs:
        lg_symlinks_root = paths.join(
            package_symlinks_root,
            lg.pkgname,
        )
        lg_symlinks = {
            "packagedb": lg.db,
            lg.lib.short_path: lg.lib,
        }
        lg_symlinked = ctx.actions.symlinked_dir(
            lg_symlinks_root,
            lg_symlinks,
        )
        package_symlinks.append(lg_symlinked)
        packagedb_args.add(
            paths.join(
                lg_symlinks_root,
                "packagedb",
            ),
        )

    # Add the target's own pre-compiled package to the symlink tree so GHCi
    # can load it via -package without recompiling from source.
    # NOTE: do NOT mutate packages_info.exposed_package_args here — the link
    # action captured that cmd_args and must not see the current package in it
    # (you can't link against a package you're in the process of creating).
    # Instead build a separate cmd_args for GHCi script rendering.
    ghci_exposed_package_args = cmd_args(packages_info.exposed_package_args)
    if src_pkg_db and src_pkgname and src_compiled:
        src_artifact_suffix = get_artifact_suffix(link_style, enable_profiling)
        src_symlinks_root = paths.join(package_symlinks_root, src_pkgname)
        src_symlinks = {"packagedb": src_pkg_db}

        for iface in src_compiled.interfaces:
            src_symlinks["mod-{}/{}".format(src_artifact_suffix, iface.short_path)] = iface

        if src_pkg_lib:
            src_symlinks[src_pkg_lib.short_path] = src_pkg_lib

        src_symlinked = ctx.actions.symlinked_dir(src_symlinks_root, src_symlinks)
        package_symlinks.append(src_symlinked)
        packagedb_args.add(paths.join(src_symlinks_root, "packagedb"))
        ghci_exposed_package_args.add("-package", src_pkgname)

    script_templates = []
    for script_template in ctx.attrs.extra_script_templates:
        final_script = _replace_macros_in_script_template(
            ctx,
            script_template = script_template,
            haskell_toolchain = haskell_toolchain,
            ghci_bin = ghci_bin,
            exposed_package_args = ghci_exposed_package_args,
            packagedb_args = packagedb_args,
            prebuilt_packagedb_args = prebuilt_packagedb_args,
        )
        script_templates.append(final_script)

    omnibus_data = _build_haskell_omnibus_so(ctx)

    final_ghci_script = _write_final_ghci_script(
        ctx,
        omnibus_data,
        packages_info,
        packagedb_args,
        prebuilt_packagedb_args,
        iserv_script,
        start_ghci_file,
        ghci_bin,
        haskell_toolchain,
        ghci_script_template,
        enable_profiling,
        # When sources are pre-compiled as a package, don't pass them as raw
        # source files — modules are already loaded via -package.
        srcs_override = "" if src_compiled else None,
        ghci_exposed_package_args = ghci_exposed_package_args,
        dep_srcs_flag = dep_srcs_flag,
    )

    outputs = [
        start_ghci_file,
        ghci_bin,
        preload_deps_info.preload_deps_root,
        iserv_script,
        omnibus_data.omnibus,
        omnibus_data.so_symlinks_root,
        final_ghci_script,
        toolchain_pkg_args_file,
    ]
    outputs.extend(package_symlinks)
    outputs.extend(script_templates)
    if dep_srcs_root != None:
        outputs.append(dep_srcs_root)

    # As default output (e.g. used in `$(location )` buck macros), the rule
    # should output a directory containing symlinks to all scripts and resources
    # (e.g. shared objects, package configs)
    output_artifacts = {o.short_path: o for o in outputs}
    root_output_dir = ctx.actions.symlinked_dir(
        "__{}__".format(ctx.label.name),
        output_artifacts,
    )
    ghci_bin_dep = ctx.attrs.ghci_bin_dep.get(RunInfo) if ctx.attrs.ghci_bin_dep else None
    hidden_dep = [ghci_bin_dep] if ghci_bin_dep else []
    run = cmd_args(final_ghci_script, hidden=hidden_dep + outputs)

    # When sources are pre-compiled, expose Haskell providers so _ghci targets
    # can be used as deps by other _ghci targets, forming a parallel dep tree.
    haskell_providers = []
    if src_compiled and src_pkg_db and src_pkgname and src_pkg_lib:
        src_hlib_info = HaskellLibraryInfo(
            name = src_pkgname,
            db = src_pkg_db,
            empty_db = None,
            deps_db = None,
            conf = HaskellPackageConfInfo(final_conf = None, empty_conf = None, deps_conf = None),
            interfaces = {False: src_compiled.interfaces},
            objects = {False: src_compiled.objects},
            hie_files = {False: []},
            stub_dirs = [],
            id = src_pkgname,
            dynamic = None,
            libs = [src_pkg_lib],
            version = "1.0.0",
            is_prebuilt = False,
            profiling_enabled = False,
            dependencies = [],
            toolchain_dependencies = [],
            md_file = None,
        )
        hlink_tset = ctx.actions.tset(
            HaskellLibraryInfoTSet,
            value = src_hlib_info,
            children = [
                li.info[link_style]
                for li in attr_deps_haskell_link_infos(ctx)
                if link_style in li.info
            ],
        )
        haskell_providers = [
            HaskellLibraryProvider(
                lib = {link_style: src_hlib_info},
                prof_lib = {},
            ),
            HaskellLinkInfo(
                info = {link_style: hlink_tset},
                prof_info = {link_style: ctx.actions.tset(HaskellLibraryInfoTSet)},
                extra = {},
            ),
        ]

    return [
        DefaultInfo(default_outputs = [root_output_dir]),
        RunInfo(args = run),
    ] + haskell_providers

def _write_global_start_ghci(
        ctx: AnalysisContext,
        script_file: Artifact):
    start_cmd = cmd_args()
    start_cmd.add("System.Environment.unsetEnv \"LD_PRELOAD\"")

    header_ghci = ctx.actions.declare_output("header.ghci")
    ctx.actions.write(header_ghci.as_output(), start_cmd)

    if ctx.attrs.ghci_init:
        append_ghci_init = cmd_args()
        append_ghci_init.add(
            ["sh", "-c", 'cat "$1" "$2" > "$3"', "--", header_ghci, ctx.attrs.ghci_init, script_file.as_output()],
        )
        ctx.actions.run(append_ghci_init, category = "append_ghci_init")
    else:
        ctx.actions.copy_file(script_file, header_ghci)

def haskell_ghci_global_impl(ctx: AnalysisContext) -> list[Provider]:
    enable_profiling = ctx.attrs.enable_profiling
    haskell_toolchain = ctx.attrs._haskell_toolchain[HaskellToolchainInfo]

    ghci_script_template = haskell_toolchain.ghci_script_template
    if not ghci_script_template:
        fail("ghci_script_template missing in haskell_toolchain")

    start_ghci_file = ctx.actions.declare_output("start.ghci")
    _write_global_start_ghci(ctx, start_ghci_file)

    ghci_bin = ctx.actions.declare_output(ctx.attrs.name + ".bin/ghci")
    _symlink_ghci_binary(ctx, ghci_bin, haskell_toolchain)

    preload_deps_info = _build_preload_deps_root(ctx, haskell_toolchain)

    iserv_script = _write_iserv_script(
        ctx,
        preload_deps_info,
        haskell_toolchain,
        enable_profiling,
    )

    dep = ctx.attrs.dep
    link_style = LinkStyle("shared")

    # Collect all transitive source files and per-library compiler flags.
    # Each TSet node carries struct(srcs=[(path, artifact)], compiler_flags=[str]).
    # Compiler flags include CPP defines (e.g. -D__LOCAL_PACKAGE_ROOT__) needed for TH.

    # Exclude source files belonging to precompiled_deps packages from the source tree.
    # GHCi treats files in the -i search path as home modules, which take priority over
    # precompiled packages. By removing those sources, GHCi is forced to use the
    # precompiled .hi files instead of recompiling them interpreted.
    precompiled_src_paths = {}
    for precompiled_dep in ctx.attrs.precompiled_deps:
        if HaskellSourceInfo in precompiled_dep:
            for node in precompiled_dep[HaskellSourceInfo].srcs.traverse():
                for (module_path, _) in node.srcs:
                    precompiled_src_paths[module_path] = None

    src_symlinks = {}
    lib_compiler_flags_seen = {}
    lib_compiler_flags = []
    for node in dep[HaskellSourceInfo].srcs.traverse():
        for (module_path, artifact) in node.srcs:
            if module_path not in precompiled_src_paths:
                src_symlinks[module_path] = artifact  # last-write-wins on conflict
        for flag in node.compiler_flags:
            if flag not in lib_compiler_flags_seen:
                lib_compiler_flags_seen[flag] = None
                lib_compiler_flags.append(flag)

    src_tree = ctx.actions.symlinked_dir(ctx.label.name + ".all-srcs", src_symlinks)
    dep_srcs_flag = '-i"${DIR}/' + src_tree.short_path + '"'

    # Build omnibus SO from the dep's transitive C/C++ deps.
    omnibus_data = _build_haskell_omnibus_so(
        ctx,
        omnibus_roots = [dep] + list(ctx.attrs.preload_deps) + ctx.attrs.template_deps,
    )

    # Get transitive toolchain package info from dep's HaskellLibraryInfoTSet.
    # Toolchain packages (aeson, QuickCheck, etc.) are haskell_toolchain_library targets;
    # they don't appear in HaskellLinkInfo but are tracked in lib.dependencies and
    # lib.toolchain_dependencies on each HaskellLibraryInfo node.
    toolchain_libs = []
    toolchain_packages = []
    prebuilt_db_set = {}
    lib_tset = dep[HaskellLinkInfo].info.get(link_style)
    if lib_tset != None:
        toolchain_libs = lib_tset.reduce("packages")
        toolchain_packages = lib_tset.reduce("toolchain_packages")
        # Also collect any genuine prebuilt package dbs (is_prebuilt=True in HaskellLinkInfo).
        for lib in lib_tset.traverse():
            if lib.is_prebuilt:
                prebuilt_db_set[lib.db] = None

    # Load first-party packages from precompiled_deps as precompiled units.
    # For each dep, traverse its HaskellLinkInfo to collect the full transitive closure.
    # Each package gets a symlink tree (packagedb/, mod-*/, lib-*/) that GHCi uses to
    # load precompiled .hi interfaces and .so libraries instead of interpreting source.
    # The source tree is kept so users can still :l individual files to override a module.
    precompiled_pkg_names = []
    first_party_package_symlinks = []
    first_party_package_symlinks_root = ctx.label.name + ".packages"
    first_party_packagedb_args = cmd_args(delimiter = " ")
    seen_precompiled = {}
    # Extra toolchain package names referenced by precompiled_deps' transitive closures
    # but absent from the main dep's closure (e.g. test-only libs not depended on by the
    # primary `dep`). These need to be in toolchain_pkgdbs.args so GHCi can satisfy their
    # precompiled deps.
    extra_toolchain_lib_names = {}
    toolchain_lib_name_set = {pkg.name: None for pkg in toolchain_packages}
    for precompiled_dep in ctx.attrs.precompiled_deps:
        dep_lib_tset = precompiled_dep[HaskellLinkInfo].info.get(link_style)
        if dep_lib_tset == None:
            continue
        for lib in dep_lib_tset.traverse():
            if lib.is_prebuilt:
                if lib.name not in toolchain_lib_name_set:
                    extra_toolchain_lib_names[lib.name] = None
                continue
            # Collect toolchain deps of this first-party node that aren't in the main
            # dep's closure. This catches toolchain packages that are only transitively
            # reachable via precompiled_deps entries absent from the main dep's tset
            # (e.g. a test-only library not in the primary `dep`'s closure).
            for tc_dep in lib.toolchain_dependencies:
                if tc_dep.name not in toolchain_lib_name_set:
                    extra_toolchain_lib_names[tc_dep.name] = None
            if lib.name in seen_precompiled:
                continue
            seen_precompiled[lib.name] = None
            lib_symlinks_root = paths.join(first_party_package_symlinks_root, lib.name)
            lib_symlinks = {"packagedb": lib.db}
            for prof, import_dirs in lib.interfaces.items():
                artifact_suffix = get_artifact_suffix(link_style, prof)
                for imp in import_dirs:
                    lib_symlinks["mod-" + artifact_suffix + "/" + imp.short_path] = imp
            for o in lib.libs:
                lib_symlinks[o.short_path] = o
            symlinked = ctx.actions.symlinked_dir(lib_symlinks_root, lib_symlinks)
            first_party_package_symlinks.append(symlinked)
            first_party_packagedb_args.add(paths.join(lib_symlinks_root, "packagedb"))
            precompiled_pkg_names.append(lib.name)

    # Resolve Nix package-db paths for all toolchain packages via dynamic action.
    # The output file contains "-package-db <nix-path>" lines; the ghci_script.tpl
    # reads it via @${DIR}/toolchain_pkgdbs.args so GHCi can find toolchain packages.
    toolchain_pkg_args_file = ctx.actions.declare_output("toolchain_pkgdbs.args")
    # Symlinked dir of toolchain package out.link dirs — forces Buck2 to materialize
    # each package-db on disk before GHCi runs (the write-args-file action is cacheable
    # and doesn't guarantee materialization when its result is served from cache).
    toolchain_pkgdbs_forced = None
    if haskell_toolchain.packages:
        # Use the "toolchain_packages" reduction (HaskellToolchainLibrary objects) as
        # the authoritative source for all_toolchain_libs.  The "packages" string
        # reduction is a superset that also includes first-party names, which are
        # silently skipped by the dynamic action, but empirically it can miss some
        # toolchain packages (e.g. leaf packages with no nix reverse-dependencies).
        # The "toolchain_packages" reduction directly tracks toolchain deps via
        # lib.toolchain_dependencies on every first-party node, so it is more reliable.
        all_toolchain_libs = [pkg.name for pkg in toolchain_packages] + list(extra_toolchain_lib_names.keys())
        ctx.actions.dynamic_output_new(_ghci_resolve_toolchain_pkgs(
            pkg_deps = haskell_toolchain.packages.dynamic,
            output = toolchain_pkg_args_file.as_output(),
            arg = struct(toolchain_libs = all_toolchain_libs),
        ))
        toolchain_pkgdbs_forced = ctx.actions.declare_output(ctx.label.name + ".pkgdbs")
        ctx.actions.dynamic_output_new(_ghci_force_toolchain_pkgs(
            pkg_deps = haskell_toolchain.packages.dynamic,
            pkgdbs_dir = toolchain_pkgdbs_forced.as_output(),
            arg = struct(toolchain_libs = all_toolchain_libs),
        ))
    else:
        ctx.actions.write(toolchain_pkg_args_file.as_output(), "")

    # Top-level target's direct toolchain deps. Used by compute_exposed_packages
    # as a tiebreaker for genuine module-name conflicts (two packages that both
    # OWN the same module, with no re-export relation between them — e.g.
    # base64 and base64-bytestring). Mirrors what a regular per-component
    # buck2 build does for `dep`'s own sources: if `dep` directly depends on
    # base64-bytestring (and not base64), then for `dep`'s `import
    # Data.ByteString.Base64` the canonical resolution is base64-bytestring.
    # Re-export-only conflicts (amazonka/amazonka-core, singletons/
    # singletons-th, etc.) don't reach this tiebreaker — they're resolved
    # purely from .conf data by preferring the owning package.
    top_level_toolchain_deps = []
    dep_provider = dep.get(HaskellLibraryProvider)
    if dep_provider != None and dep_provider.lib != None:
        dep_lib_info = dep_provider.lib.get(link_style)
        if dep_lib_info != None:
            top_level_toolchain_deps = [tc.name for tc in dep_lib_info.toolchain_dependencies]

    # Build exposed-package flags. Package specs with parens can't be inlined
    # into a bash exec line (bash treats '(' as special syntax), so we write
    # them to an args file and reference it with '@' from the wrapper script.
    #
    # compute_exposed_packages reads .conf files to determine which modules
    # each package exposes (distinguishing owned vs re-exported), resolves
    # conflicts using top_level_toolchain_deps as a tiebreaker, and falls
    # back to manual thin_packages pairs only for cases where neither owner
    # is a direct top-level dep.
    exposed_packages_args_file = ctx.actions.declare_output("exposed_packages.args")
    all_exposed_pkg_names = [pkg.name for pkg in toolchain_packages] + precompiled_pkg_names
    if haskell_toolchain.packages and toolchain_pkgdbs_forced != None:
        cep_args = cmd_args(
            cmd_args(toolchain_pkgdbs_forced, format = "--pkgdbs-forced={}"),
            cmd_args(json.encode(all_exposed_pkg_names), format = "--exposed-packages={}"),
            cmd_args(json.encode(top_level_toolchain_deps), format = "--top-level-toolchain-deps={}"),
            cmd_args(json.encode(ctx.attrs.thin_packages), format = "--thin-pairs={}"),
            cmd_args(exposed_packages_args_file.as_output(), format = "--output={}"),
        )
        ctx.actions.run(
            cmd_args(
                ctx.attrs._compute_exposed_packages[RunInfo],
                at_argfile(
                    actions = ctx.actions,
                    name = "compute_exposed_packages.args",
                    args = cep_args,
                    allow_args = True,
                ),
            ),
            category = "compute_exposed_packages",
            local_only = True,
        )
    else:
        lines = []
        for name in all_exposed_pkg_names:
            lines.extend(["-package", name])
        ctx.actions.write(exposed_packages_args_file, "\n".join(lines))

    prebuilt_packagedb_args = cmd_args(prebuilt_db_set.keys(), delimiter = " ") if prebuilt_db_set else None

    compiler_flags = cmd_args(delimiter = " ")
    # Hide all packages by default so only explicitly exposed ones are visible.
    # This prevents ambiguous module errors when multiple packages (e.g. cryptohash,
    # crypton, cryptonite) export the same module name.
    # -package-env=- disables the user's Nix/ghc package env to avoid extra conflicts.
    compiler_flags.add(["-hide-all-packages", "-package-env=-"])
    # Suppress all warnings in the global interpreted REPL — they are noisy (especially
    # custom lint plugins that fire on every module) and not actionable in a REPL session.
    # Users who want warnings can pass -Wall via ctx.attrs.compiler_flags.
    compiler_flags.add("-w")
    if enable_profiling:
        compiler_flags.add(["-prof", "-osuf p_o", "-hisuf p_hi"])
    compiler_flags.add(lib_compiler_flags)
    compiler_flags.add(ctx.attrs.compiler_flags)

    # When a bash wrapper is requested, the inner ghci script gets a .ghci suffix
    # so the wrapper can claim the plain ctx.label.name as the run entrypoint.
    inner_script_name = ctx.label.name + ".ghci" if ctx.attrs.bash else ctx.label.name

    final_ghci_script = _replace_macros_in_script_template(
        ctx,
        script_template = ghci_script_template,
        haskell_toolchain = haskell_toolchain,
        ghci_bin = ghci_bin,
        exposed_package_args = None,  # global rule uses exposed_packages.args file instead
        packagedb_args = first_party_packagedb_args if precompiled_pkg_names else None,
        prebuilt_packagedb_args = prebuilt_packagedb_args,
        start_ghci = start_ghci_file,
        iserv_script = iserv_script,
        squashed_so = omnibus_data.omnibus,
        compiler_flags = compiler_flags,
        srcs = "",
        dep_srcs_flag = dep_srcs_flag,
        output_name = inner_script_name,
    )

    extra_scripts = []
    for script_template in ctx.attrs.extra_script_templates:
        extra_script = _replace_macros_in_script_template(
            ctx,
            script_template = script_template,
            haskell_toolchain = haskell_toolchain,
            ghci_bin = ghci_bin,
            prebuilt_packagedb_args = prebuilt_packagedb_args,
        )
        extra_scripts.append(extra_script)

    # Collect native C library SOs from native_deps and symlink them into a
    # "native_libs/" subdirectory so GHCi can load them at startup.
    # The shell wrapper script passes them as positional args (RTLD_GLOBAL).
    native_lib_symlinks = {}
    for native_dep in ctx.attrs.native_deps:
        for out in native_dep[DefaultInfo].default_outputs:
            native_lib_symlinks[out.basename] = out
    native_libs_dir = ctx.actions.symlinked_dir(
        "native_libs",
        native_lib_symlinks,
    ) if native_lib_symlinks else None

    outputs = [
        start_ghci_file,
        ghci_bin,
        preload_deps_info.preload_deps_root,
        iserv_script,
        omnibus_data.omnibus,
        omnibus_data.so_symlinks_root,
        final_ghci_script,
        toolchain_pkg_args_file,
        src_tree,
        exposed_packages_args_file,
    ]
    outputs.extend(extra_scripts)
    outputs.extend(first_party_package_symlinks)
    if native_libs_dir != None:
        outputs.append(native_libs_dir)
    if toolchain_pkgdbs_forced != None:
        outputs.append(toolchain_pkgdbs_forced)

    # If a bash dep is provided, generate a thin POSIX sh wrapper that prepends
    # the Nix bash binary directory to PATH before exec-ing the real ghci script.
    # This ensures bash 4+ features in ghci_script.tpl work on macOS (which ships
    # bash 3.2) without requiring the user to have a newer bash on their PATH.
    if ctx.attrs.bash:
        bash_bin = ctx.attrs.bash[DefaultInfo].default_outputs[0]
        bash_bin_dir = ctx.actions.symlinked_dir(
            ctx.label.name + ".bash_bin",
            {"bash": bash_bin},
        )
        outputs.append(bash_bin_dir)

        wrapper = ctx.actions.declare_output(ctx.label.name)
        wrapper_content = cmd_args(
            "#!/bin/sh",
            'DIR=$(cd "$(dirname "$0")" && pwd)',
            cmd_args('export PATH="$DIR/', bash_bin_dir, ':$PATH"', delimiter = ""),
            cmd_args('exec "$DIR/', final_ghci_script, '" "$@"', delimiter = ""),
            relative_to = (wrapper, 1),
        )
        ctx.actions.write(wrapper, wrapper_content, is_executable = True)
        outputs.append(wrapper)
        run_script = wrapper
    else:
        run_script = final_ghci_script

    output_artifacts = {o.short_path: o for o in outputs}
    root_output_dir = ctx.actions.symlinked_dir(
        "__{}__".format(ctx.label.name),
        output_artifacts,
    )

    ghci_bin_dep = ctx.attrs.ghci_bin_dep.get(RunInfo) if ctx.attrs.ghci_bin_dep else None
    hidden_dep = [ghci_bin_dep] if ghci_bin_dep else []
    run = cmd_args(run_script, hidden = hidden_dep + outputs)

    return [
        DefaultInfo(default_outputs = [root_output_dir]),
        RunInfo(args = run),
    ]
