# Copyright (c) Meta Platforms, Inc. and affiliates.
#
# This source code is licensed under both the MIT license found in the
# LICENSE-MIT file in the root directory of this source tree and the Apache
# License, Version 2.0 found in the LICENSE-APACHE file in the root directory
# of this source tree.

# Implementation of the Haskell build rules.

load("@prelude//:paths.bzl", "paths")
load("@prelude//:resources.bzl", "ResourceInfo", "create_resource_db", "gather_resources")
load("@prelude//cxx:archive.bzl", "make_archive")
load("@prelude//cxx:cxx_context.bzl", "get_cxx_toolchain_info")
load(
    "@prelude//cxx:cxx_toolchain_types.bzl",
    "CxxToolchainInfo",
    "LinkerInfo",
    "LinkerType",
)
load("@prelude//cxx:linker.bzl", "LINKERS", "get_rpath_origin", "get_shared_library_flags")
load(
    "@prelude//linking:link_info.bzl",
    "ArchiveLinkable",
    "LibOutputStyle",
    "LinkArgs",
    "LinkInfo",
    "LinkInfos",
    "LinkStyle",
    "LinkedObject",
    "MergedLinkInfo",
    "SharedLibLinkable",
    "default_output_style_for_link_strategy",
    "get_lib_output_style",
    "get_link_args_for_strategy",
    "get_output_styles_for_linkage",
    "legacy_output_style_to_link_style",
    "map_to_link_infos",
    "to_link_strategy",
    "unpack_link_args",
)
load("@prelude//linking:types.bzl", "Linkage")
load(
    "@prelude//python:python.bzl",
    "PythonLibraryInfo",
)
load("@prelude//test:inject_test_run_info.bzl", "inject_test_run_info")
load("@prelude//tests:re_utils.bzl", "get_re_executors_from_props")
load("@prelude//utils:argfile.bzl", "at_argfile")
load("@prelude//utils:arglike.bzl", "ArgLike")
load(
    "@prelude//utils:utils.bzl",
    "dedupe_by_value",
    "flatten_dict",
)
load(
    ":compile.bzl",
    "CompileResultInfo",
    "compile",
    "get_extra_lib_info",
    "target_metadata",
    "target_skeleton",
)
load(
    ":ghc_plugin.bzl",
    "compute_plugin_flags",
    "validate_plugins_attrs",
)
load(
    ":haskell_haddock.bzl",
    "haskell_haddock_lib",
)
load(
    ":library_info.bzl",
    "ExtraLibraryInfo",
    "HaskellLibraryInfo",
    "HaskellLibraryInfoTSet",
    "HaskellLibraryProvider",
    "HaskellPackageConfInfo",
    "HaskellSourceInfo",
    "HaskellSourcesTSet",
    "get_libname",
    "merge_extra_lib_infos",
)
load(
    ":link_info.bzl",
    "ExtraGhcLinkerFlagsInfo",
    "GhcLinkableInfo",
    "HaskellLinkGroupInfo",
    "HaskellLinkGroupProvider",
    "HaskellLinkGroupTSet",
    "HaskellLinkGroupTSetProvider",
    "HaskellLinkInfo",
    "attr_link_style",
    "cxx_toolchain_link_style",
    "get_link_infos_from_extra_lib_info",
)
load(":pkg_conf.bzl", "append_pkg_conf_link_fields_for_link_infos")
load(":resources.bzl", "haskell_attr_resources")
load(
    ":toolchain.bzl",
    "DynamicHaskellToolchainLibraryInfo",
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
    "attr_deps_haskell_link_group_tsets",
    "attr_deps_haskell_link_infos",
    "attr_deps_haskell_link_infos_sans_template_deps",
    "attr_deps_haskell_toolchain_libraries",
    "attr_deps_merged_link_infos",
    "compute_source_module_paths",
    "get_artifact_suffix",
    "get_source_prefixes",
    "make_haskell_names_from_label",
    "md_module_mapping",
    "output_extensions",
    "src_to_module_name",
)

HaskellIndexingTSet = transitive_set()

# A list of hie dirs
HaskellIndexInfo = provider(
    fields = {
        "info": provider_field(typing.Any, default = None),  # dict[LinkStyle, HaskellIndexingTset]
    },
)

# This conversion is non-standard, see TODO about link style below
def _to_lib_output_style(link_style: LinkStyle) -> LibOutputStyle:
    return default_output_style_for_link_strategy(to_link_strategy(link_style))

def _attr_preferred_linkage(ctx: AnalysisContext) -> Linkage:
    preferred_linkage = ctx.attrs.preferred_linkage

    # force_static is deprecated, but it has precedence over preferred_linkage
    if getattr(ctx.attrs, "force_static", False):
        preferred_linkage = "static"

    return Linkage(preferred_linkage)

# --

def _toolchain_target_metadata_impl(
        actions: AnalysisActions,
        haskell_toolchain: HaskellToolchainInfo,
        output: OutputArtifact,
        libname: str,
        pkg_deps: ResolvedDynamicValue,
        md_gen: RunInfo) -> list[Provider]:
    toolchain_package_db = pkg_deps.providers[DynamicHaskellToolchainPackageDbInfo].toolchain_packages

    md_args = cmd_args(md_gen, "--ghc-pkg", haskell_toolchain.packager, "--package-name", libname, "--output", output)
    if libname in toolchain_package_db:
        pkg = toolchain_package_db[libname].reduce("toolchain_root")
        md_args.add("--package-dir", pkg.db)

    actions.run(
        md_args,
        category = "haskell_toolchain_library_metadata",
        identifier = libname,
        allow_cache_upload = True,
    )

    return []

_toolchain_target_metadata = dynamic_actions(
    impl = _toolchain_target_metadata_impl,
    attrs = {
        "haskell_toolchain": dynattrs.value(typing.Any),
        "output": dynattrs.output(),
        "libname": dynattrs.value(typing.Any),
        "pkg_deps": dynattrs.option(dynattrs.dynamic_value()),
        "md_gen": dynattrs.value(typing.Any),
    },
)

def _get_toolchain_haskell_package_id_impl(
        actions: AnalysisActions,
        md_file: ArtifactValue) -> list[Provider]:
    md = md_file.read_json()
    package_id = md["id"]
    return [DynamicHaskellToolchainLibraryInfo(id = package_id)]

_get_toolchain_haskell_package_id = dynamic_actions(
    impl = _get_toolchain_haskell_package_id_impl,
    attrs = {
        "md_file": dynattrs.artifact_value(),
    },
)

def haskell_toolchain_library_impl(ctx: AnalysisContext):
    md_file = ctx.actions.declare_output(ctx.label.name + ".md.json")
    haskell_toolchain = ctx.attrs._haskell_toolchain[HaskellToolchainInfo]
    pkg_deps = haskell_toolchain.packages.dynamic if haskell_toolchain.packages else None
    ctx.actions.dynamic_output_new(
        _toolchain_target_metadata(
            haskell_toolchain = haskell_toolchain,
            output = md_file.as_output(),
            libname = ctx.attrs.name,
            pkg_deps = pkg_deps,
            md_gen = ctx.attrs._generate_toolchain_lib_metadata[RunInfo],
        ),
    )
    dynamic = ctx.actions.dynamic_output_new(
        _get_toolchain_haskell_package_id(md_file = md_file),
    )
    sub_targets = {"metadata": [DefaultInfo(default_output = md_file)]}
    return [
        DefaultInfo(sub_targets = sub_targets),
        HaskellToolchainLibrary(
            name = ctx.attrs.name,
            dynamic = dynamic,
        ),
    ]

# --

def _get_haskell_prebuilt_libs(
        ctx: AnalysisContext,
        link_style: LinkStyle,
        enable_profiling: bool) -> list[Artifact]:
    if link_style == LinkStyle("shared"):
        if enable_profiling:
            # Profiling doesn't support shared libraries
            return []

        return ctx.attrs.shared_libs.values()
    elif link_style == LinkStyle("static"):
        if enable_profiling:
            return ctx.attrs.profiled_static_libs
        return ctx.attrs.static_libs
    elif link_style == LinkStyle("static_pic"):
        if enable_profiling:
            return ctx.attrs.pic_profiled_static_libs
        return ctx.attrs.pic_static_libs
    else:
        fail("Unexpected LinkStyle: " + link_style.value)

def haskell_prebuilt_library_impl(ctx: AnalysisContext) -> list[Provider]:
    haskell_infos = []
    for dep in attr_deps(ctx):
        used = False
        if HaskellLinkInfo in dep:
            used = True
            haskell_infos.append(dep[HaskellLinkInfo])
        if PythonLibraryInfo in dep:
            used = True
        if not used:
            fail("Unexpected link info encountered")

    hlibinfos = {}
    prof_hlibinfos = {}
    hlinkinfos = {}
    prof_hlinkinfos = {}

    for link_style in LinkStyle:
        libs = _get_haskell_prebuilt_libs(ctx, link_style, False)
        prof_libs = _get_haskell_prebuilt_libs(ctx, link_style, True)

        hlibinfo = HaskellLibraryInfo(
            name = ctx.attrs.name,
            db = ctx.attrs.db,
            empty_db = None,
            deps_db = None,
            conf = HaskellPackageConfInfo(final_conf = None, empty_conf = None, deps_conf = None),
            interfaces = {},
            objects = {},
            dependencies = [],
            toolchain_dependencies = [],
            hie_files = {},
            stub_dirs = [],
            id = ctx.attrs.id,
            dynamic = None,
            libs = libs,
            version = ctx.attrs.version,
            is_prebuilt = True,
            profiling_enabled = False,
            md_file = None,
        )
        prof_hlibinfo = HaskellLibraryInfo(
            name = ctx.attrs.name,
            db = ctx.attrs.db,
            empty_db = None,
            deps_db = None,
            conf = HaskellPackageConfInfo(final_conf = None, empty_conf = None, deps_conf = None),
            interfaces = {},
            objects = {},
            dependencies = [],
            toolchain_dependencies = [],
            hie_files = {},
            stub_dirs = [],
            id = ctx.attrs.id,
            dynamic = None,
            libs = prof_libs,
            version = ctx.attrs.version,
            is_prebuilt = True,
            profiling_enabled = True,
            md_file = None,
        )

        hlibinfos[link_style] = hlibinfo
        hlinkinfos[link_style] = ctx.actions.tset(
            HaskellLibraryInfoTSet,
            value = hlibinfo,
            children = [lib.info[link_style] for lib in haskell_infos],
        )
        prof_hlibinfos[link_style] = prof_hlibinfo
        prof_hlinkinfos[link_style] = ctx.actions.tset(
            HaskellLibraryInfoTSet,
            value = prof_hlibinfo,
            children = [lib.prof_info[link_style] for lib in haskell_infos],
        )

    haskell_link_infos = HaskellLinkInfo(
        info = hlinkinfos,
        prof_info = prof_hlinkinfos,
    )
    haskell_lib_provider = HaskellLibraryProvider(
        lib = hlibinfos,
        prof_lib = prof_hlibinfos,
    )

    return [
        DefaultInfo(),
        haskell_lib_provider,
        haskell_link_infos,
        ResourceInfo(resources = gather_resources(
            label = ctx.label,
            resources = haskell_attr_resources(ctx),
            deps = attr_deps(ctx),
        )),
    ]

def _register_package_conf(
        actions: AnalysisActions,
        pkg_conf: Artifact,
        db: OutputArtifact,
        registerer: RunInfo,
        packager: RunInfo,
        category_prefix: str,
        artifact_suffix: str,
        use_empty_lib: bool,
        allow_cache_upload: bool) -> None:
    register_cmd = cmd_args(registerer)
    register_cmd.add("--ghc-pkg", packager)
    register_cmd.add("--output", db)
    register_cmd.add("--package-conf", pkg_conf)

    actions.run(
        register_cmd,
        category = category_prefix + artifact_suffix.replace("-", "_"),
        identifier = "empty" if use_empty_lib else "final",
        # explicit turn this on for local_only actions to upload their results.
        allow_cache_upload = allow_cache_upload,
    )

def _mk_artifact_dir(dir_prefix: str, profiled: bool, link_style, subdir: str = "") -> str:
    suffix = get_artifact_suffix(link_style, profiled)
    if subdir:
        suffix = paths.join(suffix, subdir)
    return "\"${pkgroot}/" + dir_prefix + "-" + suffix + "\""

_WritePackageConfOptions = record(
    for_deps = bool,
    profiling = list[bool],
    link_style = LinkStyle,
    # NB: We only expect to need one `LinkInfo` here, but `map_to_link_infos`
    # returns a list, so it may be more convenient to use a list in the future.
    link_infos = list[LinkInfo],
    pkgname = str,
    hlis = list[HaskellLibraryInfo],
    use_empty_lib = bool,
    allow_cache_upload = bool,
    enable_profiling = bool,
    artifact_suffix = str,
    srcs = list[typing.Any],
    strip_prefix = list[str],
    haskell_toolchain = HaskellToolchainInfo,
    registerer = RunInfo,
    extra_libs = list[Artifact],
    purpose = str,
)

def _write_package_conf_impl(
        actions: AnalysisActions,
        md_file: ArtifactValue,
        toolchain_lib_dyn_infos: list[ResolvedDynamicValue],
        extra_lib_dyns: list[ResolvedDynamicValue],
        pkg_conf: OutputArtifact,
        db: OutputArtifact,
        libname: str | None,
        arg: _WritePackageConfOptions) -> list[Provider]:
    md = md_file.read_json()
    module_map = md_module_mapping(md)

    source_prefixes = get_source_prefixes(arg.srcs, module_map)
    source_prefixes_excluded = [prefix for prefix in source_prefixes if prefix not in arg.strip_prefix]

    modules = [
        module
        for module in md["module_graph"].keys()
        if not module.endswith("-boot")
    ]

    # XXX use a single import dir when this package db is used for resolving dependencies with ghc -M,
    #     which works around an issue with multiple import dirs resulting in GHC trying to locate interface files
    #     for each exposed module
    if arg.for_deps:
        import_dirs = ["."]
    elif not source_prefixes_excluded:
        import_dirs = [
            _mk_artifact_dir("mod", profiled, arg.link_style)
            for profiled in arg.profiling
        ]
    else:
        import_dirs = [
            _mk_artifact_dir("mod", profiled, arg.link_style, src_prefix)
            for profiled in arg.profiling
            for src_prefix in source_prefixes_excluded
        ]

    toolchain_lib_ids = [info.providers[DynamicHaskellToolchainLibraryInfo].id for info in toolchain_lib_dyn_infos]

    conf = cmd_args(
        "name: " + arg.pkgname,
        "version: 1.0.0",
        "id: " + arg.pkgname,
        "key: " + arg.pkgname,
        "exposed: False",
        "exposed-modules: " + ", ".join(modules),
        "import-dirs:" + ", ".join(import_dirs),
    )

    def _select_db_conf(lib):
        if arg.purpose == "deps":
            return [lib.deps_db, lib.conf.deps_conf]
        elif arg.purpose == "empty":
            return [lib.empty_db, lib.conf.empty_conf]
        else:
            return [lib.db, lib.conf.final_conf]

    toolchain_deps_args = [cmd_args(id) for id in toolchain_lib_ids]
    project_deps_args = [cmd_args(lib.id, hidden = _select_db_conf(lib)) for lib in arg.hlis]
    depends = cmd_args(cmd_args(toolchain_deps_args + project_deps_args, delimiter = ", "), format = "depends: {}")
    conf.add(depends)

    if not arg.use_empty_lib:
        if not libname:
            fail("argument `libname` cannot be empty, when use_empty_lib == False")

        if arg.enable_profiling:
            # Add the `-p` suffix otherwise ghc will look for objects
            # following this logic (https://fburl.com/code/3gmobm5x) and will fail.
            libname += "_p"

        if arg.link_style == LinkStyle("shared"):
            library_dirs = [_mk_artifact_dir("lib", profiled, arg.link_style) for profiled in arg.profiling]
        else:
            library_dirs = [_mk_artifact_dir("lib", profiled, link_style) for profiled in arg.profiling for link_style in [arg.link_style, LinkStyle("shared")]]

        conf.add(cmd_args(cmd_args(library_dirs, delimiter = ","), format = "library-dirs: {}"))
        conf.add(cmd_args(libname, format = "hs-libraries: {}"))

    extra_ld_opts = cmd_args(hidden = arg.extra_libs)

    # Extra flags that can be dynamically resolved. For example, -rpath /nix/store/...
    for dyn in extra_lib_dyns:
        fs = dyn.providers[ExtraGhcLinkerFlagsInfo].flags
        extra_ld_opts.add(cmd_args(cmd_args(fs, delimiter = ","), format = "\"-Wl,{}\""))

    append_pkg_conf_link_fields_for_link_infos(
        pkgname = arg.pkgname,
        pkg_conf = conf,
        link_infos = arg.link_infos,
        extra_ld_opts = extra_ld_opts,
    )

    pkg_conf_artifact = actions.write(pkg_conf, conf, with_inputs = True)

    _register_package_conf(
        actions,
        pkg_conf_artifact,
        db,
        arg.registerer,
        arg.haskell_toolchain.packager,
        "haskell_package_",
        arg.artifact_suffix,
        arg.use_empty_lib,
        arg.allow_cache_upload,
    )

    return []

_write_package_conf = dynamic_actions(
    impl = _write_package_conf_impl,
    attrs = {
        "md_file": dynattrs.artifact_value(),
        "toolchain_lib_dyn_infos": dynattrs.list(dynattrs.dynamic_value()),
        "extra_lib_dyns": dynattrs.list(dynattrs.dynamic_value()),
        "pkg_conf": dynattrs.output(),
        "db": dynattrs.output(),
        "libname": dynattrs.value(typing.Any),
        "arg": dynattrs.value(typing.Any),
    },
)

# Create a package
#
# The way we use packages is a bit strange. We're not using them
# at link time at all: all the linking info is in the
# HaskellLibraryInfo and we construct linker command lines
# manually. Packages are used for:
#
#  - finding .hi files at compile time
#
#  - symbol namespacing (so that modules with the same name in
#    different libraries don't clash).
#
#  - controlling module visibility: only dependencies that are
#    directly declared as dependencies may be used
#
#  - by GHCi when loading packages into the repl
#
#  - when linking binaries statically, in order to pass libraries
#    to the linker in the correct order
def _make_package(
        ctx: AnalysisContext,
        link_style: LinkStyle,
        pkgname: str,
        libname: str | None,
        hlis: list[HaskellLibraryInfo],
        profiling: list[bool],
        enable_profiling: bool,
        use_empty_lib: bool,
        md_file: Artifact,
        extra_lib_info: ExtraLibraryInfo,
        for_deps: bool = False):
    artifact_suffix = get_artifact_suffix(link_style, enable_profiling)

    if for_deps:
        pkg_conf = ctx.actions.declare_output("pkg-" + artifact_suffix + "_deps.conf")
        db = ctx.actions.declare_output("db-" + artifact_suffix + "_deps", dir = True)
        purpose = "deps"
    elif use_empty_lib:
        pkg_conf = ctx.actions.declare_output("pkg-" + artifact_suffix + "_empty.conf")
        db = ctx.actions.declare_output("db-" + artifact_suffix + "_empty", dir = True)
        purpose = "empty"
    else:
        pkg_conf = ctx.actions.declare_output("pkg-" + artifact_suffix + ".conf")
        db = ctx.actions.declare_output("db-" + artifact_suffix, dir = True)
        purpose = "final"

    link_infos = get_link_infos_from_extra_lib_info(
        ctx.actions,
        ctx.label,
        get_cxx_toolchain_info(ctx).linker_info,
        link_style,
        extra_lib_info,
    )

    toolchain_libs = attr_deps_haskell_toolchain_libraries(ctx)
    toolchain_lib_dyn_infos = [dep.dynamic for dep in toolchain_libs]

    arg = _WritePackageConfOptions(
        for_deps = for_deps,
        profiling = profiling,
        link_style = link_style,
        link_infos = link_infos,
        pkgname = pkgname,
        hlis = hlis,
        use_empty_lib = use_empty_lib,
        allow_cache_upload = ctx.attrs.allow_cache_upload,
        enable_profiling = enable_profiling,
        artifact_suffix = artifact_suffix,
        srcs = ctx.attrs.srcs,
        strip_prefix = ctx.attrs.strip_prefix,
        haskell_toolchain = ctx.attrs._haskell_toolchain[HaskellToolchainInfo],
        registerer = ctx.attrs._ghc_pkg_registerer[RunInfo],
        extra_libs = extra_lib_info.extra_libs,
        purpose = purpose,
    )

    ctx.actions.dynamic_output_new(
        _write_package_conf(
            md_file = md_file,
            toolchain_lib_dyn_infos = toolchain_lib_dyn_infos,
            extra_lib_dyns = extra_lib_info.extra_lib_dyns,
            pkg_conf = pkg_conf.as_output(),
            db = db.as_output(),
            libname = libname,
            arg = arg,
        ),
    )

    return db, pkg_conf

HaskellLibBuildOutput = record(
    hlib = HaskellLibraryInfo,
    solibs = dict[str, LinkedObject],
    link_infos = LinkInfos,
    compiled = CompileResultInfo,
    libs = list[Artifact],
)

def _get_haskell_shared_library_name_linker_flags(
        linker_type: LinkerType,
        soname: str) -> list[str]:
    if linker_type == LinkerType("gnu"):
        return ["-Wl,-soname,{}".format(soname)]
    elif linker_type == LinkerType("darwin"):
        # Passing `-install_name @rpath/...` or
        # `-Xlinker -install_name -Xlinker @rpath/...` instead causes
        # ghc-9.6.3: panic! (the 'impossible' happened)
        return ["-Wl,-install_name,@rpath/{}".format(soname)]
    else:
        fail("Unknown linker type '{}'.".format(linker_type))

_DynamicLinkSharedOptions = record(
    artifact_suffix = str,
    haskell_toolchain = HaskellToolchainInfo,
    infos = LinkArgs,
    link_args = ArgLike,  # TODO: is this redundant with `infos`?
    haskell_direct_deps_lib_infos = list[HaskellLibraryInfo],
    direct_deps_info = list[HaskellLibraryInfoTSet],
    lib = Artifact,
    libfile = str,
    linker_flags = list[typing.Any],  # args
    linker_info = LinkerInfo,
    objects = list[Artifact],
    link_group_libs = list[HaskellLinkGroupInfo],
    toolchain_libs = list[str],
    project_libs = list[str],
    toolchain_libs_full = list[HaskellToolchainLibrary],
    project_libs_full = list[HaskellLibraryInfo],
    worker_target_id = str,
    allow_cache_upload = bool,
)

def _dynamic_link_shared_impl(
        actions: AnalysisActions,
        pkg_deps: ResolvedDynamicValue,
        extra_libs: list[Artifact],
        extra_lib_dyns: list[ResolvedDynamicValue],
        lib: OutputArtifact,
        arg: _DynamicLinkSharedOptions) -> list[Provider]:
    # link group
    all_link_group_ids = [l.id for lg in arg.link_group_libs for l in lg.libraries]

    toolchain_package_db = pkg_deps.providers[DynamicHaskellToolchainPackageDbInfo].toolchain_packages

    libs = actions.tset(HaskellLibraryInfoTSet, children = arg.direct_deps_info)
    all_deps = libs.reduce("packages")
    toolchain_package_db_tset = actions.tset(
        HaskellToolchainPackageDbTSet,
        children = [toolchain_package_db[name] for name in (arg.toolchain_libs + all_deps) if name in toolchain_package_db],
    )

    packagedb_args = cmd_args()
    link_args = cmd_args()
    link_cmd_hidden = []

    for d in list(libs.traverse()):
        if d.name in all_link_group_ids:
            packagedb_args.add(cmd_args(d.empty_db))
        else:
            packagedb_args.add(cmd_args(d.db))
            link_cmd_hidden.extend(d.libs)
    for lg in arg.link_group_libs:
        packagedb_args.add(cmd_args(lg.db))

    packagedb_args.add(toolchain_package_db_tset.project_as_args("toolchain_package_db"))

    link_args.add(arg.haskell_toolchain.linker_flags)
    link_args.add(arg.linker_flags)
    link_args.add("-hide-all-packages")
    link_args.add(cmd_args(packagedb_args, prepend = "-package-db"))

    link_args.add(cmd_args(arg.toolchain_libs, prepend = "-package"))

    for item in arg.haskell_direct_deps_lib_infos:
        if not item.id in all_link_group_ids:
            link_args.add(cmd_args(item.name, prepend = "-package"))

    link_args.add(cmd_args(toolchain_package_db_tset.project_as_args("toolchain_package_db"), prepend = "-package-db"))

    # extra libraries
    link_cmd_hidden.extend(extra_libs)

    # link group
    for lg in arg.link_group_libs:
        link_args.add("-package", lg.pkgname)
        link_cmd_hidden.append(lg.lib)

    link_args.add(
        get_shared_library_flags(arg.linker_info.type),
        "-dynamic",
        cmd_args(
            _get_haskell_shared_library_name_linker_flags(arg.linker_info.type, arg.libfile),
            prepend = "-optl",
        ),
        arg.objects,
        arg.link_args,
        "-o",
        lib,
    )

    # Extra flags that can be dynamically resolved. For example, -rpath /nix/store/...
    for dyn in extra_lib_dyns:
        fs = dyn.providers[ExtraGhcLinkerFlagsInfo].flags
        link_args.add(cmd_args(cmd_args(cmd_args(fs, delimiter = ","), format = "-Wl,{}"), prepend = "-optl"))

    link_cmd_hidden.append(unpack_link_args(arg.infos))

    link_cmd = cmd_args(
        arg.haskell_toolchain.linker,
        at_argfile(
            actions = actions,
            name = "haskell_link_" + arg.artifact_suffix.replace("-", "_") + ".argsfile",
            args = link_args,
            allow_args = True,
        ),
        hidden = link_cmd_hidden,
    )

    actions.run(
        link_cmd,
        category = "haskell_link_" + arg.artifact_suffix.replace("-", "_"),
        # explicit turn this on for local_only actions to upload their results.
        allow_cache_upload = arg.allow_cache_upload,
    )

    return []

_dynamic_link_shared = dynamic_actions(
    impl = _dynamic_link_shared_impl,
    attrs = {
        "arg": dynattrs.value(typing.Any),
        "lib": dynattrs.output(),
        "pkg_deps": dynattrs.dynamic_value(),
        "extra_libs": dynattrs.value(typing.Any),
        "extra_lib_dyns": dynattrs.list(dynattrs.dynamic_value()),
    },
)

def _build_haskell_lib(
        ctx: AnalysisContext,
        worker: WorkerInfo | None,
        allow_worker: bool,
        libname: str,
        pkgname: str,
        hlis: list[HaskellLinkInfo],  # haskell link infos from all deps
        nlis: list[MergedLinkInfo],  # native link infos from all deps
        link_style: LinkStyle,
        enable_profiling: bool,
        enable_haddock: bool,
        md_file: Artifact,
        skeleton: Artifact | None = None,
        # The non-profiling artifacts are also needed to build the package for
        # profiling, so it should be passed when `enable_profiling` is True.
        non_profiling_hlib: [HaskellLibBuildOutput, None] = None,
        unit_plugin_flags = None,
        srcs_plugin_flags = {},
        extra_tool_paths = [],
        srcs_plugin_tool_paths = {},
        plugin_toolchain_deps = []) -> HaskellLibBuildOutput:
    linker_info = ctx.attrs._cxx_toolchain[CxxToolchainInfo].linker_info

    # Link the objects into a library
    haskell_toolchain = ctx.attrs._haskell_toolchain[HaskellToolchainInfo]

    # Compile the sources
    #
    # TODO: This computes `link_args` from `ctx.attrs.extra_libraries` like we
    # do below, I think it may put in duplicate `link_args` at some point.
    compiled = compile(
        ctx,
        link_style,
        enable_profiling = enable_profiling,
        enable_haddock = enable_haddock,
        md_file = md_file,
        pkgname = pkgname,
        worker = worker,
        incremental = ctx.attrs.incremental,
        is_haskell_binary = False,
        src_main = None,
        unit_plugin_flags = unit_plugin_flags,
        srcs_plugin_flags = srcs_plugin_flags,
        extra_tool_paths = extra_tool_paths,
        srcs_plugin_tool_paths = srcs_plugin_tool_paths,
        plugin_toolchain_deps = plugin_toolchain_deps,
    )
    solibs = {}
    artifact_suffix = get_artifact_suffix(link_style, enable_profiling)

    libstem = libname

    dynamic_lib_suffix = "." + LINKERS[linker_info.type].default_shared_library_extension
    static_lib_suffix = "_p.a" if enable_profiling else ".a"
    if link_style == LinkStyle("shared"):
        compiler_suffix = "-ghc{}".format(haskell_toolchain.compiler_major_version)
    else:
        compiler_suffix = ""
    libfile = "lib" + libstem + compiler_suffix + (dynamic_lib_suffix if link_style == LinkStyle("shared") else static_lib_suffix)

    lib_short_path = paths.join("lib-{}".format(artifact_suffix), libfile)

    linfos = [x.prof_info if enable_profiling else x.info for x in hlis]

    # only gather direct dependencies
    uniq_infos = [x[link_style].value for x in linfos]

    toolchain_libs = [dep.name for dep in attr_deps_haskell_toolchain_libraries(ctx)]
    project_libs = [dep.name for dep in attr_deps_haskell_lib_infos(ctx, link_style, enable_profiling)]
    toolchain_libs_full = attr_deps_haskell_toolchain_libraries(ctx)
    project_libs_full = attr_deps_haskell_lib_infos(ctx, link_style, enable_profiling)

    # construct ExtraLibraryInfo struct from extra_libraries
    extra_lib_info = get_extra_lib_info(link_style, ctx.attrs.extra_libraries)
    extra_libs = extra_lib_info.extra_libs
    extra_lib_dyns = extra_lib_info.extra_lib_dyns

    link_args = unpack_link_args(get_link_args_for_strategy(
        ctx.actions,
        ctx.label,
        get_cxx_toolchain_info(ctx).linker_info,
        [
            lib[MergedLinkInfo]
            for lib in ctx.attrs.extra_libraries
        ],
        to_link_strategy(link_style),
        prefer_stripped = True,
        transformation_spec_context = None,
    ))

    if link_style == LinkStyle("shared"):
        lib = ctx.actions.declare_output(lib_short_path)
        objects = [
            object
            for object in compiled.objects
            if not object.extension.endswith("-boot")
        ]

        infos = get_link_args_for_strategy(
            ctx.actions,
            ctx.label,
            get_cxx_toolchain_info(ctx).linker_info,
            nlis,
            to_link_strategy(link_style),
            prefer_stripped = True,
            transformation_spec_context = None,
        )

        haskell_direct_deps_lib_infos = attr_deps_haskell_lib_infos(
            ctx,
            link_style,
            enable_profiling = enable_profiling,
        )
        direct_deps_info = [
            lib.prof_info[link_style] if enable_profiling else lib.info[link_style]
            for lib in attr_deps_haskell_link_infos(ctx)
        ]
        link_group_libs = attr_deps_haskell_link_group_infos(ctx, link_style)

        ctx.actions.dynamic_output_new(_dynamic_link_shared(
            pkg_deps = haskell_toolchain.packages.dynamic,
            extra_libs = extra_libs,
            extra_lib_dyns = extra_lib_dyns,
            lib = lib.as_output(),
            arg = _DynamicLinkSharedOptions(
                artifact_suffix = artifact_suffix,
                haskell_toolchain = haskell_toolchain,
                infos = infos,
                haskell_direct_deps_lib_infos = haskell_direct_deps_lib_infos,
                direct_deps_info = direct_deps_info,
                lib = lib,
                libfile = libfile,
                linker_flags = ctx.attrs.linker_flags,
                linker_info = linker_info,
                objects = objects,
                link_group_libs = link_group_libs,
                toolchain_libs = toolchain_libs,
                project_libs = project_libs,
                toolchain_libs_full = toolchain_libs_full,
                project_libs_full = project_libs_full,
                worker_target_id = pkgname,
                link_args = link_args,
                allow_cache_upload = ctx.attrs.allow_cache_upload,
            ),
        ))

        extra = []

        solibs[libfile] = LinkedObject(output = lib, unstripped_output = lib)
        libs = [lib]
        link_infos = LinkInfos(
            default = LinkInfo(linkables = [SharedLibLinkable(lib = lib)]),
        )

    else:  # static flavours
        # TODO: avoid making an archive for a single object, like cxx does
        # (but would that work with Template Haskell?)
        objs = [o for o in compiled.objects if o.extension != ".dyn_o"]

        if objs:
            hidden = compiled.interfaces + \
                     compiled.extra_interfaces + \
                     compiled.extra_interfaces + \
                     compiled.extra_objects + \
                     extra_libs
            archive = make_archive(ctx, lib_short_path, objs, hidden = hidden)
            lib = archive.artifact
            libs = [lib] + archive.external_objects
            linkables = [ArchiveLinkable(
                archive = archive,
                linker_type = linker_info.type,
                link_whole = ctx.attrs.link_whole,
            )]
        else:
            libs = []
            linkables = []

        link_infos = LinkInfos(
            default = LinkInfo(
                linkables = linkables,
            ),
        )
        extra = []

    if enable_profiling and link_style != LinkStyle("shared"):
        if not non_profiling_hlib:
            fail("Non-profiling HaskellLibBuildOutput wasn't provided when building profiling lib")

        dynamic = {
            True: compiled.module_tsets,
            False: non_profiling_hlib.compiled.module_tsets,
        }
        interface_artifacts = {
            True: compiled.interfaces,
            False: non_profiling_hlib.compiled.interfaces,
        }
        object_artifacts = {
            True: compiled.objects,
            False: non_profiling_hlib.compiled.objects,
        }
        hie_artifacts = {
            True: compiled.hie,
            False: non_profiling_hlib.compiled.hie,
        }
        all_libs = libs + non_profiling_hlib.libs
        stub_dirs = [compiled.stubs] + [non_profiling_hlib.compiled.stubs]
    else:
        dynamic = {
            False: compiled.module_tsets,
        }
        interface_artifacts = {
            False: compiled.interfaces,
        }
        object_artifacts = {
            False: compiled.objects,
        }
        hie_artifacts = {
            False: compiled.hie,
        }
        all_libs = libs
        stub_dirs = [compiled.stubs]

    db, final_conf = _make_package(
        ctx,
        link_style,
        pkgname,
        libstem,
        uniq_infos,
        interface_artifacts.keys(),
        enable_profiling = enable_profiling,
        use_empty_lib = False,
        md_file = md_file,
        extra_lib_info = extra_lib_info,
    )
    empty_db, empty_conf = _make_package(
        ctx,
        link_style,
        pkgname,
        None,
        uniq_infos,
        interface_artifacts.keys(),
        enable_profiling = enable_profiling,
        use_empty_lib = True,
        md_file = md_file,
        extra_lib_info = extra_lib_info,
    )
    deps_db, deps_conf = _make_package(
        ctx,
        link_style,
        pkgname,
        None,
        uniq_infos,
        interface_artifacts.keys(),
        enable_profiling = enable_profiling,
        use_empty_lib = True,
        md_file = md_file,
        extra_lib_info = extra_lib_info,
        for_deps = True,
    )

    hlib = HaskellLibraryInfo(
        name = pkgname,
        db = db,
        empty_db = empty_db,
        deps_db = deps_db,
        conf = HaskellPackageConfInfo(
            final_conf = final_conf,
            empty_conf = empty_conf,
            deps_conf = deps_conf,
        ),
        id = pkgname,
        dynamic = dynamic,  # TODO(ah) refine with dynamic projections
        interfaces = interface_artifacts,
        objects = object_artifacts,
        hie_files = hie_artifacts,
        stub_dirs = stub_dirs,
        extra_libraries = extra_lib_info,
        libs = all_libs,
        version = "1.0.0",
        is_prebuilt = False,
        profiling_enabled = enable_profiling,
        dependencies = toolchain_libs + project_libs,
        toolchain_dependencies = toolchain_libs_full,
        md_file = md_file,
        skeleton = skeleton,
    )

    return HaskellLibBuildOutput(
        hlib = hlib,
        solibs = solibs,
        link_infos = link_infos,
        compiled = compiled,
        libs = libs,
    )

def _get_actual_link_style(ctx: AnalysisContext, preferred_linkage: Linkage) -> LinkStyle:
    pic_behavior = ctx.attrs._cxx_toolchain[CxxToolchainInfo].pic_behavior
    link_style = cxx_toolchain_link_style(ctx)
    output_style = get_lib_output_style(
        to_link_strategy(link_style),
        preferred_linkage,
        pic_behavior,
    )

    # TODO(cjhopman): this haskell implementation does not consistently handle LibOutputStyle
    # and LinkStrategy as expected and it's hard to tell what the intent of the existing code is
    # and so we currently just preserve its existing use of the legacy LinkStyle type and just
    # naively convert it at the boundaries of other code. This needs to be cleaned up by someone
    # who understands the intent of the code here.
    actual_link_style = legacy_output_style_to_link_style(output_style)

    return actual_link_style

def haskell_library_impl(ctx: AnalysisContext) -> list[Provider]:
    sources = ctx.attrs.srcs
    if not sources:
        fail("{} has no srcs; either add one or delete the target".format(ctx.label))

    preferred_linkage = _attr_preferred_linkage(ctx)
    if ctx.attrs.enable_profiling and preferred_linkage == Linkage("any"):
        preferred_linkage = Linkage("static")

    # Get haskell and native link infos from all deps
    hlis = attr_deps_haskell_link_infos_sans_template_deps(ctx)
    nlis = attr_deps_merged_link_infos(ctx)

    link_infos = {}
    hlib_infos = {}
    hlink_infos = {}
    prof_hlib_infos = {}
    prof_hlink_infos = {}
    indexing_tsets = {}
    sub_targets = {}
    extra = {}

    (pkgname, libname) = make_haskell_names_from_label(
        ctx.label,
        ctx.attrs.use_same_package_name,
    )

    worker = ctx.attrs._worker[WorkerInfo] if ctx.attrs._worker else None

    skeleton = target_skeleton(ctx, sources)

    # Validate and compute GHC plugin flags.
    validate_plugins_attrs(ctx)

    haskell_toolchain = ctx.attrs._haskell_toolchain[HaskellToolchainInfo]

    # The non-profiling library is also needed to build the package with
    # profiling enabled, so we need to keep track of it for each link style.
    non_profiling_hlib = {}
    def_md_file = None
    for enable_profiling in [False, True]:
        for output_style in get_output_styles_for_linkage(preferred_linkage):
            link_style = legacy_output_style_to_link_style(output_style)
            if link_style == LinkStyle("shared") and enable_profiling:
                # Profiling isn't support with dynamic linking
                continue

            plugin_flags = compute_plugin_flags(ctx, link_style)

            # Request the build plan from GHC in order to resolve dependencies between modules.
            # This is executed for each output style even though the dependency graph is independent of it.
            # The reason for that is that the persistent worker initializes the module graph fully during this request,
            # requiring the linking and profiling settings to be applied.
            md_file = target_metadata(
                ctx,
                link_style = link_style,
                enable_profiling = enable_profiling,
                enable_haddock = not enable_profiling and not non_profiling_hlib,
                main = None,
                is_binary = False,
                sources = sources,
                worker = worker,
            )
            if link_style == LinkStyle("shared") and not enable_profiling:
                def_md_file = md_file

            hlib_build_out = _build_haskell_lib(
                ctx,
                worker,
                ctx.attrs.allow_worker,
                libname,
                pkgname,
                hlis = hlis,
                nlis = nlis,
                link_style = link_style,
                enable_profiling = enable_profiling,
                # enable haddock only for the first non-profiling hlib
                enable_haddock = not enable_profiling and not non_profiling_hlib,
                md_file = md_file,
                skeleton = skeleton,
                non_profiling_hlib = non_profiling_hlib.get(link_style),
                unit_plugin_flags = plugin_flags.unit,
                srcs_plugin_flags = plugin_flags.srcs,
                extra_tool_paths = plugin_flags.global_tool_paths,
                srcs_plugin_tool_paths = plugin_flags.srcs_tool_paths,
                plugin_toolchain_deps = plugin_flags.plugin_toolchain_deps,
            )
            if not enable_profiling:
                non_profiling_hlib[link_style] = hlib_build_out

            hlib = hlib_build_out.hlib
            compiled = hlib_build_out.compiled
            libs = hlib_build_out.libs

            if enable_profiling:
                prof_hlib_infos[link_style] = hlib
                prof_hlink_infos[link_style] = ctx.actions.tset(HaskellLibraryInfoTSet, value = hlib, children = [li.prof_info[link_style] for li in hlis])
            else:
                hlib_infos[link_style] = hlib
                hlink_infos[link_style] = ctx.actions.tset(HaskellLibraryInfoTSet, value = hlib, children = [li.info[link_style] for li in hlis])
                link_infos[link_style] = hlib_build_out.link_infos

            # Build the indices and create subtargets only once, with profiling
            # enabled or disabled based on what was set in the library's
            # target.
            if ctx.attrs.enable_profiling == enable_profiling:
                if compiled.producing_indices:
                    tset = derive_indexing_tset(
                        ctx.actions,
                        link_style,
                        compiled.interfaces,
                        attr_deps(ctx),
                    )
                    indexing_tsets[link_style] = tset

                sub_targets[link_style.value.replace("_", "-")] = [DefaultInfo(
                    default_outputs = libs,
                    sub_targets = _haskell_module_sub_targets(
                        compiled = compiled,
                        link_style = link_style,
                        enable_profiling = enable_profiling,
                    ) | dict(
                        metadata = [DefaultInfo(default_output = md_file)],
                        db = [DefaultInfo(default_output = hlib.db)],
                        empty_db = [DefaultInfo(default_output = hlib.empty_db)],
                        deps_db = [DefaultInfo(default_output = hlib.deps_db)],
                    ),
                )]

    # By default, [metadata] = [shared][metadata].
    if def_md_file:
        sub_targets["metadata"] = [DefaultInfo(default_output = def_md_file)]

    actual_link_style = _get_actual_link_style(ctx, preferred_linkage)

    default_compiled = non_profiling_hlib[actual_link_style].compiled
    manifest_outputs = default_compiled.interfaces + default_compiled.objects
    manifest = ctx.actions.write("manifest.txt", cmd_args(manifest_outputs))
    manifest = manifest.with_associated_artifacts(manifest_outputs)
    sub_targets["manifest"] = [DefaultInfo(
        default_output = manifest,
        other_outputs = manifest_outputs,
    )]

    haddock = haskell_haddock_lib(
        ctx,
        pkgname,
        non_profiling_hlib[LinkStyle("shared")].compiled,
        # Use the shared, non-profiling metadata (build plan) to match the
        # shared compiled info passed above.
        def_md_file,
    )

    haskell_toolchain = ctx.attrs._haskell_toolchain[HaskellToolchainInfo]

    styles = [
        ctx.actions.declare_output("haddock-html", file)
        for file in "synopsis.png linuwial.css quick-jump.css haddock-bundle.min.js".split()
    ]
    ctx.actions.run(
        cmd_args(
            haskell_toolchain.haddock,
            "--gen-index",
            "--optghc=-package-env=-",
            "-o",
            cmd_args(styles[0].as_output(), parent = 1),
            hidden = [file.as_output() for file in styles],
        ),
        category = "haddock_styles",
        # FIXME(jadel): determine whether this is safe to upload to cache
        allow_cache_upload = False,
    )
    sub_targets.update({
        "haddock": [DefaultInfo(
            default_outputs = haddock.html.values(),
            sub_targets = {
                module: [DefaultInfo(default_output = html, other_outputs = styles)]
                for module, html in haddock.html.items()
            },
        )],
    })

    if ctx.attrs.no_default_info:
        def_info = DefaultInfo()
    else:
        def_info = DefaultInfo(
            default_outputs = [manifest],
            other_outputs = manifest_outputs,
            sub_targets = sub_targets,
        )
    providers = [
        def_info,
        HaskellLibraryProvider(
            lib = hlib_infos,
            prof_lib = prof_hlib_infos,
        ),
        HaskellLinkInfo(
            info = hlink_infos,
            prof_info = prof_hlink_infos,
            extra = extra,
        ),
        haddock,
    ]

    if indexing_tsets:
        providers.append(HaskellIndexInfo(info = indexing_tsets))

    providers.append(ResourceInfo(resources = gather_resources(
        label = ctx.label,
        resources = haskell_attr_resources(ctx),
        deps = attr_deps(ctx),
    )))

    src_pairs = compute_source_module_paths(
        package = ctx.label.package,
        module_prefix = getattr(ctx.attrs, "module_prefix", None),
        strip_prefix = ctx.attrs.strip_prefix,
        sources = sources,
    )
    src_children = [
        dep[HaskellSourceInfo].srcs
        for dep in attr_deps(ctx)
        if HaskellSourceInfo in dep
    ]

    # Node value carries both source pairs and this library's compiler flags.
    # The flags (e.g. -D__LOCAL_PACKAGE_ROOT__) are needed for TH splices that
    # depend on CPP defines to locate data files at the right path.
    src_tset = ctx.actions.tset(
        HaskellSourcesTSet,
        value = struct(
            srcs = src_pairs,
            # Only propagate CPP defines (-D...) for GHCi's interpreted mode.
            # Linker flags (-l, -L) cause GHCi to dlopen native libs which the
            # omnibus SO already handles. Location macros would produce literal
            # $(location ...) text in the bash script. Only CPP defines like
            # -D__LOCAL_PACKAGE_ROOT__ affect TH splices and need propagation.
            # Buck2 wraps ResolvedStringWithMacros values in quotes when str()d,
            # so strip quotes before checking the prefix.
            compiler_flags = [str(f).strip('"') for f in ctx.attrs.compiler_flags if str(f).strip('"').startswith("-D")],
        ),
        children = src_children,
    )
    providers.append(HaskellSourceInfo(srcs = src_tset))

    return providers

# TODO(cjhopman): should this be LibOutputType or LinkStrategy?
def derive_indexing_tset(
        actions: AnalysisActions,
        link_style: LinkStyle,
        value: list[Artifact] | None,
        children: list[Dependency]) -> HaskellIndexingTSet:
    index_children = []
    for dep in children:
        li = dep.get(HaskellIndexInfo)
        if li:
            if (link_style in li.info):
                index_children.append(li.info[link_style])

    return actions.tset(
        HaskellIndexingTSet,
        value = value,
        children = index_children,
    )

def _make_link_package(
        ctx: AnalysisContext,
        link_style: LinkStyle,
        pkgname: str,
        hlis: list[HaskellLibraryInfo],
        static_libs: ArgLike) -> Artifact:
    artifact_suffix = get_artifact_suffix(link_style, False)

    conf = cmd_args(
        "name: " + pkgname,
        "version: 1.0.0",
        "id: " + pkgname,
        "key: " + pkgname,
        "exposed: False",
        cmd_args(cmd_args(static_libs, delimiter = ", "), format = "ld-options: {}"),
        "depends: " + ", ".join([lib.id for lib in hlis]),
    )

    pkg_conf = ctx.actions.write("pkg-" + artifact_suffix + "_link.conf", conf)
    db = ctx.actions.declare_output("db-" + artifact_suffix + "_link", dir = True)

    haskell_toolchain = ctx.attrs._haskell_toolchain[HaskellToolchainInfo]
    registerer = ctx.attrs._ghc_pkg_registerer[RunInfo]
    category_prefix = "haskell_package_link_"

    _register_package_conf(
        ctx.actions,
        pkg_conf,
        db.as_output(),
        registerer,
        haskell_toolchain.packager,
        category_prefix,
        artifact_suffix,
        False,
        ctx.attrs.allow_cache_upload,
    )

    return db

_DynamicLinkBinaryOptions = record(
    label = Label,
    deps = list[Dependency],
    direct_deps_link_info = list[HaskellLinkInfo],
    direct_deps_lg_tsets = list[HaskellLinkGroupTSet],
    enable_profiling = bool,
    haskell_direct_deps_lib_infos = list[HaskellLibraryInfo],
    haskell_toolchain = HaskellToolchainInfo,
    linker_info = typing.Any,
    link_args = cmd_args,
    link_style = LinkStyle,
    link_haskell_objects_at_once = bool,
    linker_flags = list[typing.Any],  # Arguments.
    link_group_libs = list[HaskellLinkGroupInfo],
    toolchain_libs = list[str],
    # Haskell Library TSet
    haskell_library_tset = TransitiveSet,
    allow_cache_upload = bool,
)

def _dynamic_link_binary_impl(
        actions: AnalysisActions,
        pkg_deps: ResolvedDynamicValue,
        extra_lib_dyns: list[ResolvedDynamicValue],
        output: OutputArtifact,
        output_symlink_dir: OutputArtifact | None,
        arg: _DynamicLinkBinaryOptions) -> list[Provider]:
    link_args = arg.link_args.copy()  # link is already frozen, make a copy
    link_style = arg.link_style
    link_cmd_hidden = []

    toolchain_package_db = pkg_deps.providers[DynamicHaskellToolchainPackageDbInfo].toolchain_packages

    # Extra flags that can be dynamically resolved. For example, -rpath /nix/store/...
    for dyn in extra_lib_dyns:
        fs = dyn.providers[ExtraGhcLinkerFlagsInfo].flags
        link_args.add(cmd_args(cmd_args(cmd_args(fs, delimiter = ","), format = "-Wl,{}"), prepend = "-optl"))

    link_args.add("-hide-all-packages")

    link_group_tset = actions.tset(
        HaskellLinkGroupTSet,
        children = arg.direct_deps_lg_tsets,
    )

    all_link_group_ids = link_group_tset.reduce("components")

    all_toolchain_libs0 = []
    all_toolchain_libs0.extend(arg.toolchain_libs)
    all_toolchain_libs0.extend([p.name for p in arg.haskell_library_tset.reduce("toolchain_packages")])
    all_toolchain_libs0.extend([p.name for p in link_group_tset.reduce("toolchain_packages")])
    all_toolchain_libs = dedupe_by_value(all_toolchain_libs0)

    toolchain_package_db_tset = actions.tset(
        HaskellToolchainPackageDbTSet,
        children = [toolchain_package_db[name] for name in all_toolchain_libs if name in toolchain_package_db],
    )

    packagedb_args = cmd_args()
    package_args = cmd_args()
    object_args = cmd_args()

    # toolchain libs: all transitive dependencies are needed.
    packagedb_args.add(toolchain_package_db_tset.project_as_args("toolchain_package_db"))
    package_args.add(all_toolchain_libs)

    # link group
    # NOTE: link group for executable is currently only relevant to LinkStyle("shared")
    # NOTE: link group is not affected by link_haskell_objects_at_once.
    for lg in arg.link_group_libs:
        packagedb_args.add(cmd_args(lg.db))
    for lg in arg.link_group_libs:
        package_args.add(lg.pkgname)
        link_cmd_hidden.append(lg.lib)

    # NOTE: If link_haskell_objects_at_once = True, all the transitive dependency objects
    # (except for those from haskell_link_group) are directly linked at executable binary
    # linking. Therefore, we set package db dependencies to use empty_db (module-object-only
    # packages)
    if arg.link_haskell_objects_at_once:  # when link_haskell_objects_at_once = True
        for hlib in arg.haskell_library_tset.traverse():
            # Add all the transitive objects except for those in link group.
            # for now, only non-profiled binary
            is_profiled = False
            if hlib.name not in all_link_group_ids:
                object_args.add(hlib.objects[is_profiled])

    else:  # when link_haskell_objects_at_once = False
        for hlib in arg.haskell_library_tset.traverse():
            if hlib.name not in all_link_group_ids:
                packagedb_args.add(cmd_args(hlib.db))
                link_cmd_hidden.append(hlib.libs)
        for item in arg.haskell_direct_deps_lib_infos:
            if item.id not in all_link_group_ids:
                package_args.add(item.name)
                link_cmd_hidden.append(item.libs)

    link_args.add(cmd_args(packagedb_args, prepend = "-package-db"))
    link_args.add(cmd_args(package_args, prepend = "-package"))
    link_args.add(object_args)

    link_args.add(arg.haskell_toolchain.linker_flags)
    link_args.add(arg.linker_flags)

    link_args.add("-o", output)

    artifact_suffix = get_artifact_suffix(arg.link_style, arg.enable_profiling)
    link_cmd = cmd_args(
        arg.haskell_toolchain.compiler,
        at_argfile(
            actions = actions,
            name = "haskell_link_" + artifact_suffix.replace("-", "_") + ".argsfile",
            args = link_args,
            allow_args = True,
        ),
        hidden = link_cmd_hidden,
    )

    # TODO: this must be interleaved with the above.
    if arg.link_style == LinkStyle("shared"):
        shlib_entries = []
        components = link_group_tset.reduce("components")
        for link_group in link_group_tset.traverse():
            shlib_entries.append((link_group.lib.basename, link_group.lib))
        if not arg.link_haskell_objects_at_once:
            for hlib in arg.haskell_library_tset.traverse():
                if hlib.name not in components:
                    shlib_entries.extend([(lib.basename, lib) for lib in hlib.libs])

        unnamed_packages = 0
        for toolchain_pkg in toolchain_package_db_tset.traverse():
            if toolchain_pkg.name:
                shlib_entries.append((toolchain_pkg.name, toolchain_pkg.path))
            else:
                unnamed_packages += 1
                shlib_entries.append(("{}".format(unnamed_packages), toolchain_pkg.path))

        shlibs_dict = {}
        for (name, artifact) in shlib_entries:
            existing = shlibs_dict.get(name)
            if existing == artifact:
                continue
            if existing != None:
                name = "{}.{}".format(name, len(shlibs_dict))
            shlibs_dict[name] = artifact
        if output_symlink_dir:
            actions.symlinked_dir(
                output_symlink_dir,
                shlibs_dict,
            )

    actions.run(
        link_cmd,
        category = "haskell_link",
        # explicit turn this on for local_only actions to upload their results.
        allow_cache_upload = arg.allow_cache_upload,
    )

    return []

_dynamic_link_binary = dynamic_actions(
    impl = _dynamic_link_binary_impl,
    attrs = {
        "arg": dynattrs.value(typing.Any),
        "pkg_deps": dynattrs.option(dynattrs.dynamic_value()),
        "extra_lib_dyns": dynattrs.list(dynattrs.dynamic_value()),
        "output": dynattrs.output(),
        "output_symlink_dir": dynattrs.option(dynattrs.output()),
    },
)

HaskellExecutableOutput = record(
    binary = Artifact,
    sub_targets = dict[str, list[DefaultInfo]],
    run = ArgLike,
    runtime_files = field(list[ArgLike], []),
    index_info = field(HaskellIndexInfo | None),
)

def haskell_binary_impl(ctx: AnalysisContext) -> list[Provider]:
    exe = _haskell_executable(ctx)

    providers = [
        DefaultInfo(exe.binary, other_outputs = exe.runtime_files, sub_targets = exe.sub_targets),
        RunInfo(args = exe.run),
    ]
    if exe.index_info:
        providers.append(exe.index_info)

    return providers

def _haskell_executable(ctx: AnalysisContext) -> HaskellExecutableOutput:
    sources = ctx.attrs.srcs
    if not sources:
        fail("{} has no srcs; either add one or delete the target".format(ctx.label))

    enable_profiling = ctx.attrs.enable_profiling

    # Decide what kind of linking we're doing

    link_style = attr_link_style(ctx)

    # Profiling doesn't support shared libraries
    if enable_profiling and link_style == LinkStyle("shared"):
        link_style = LinkStyle("static")

    worker = ctx.attrs._worker[WorkerInfo] if ctx.attrs._worker else None

    main = ctx.attrs.main
    src_main = ctx.attrs.src_main

    # if only one file in srcs, it's automatically assigned to src_main.
    if src_main == None:
        if len(sources) > 1:
            fail("More than one Haskell source files in srcs, but src_main or main is not specified.")
        if len(sources) == 1:
            src_main = sources[0]

    # Validate and compute GHC plugin flags.
    validate_plugins_attrs(ctx)
    plugin_flags = compute_plugin_flags(ctx, link_style)

    md_file = target_metadata(
        ctx,
        link_style = link_style,
        enable_profiling = enable_profiling,
        enable_haddock = False,
        main = getattr(ctx.attrs, "main", None),
        is_binary = True,
        sources = sources,
        worker = worker,
    )

    (pkgname, libname) = make_haskell_names_from_label(ctx.label, False)

    compiled = compile(
        ctx,
        link_style,
        incremental = ctx.attrs.incremental,
        enable_profiling = enable_profiling,
        enable_haddock = False,
        md_file = md_file,
        worker = worker,
        pkgname = pkgname,
        is_haskell_binary = True,
        src_main = src_main,
        unit_plugin_flags = plugin_flags.unit,
        srcs_plugin_flags = plugin_flags.srcs,
        extra_tool_paths = plugin_flags.global_tool_paths,
        srcs_plugin_tool_paths = plugin_flags.srcs_tool_paths,
        plugin_toolchain_deps = plugin_flags.plugin_toolchain_deps,
    )

    haskell_toolchain = ctx.attrs._haskell_toolchain[HaskellToolchainInfo]

    toolchain_libs = [dep[HaskellToolchainLibrary].name for dep in attr_deps(ctx) if HaskellToolchainLibrary in dep]

    output = ctx.actions.declare_output(ctx.label.name)
    link_args = cmd_args()

    objects = {}

    # extra-libraries
    link_args.add(unpack_link_args(get_link_args_for_strategy(
        ctx.actions,
        ctx.label,
        get_cxx_toolchain_info(ctx).linker_info,
        [
            lib[MergedLinkInfo]
            for lib in ctx.attrs.extra_libraries
        ],
        to_link_strategy(link_style),
        prefer_stripped = True,
        transformation_spec_context = None,
    )))

    # only add the first object per module
    # TODO[CB] restructure this to use a record / dict for compiled.objects
    for obj in compiled.objects:
        key = paths.replace_extension(obj.short_path, "")
        if not key in objects:
            objects[key] = obj

    link_args.add(objects.values())

    indexing_tsets = {}
    if compiled.producing_indices:
        tset = derive_indexing_tset(ctx.actions, link_style, compiled.interfaces, attr_deps(ctx))
        indexing_tsets[link_style] = tset

    if link_style == LinkStyle("shared"):
        link_args.add("-dynamic")

    haskell_direct_deps_lib_infos = attr_deps_haskell_lib_infos(
        ctx,
        link_style,
        enable_profiling = enable_profiling,
    )

    direct_deps_info = [
        lib.prof_info[link_style] if enable_profiling else lib.info[link_style]
        for lib in attr_deps_haskell_link_infos(ctx)
    ]
    link_group_libs = attr_deps_haskell_link_group_infos(ctx, link_style)

    if link_style == LinkStyle("shared"):
        output_symlink_dir = ctx.actions.declare_output(
            "__{}__shared_libs_symlink_tree".format(ctx.label.name),
            dir = True,
        )

        link_args.add(cmd_args(
            "-Wl,-rpath,{}/{}".format(
                get_rpath_origin(get_cxx_toolchain_info(ctx).linker_info.type),
                output_symlink_dir.short_path,
            ),
            prepend = "-optl",
        ))
    else:
        output_symlink_dir = None

    haskell_library_tset = ctx.actions.tset(HaskellLibraryInfoTSet, children = direct_deps_info)

    label = ctx.label
    linker_info = get_cxx_toolchain_info(ctx).linker_info
    direct_extra_libs = ctx.attrs.extra_libraries

    # get all the native library deps wanted from Haskell dependencies transitively and link them.
    extra_lib_info_transitive = haskell_library_tset.reduce("extra_libs")
    direct_extra_lib_info = get_extra_lib_info(link_style, direct_extra_libs)
    extra_lib_info = merge_extra_lib_infos(direct_extra_lib_info, extra_lib_info_transitive)
    link_infos = get_link_infos_from_extra_lib_info(
        ctx.actions,
        label,
        linker_info,
        link_style,
        extra_lib_info,
    )
    for link_info in link_infos:
        for linkable in link_info.linkables:
            if isinstance(linkable, SharedLibLinkable):
                link_args.add(cmd_args(linkable.lib, format = "-L{}", parent = 1))
                link_args.add(cmd_args(get_libname(linkable), format = "-l{}"))
            else:
                # TODO(iank): Implement the support for static archives.
                fail("Unimplemented linkable: {}".format(linkable))

    ctx.actions.dynamic_output_new(_dynamic_link_binary(
        pkg_deps = haskell_toolchain.packages.dynamic if haskell_toolchain.packages else None,
        extra_lib_dyns = extra_lib_info.extra_lib_dyns,
        output = output.as_output(),
        output_symlink_dir = output_symlink_dir.as_output() if output_symlink_dir else None,
        arg = _DynamicLinkBinaryOptions(
            label = label,
            deps = attr_deps(ctx),
            direct_deps_link_info = attr_deps_haskell_link_infos(ctx),
            direct_deps_lg_tsets = attr_deps_haskell_link_group_tsets(ctx, link_style),
            enable_profiling = enable_profiling,
            haskell_direct_deps_lib_infos = haskell_direct_deps_lib_infos,
            haskell_toolchain = haskell_toolchain,
            linker_info = linker_info,
            link_args = link_args,
            link_style = link_style,
            link_haskell_objects_at_once = ctx.attrs.link_haskell_objects_at_once,
            linker_flags = ctx.attrs.linker_flags,
            link_group_libs = link_group_libs,
            toolchain_libs = toolchain_libs,
            haskell_library_tset = haskell_library_tset,
            allow_cache_upload = ctx.attrs.allow_cache_upload,
        ),
    ))

    resources = flatten_dict(gather_resources(
        label = ctx.label,
        resources = haskell_attr_resources(ctx),
        deps = attr_deps(ctx),
    ).values())
    resources_hidden = []
    if resources:
        resources_hidden.append(create_resource_db(
            ctx = ctx,
            name = output.basename + ".resources.json",
            binary = output,
            resources = resources,
        ))
        for resource in resources.values():
            resources_hidden.append(resource.default_output)
            resources_hidden.extend(resource.other_outputs)

    if link_style == LinkStyle("shared"):
        shared_libs = [output_symlink_dir] + [lginfo.lib for lginfo in link_group_libs]

        output = output.with_associated_artifacts(shared_libs)
        run = cmd_args(output, hidden = shared_libs + resources_hidden)
    else:
        run = cmd_args(output, hidden = resources_hidden)

    sub_targets = {
        "metadata": [DefaultInfo(default_output = md_file)],
    }
    sub_targets.update(_haskell_module_sub_targets(
        compiled = compiled,
        link_style = link_style,
        enable_profiling = enable_profiling,
    ))

    return HaskellExecutableOutput(
        binary = output,
        sub_targets = sub_targets,
        run = run,
        runtime_files = resources_hidden,
        index_info = HaskellIndexInfo(info = indexing_tsets) if indexing_tsets else None,
    )

def _haskell_module_sub_targets(
        *,
        compiled: CompileResultInfo,
        link_style: LinkStyle,
        enable_profiling: bool) -> dict[str, list[Provider]]:
    (osuf, hisuf) = output_extensions(link_style, enable_profiling)
    return {
        "interfaces": [DefaultInfo(sub_targets = {
            src_to_module_name(hi.short_path): [DefaultInfo(default_output = hi)]
            for hi in compiled.interfaces
            if hi.extension[1:] == hisuf
        })],
        "objects": [DefaultInfo(sub_targets = {
            src_to_module_name(o.short_path): [DefaultInfo(default_output = o)]
            for o in compiled.objects
            if o.extension[1:] == osuf
        })],
        "hie": [DefaultInfo(sub_targets = {
            src_to_module_name(hie.short_path): [DefaultInfo(default_output = hie)]
            for hie in compiled.hie
            if hie.extension == ".hie"
        })],
    }

#
def _make_link_group_package(
        actions: AnalysisActions,
        *,
        link_style: LinkStyle,
        link_infos: list[LinkInfo],
        pkgname: str,
        libname: str,
        registerer: RunInfo,
        haskell_toolchain: HaskellToolchainInfo,
        db: OutputArtifact,
        hlibinfos: list[HaskellLibraryInfo],
        project_deps: list[str],
        extra_lib_dyns: list[ResolvedDynamicValue],
        toolchain_lib_dyn_infos: list[ResolvedDynamicValue],
        allow_cache_upload: bool) -> None:
    artifact_suffix = get_artifact_suffix(link_style, False)

    toolchain_deps = [info.providers[DynamicHaskellToolchainLibraryInfo].id for info in toolchain_lib_dyn_infos]
    direct_deps = [lib.name for lib in hlibinfos]
    indirect_deps = [n for n in project_deps if n not in direct_deps]
    all_deps = indirect_deps + toolchain_deps

    extra_ld_opts = cmd_args()
    for dyn in extra_lib_dyns:
        fs = dyn.providers[ExtraGhcLinkerFlagsInfo].flags
        extra_ld_opts.add(cmd_args(cmd_args(fs, delimiter = ","), format = "\"-Wl,{}\""))

    conf = cmd_args(
        "name: " + pkgname,
        "version: 1.0.0",
        "id: " + pkgname,
        "key: " + pkgname,
        "exposed: False",
        "depends: " + ", ".join(all_deps),
    )

    profiled = False
    library_dirs = [_mk_artifact_dir("lib", profiled, link_style)]
    conf.add(cmd_args(cmd_args(library_dirs, delimiter = ","), format = "library-dirs: {}"))
    conf.add(cmd_args(libname, format = "hs-libraries: {}"))

    # collect all the extra library dependencies from component Haskell libraries
    append_pkg_conf_link_fields_for_link_infos(
        pkgname = pkgname,
        pkg_conf = conf,
        link_infos = link_infos,
        extra_ld_opts = extra_ld_opts,
    )

    pkg_conf = actions.write("pkg-" + artifact_suffix, conf)

    _register_package_conf(
        actions,
        pkg_conf,
        db,
        registerer,
        haskell_toolchain.packager,
        "haskell_package_linkgroup_",
        artifact_suffix,
        False,
        allow_cache_upload,
    )

_DynamicLinkGroupSharedOptions = record(
    hlibinfos = list[HaskellLibraryInfo],
    pkgname = str,
    libname = str,
    libfile = str,
    link_style = LinkStyle,
    linker_info = LinkerInfo,
    registerer = RunInfo,
    haskell_toolchain = HaskellToolchainInfo,
    toolchain_deps = list[HaskellToolchainLibrary],
    project_deps = list[str],
    libs_tset = HaskellLibraryInfoTSet,
    link_group_tset = HaskellLinkGroupTSet,
    link_args = LinkArgs,
    allow_cache_upload = bool,
)

# Implement dynamic library linking for a link group
def _dynamic_link_group_shared_impl(
        actions: AnalysisActions,
        lib: OutputArtifact,
        db: OutputArtifact,
        arg: _DynamicLinkGroupSharedOptions,
        toolchain_lib_dyn_infos: list[ResolvedDynamicValue],
        pkg_deps: ResolvedDynamicValue | None,
        extra_lib_dyns: list[ResolvedDynamicValue]):
    link_cmd_hidden = []

    link_args = cmd_args()
    link_args.add(arg.haskell_toolchain.linker_flags)

    toolchain_deps = [d.name for d in arg.toolchain_deps]
    toolchain_package_db = pkg_deps.providers[DynamicHaskellToolchainPackageDbInfo].toolchain_packages

    packagedb_args = cmd_args()
    package_args = cmd_args()
    object_args = cmd_args()

    # toolchain package db
    toolchain_package_db_tset = actions.tset(
        HaskellToolchainPackageDbTSet,
        children = [toolchain_package_db[name] for name in toolchain_deps if name in toolchain_package_db],
    )
    packagedb_args.add(toolchain_package_db_tset.project_as_args("toolchain_package_db"))

    # adding toolchain dep packages
    package_args.add(cmd_args(toolchain_deps, prepend = "-package"))

    # linkgroup package db and package
    packagedb_args.add(arg.link_group_tset.project_as_args("package_db"))
    package_args.add(cmd_args(arg.link_group_tset.project_as_args("package"), prepend = "-package"))

    # adding indirect project dep packages
    direct_deps = []
    indirect_deps = []
    direct_deps_name = [d.name for d in arg.hlibinfos]

    component_deps = arg.link_group_tset.reduce("components") + direct_deps_name

    for d in list(arg.libs_tset.traverse()):
        if d.name in component_deps:
            direct_deps.append(d)
            packagedb_args.add(cmd_args(d.empty_db))
        else:
            indirect_deps.append(d)
            packagedb_args.add(cmd_args(d.db))

    link_args.add(cmd_args(packagedb_args, prepend = "-package-db"))
    for d in indirect_deps:
        package_args.add(cmd_args(d.name, prepend = "-package"))
        link_cmd_hidden.append(d.libs)

    link_args.add(package_args)

    for hlib in arg.hlibinfos:
        is_profiled = False
        for o in hlib.objects[is_profiled]:
            object_args.add(o)

    link_args.add(unpack_link_args(arg.link_args))

    # Extra flags that can be dynamically resolved. For example, -rpath /nix/store/...
    for dyn in extra_lib_dyns:
        fs = dyn.providers[ExtraGhcLinkerFlagsInfo].flags
        link_args.add(cmd_args(cmd_args(cmd_args(fs, delimiter = ","), format = "-Wl,{}"), prepend = "-optl"))

    suffix = get_artifact_suffix(arg.link_style, False)
    if arg.link_style == LinkStyle("shared"):
        link_args.add(object_args)
        link_args.add(
            get_shared_library_flags(arg.linker_info.type),
            "-dynamic",
            cmd_args(
                _get_haskell_shared_library_name_linker_flags(arg.linker_info.type, arg.libfile),
                prepend = "-optl",
            ),
            "-o",
            lib,
        )

        link_cmd = cmd_args(
            arg.haskell_toolchain.linker,
            at_argfile(
                actions = actions,
                name = "haskell_link_group_{}.argsfile".format(suffix),
                args = link_args,
                allow_args = True,
            ),
            hidden = link_cmd_hidden,
        )
    else:
        # NOTE: For static linking, we use the ar command directly. Unfortunately,
        # although GHC as a linker can make static library with -staticlib but that
        # includes more undefined symbols than desired, so we get linker error at exe
        # linking.
        # Also, we couldn't use make_archive directly since we are here in a dynamic action.
        # (the prelude function takes ctx).
        #
        # NOTE: This is from the private _archive_flags function in @prelude//cxx:archive.bzl
        # TODO: Make prelude archive_flags function more openly available or make_archive
        #       should take actions, not ctx.
        # q: Operate in quick append mode.
        # c: Suppress warning about creating a new archive.
        # s: Run ranlib to generate symbol index for faster linking.
        new_link_args = cmd_args("qcs")
        new_link_args.add(lib)
        new_link_args.add(object_args)

        link_cmd = cmd_args(
            arg.linker_info.archiver,
            at_argfile(
                actions = actions,
                name = "haskell_link_group_{}.argsfile".format(suffix),
                args = new_link_args,
                allow_args = True,
            ),
            hidden = link_cmd_hidden,
        )

    actions.run(
        link_cmd,
        category = "haskell_link_group_shared",
        identifier = arg.libname,
        allow_cache_upload = arg.allow_cache_upload,
    )

    _make_link_group_package(
        actions,
        link_style = arg.link_style,
        link_infos = map_to_link_infos([arg.link_args]),
        pkgname = arg.pkgname,
        libname = arg.libname,
        registerer = arg.registerer,
        haskell_toolchain = arg.haskell_toolchain,
        db = db,
        hlibinfos = arg.hlibinfos,
        project_deps = arg.project_deps,
        extra_lib_dyns = extra_lib_dyns,
        toolchain_lib_dyn_infos = toolchain_lib_dyn_infos,
        allow_cache_upload = arg.allow_cache_upload,
    )

    return []

_dynamic_link_group_shared = dynamic_actions(
    impl = _dynamic_link_group_shared_impl,
    attrs = {
        "lib": dynattrs.output(),
        "db": dynattrs.output(),
        "arg": dynattrs.value(typing.Any),
        "toolchain_lib_dyn_infos": dynattrs.list(dynattrs.dynamic_value()),
        "pkg_deps": dynattrs.option(dynattrs.dynamic_value()),
        "extra_lib_dyns": dynattrs.list(dynattrs.dynamic_value()),
    },
)

# Haskell link group implementation
# Link group creates a virtual package with only shared and static library artifacts
# This saves linking time.
def make_haskell_link_group(
        ctx: AnalysisContext,
        *,
        label: Label,
        hlibs: list[HaskellLibraryProvider],
        registerer: RunInfo,
        haskell_toolchain: HaskellToolchainInfo,
        linker_info: LinkerInfo,
        allow_cache_upload: bool) -> list[Provider]:
    preferred_linkage = _attr_preferred_linkage(ctx)
    actual_link_style = _get_actual_link_style(ctx, preferred_linkage)

    providers = []
    lg_provider = HaskellLinkGroupProvider(
        link_group = {},
    )
    lg_tset_provider = HaskellLinkGroupTSetProvider(
        link_group_tsets = {},
    )

    # TODO: for now, support only non-profiling.
    for enable_profiling in [False]:
        # TODO: for now, support only shared link_style.
        for output_style in get_output_styles_for_linkage(preferred_linkage):
            link_style = legacy_output_style_to_link_style(output_style)
            hlibinfos = [p.lib[link_style] for p in hlibs]
            direct_deps_info = [lib.info[link_style] for lib in attr_deps_haskell_link_infos_sans_template_deps(ctx)]
            direct_deps_lg_tsets = attr_deps_haskell_link_group_tsets(ctx, link_style)

            actions = ctx.actions
            artifact_suffix = get_artifact_suffix(link_style, enable_profiling)
            dynamic_lib_suffix = "." + LINKERS[linker_info.type].default_shared_library_extension
            static_lib_suffix = "_p.a" if enable_profiling else ".a"

            libprefix = repr(label.path).replace("//", "_").replace("/", "_")

            (pkgname, libname) = make_haskell_names_from_label(label, False)

            libstem = libname
            if link_style == LinkStyle("shared"):
                compiler_suffix = "-ghc{}".format(haskell_toolchain.compiler_major_version)
            else:
                compiler_suffix = ""
            libfile = "lib" + libstem + compiler_suffix + (dynamic_lib_suffix if link_style == LinkStyle("shared") else static_lib_suffix)

            lib_short_path = paths.join("lib-{}".format(artifact_suffix), libfile)
            lib = actions.declare_output(lib_short_path)
            db = actions.declare_output("db-" + artifact_suffix, dir = True)

            libs_tset = actions.tset(
                HaskellLibraryInfoTSet,
                children = direct_deps_info,
            )

            link_group_tset = actions.tset(
                HaskellLinkGroupTSet,
                children = direct_deps_lg_tsets,
            )

            toolchain_deps = libs_tset.reduce("toolchain_packages")
            toolchain_deps_name = [d.name for d in toolchain_deps]
            toolchain_lib_dyn_infos = [dep.dynamic for dep in toolchain_deps]

            all_deps = libs_tset.reduce("packages")
            project_deps = [d for d in all_deps if d not in toolchain_deps_name]

            pkg_deps = haskell_toolchain.packages.dynamic if haskell_toolchain.packages else None

            # collect all the extra library dependencies from component Haskell libraries
            direct_extra_libs = [elib for p in hlibs for elib in p.lib[link_style].extra_libraries.as_deps]
            link_args = get_link_args_for_strategy(
                ctx.actions,
                ctx.label,
                get_cxx_toolchain_info(ctx).linker_info,
                # These attributes will always have `MergedLinkInfo` and
                # `GhcLinkableInfo` providers, but the type system doesn't guarantee
                # that statically, so let's just be safe.
                [
                    extra_lib[MergedLinkInfo]
                    for extra_lib in direct_extra_libs
                    if MergedLinkInfo in extra_lib
                ],
                to_link_strategy(link_style),
                prefer_stripped = True,
                transformation_spec_context = None,
            )
            extra_lib_dyns = dedupe_by_value([
                extra_lib[GhcLinkableInfo].extra_ghc_linker_flags_dynamic
                for extra_lib in direct_extra_libs
                if GhcLinkableInfo in extra_lib
            ])

            actions.dynamic_output_new(_dynamic_link_group_shared(
                lib = lib.as_output(),
                db = db.as_output(),
                arg = _DynamicLinkGroupSharedOptions(
                    hlibinfos = hlibinfos,
                    pkgname = pkgname,
                    libname = libname,
                    libfile = libfile,
                    link_style = link_style,
                    linker_info = linker_info,
                    registerer = registerer,
                    haskell_toolchain = haskell_toolchain,
                    toolchain_deps = toolchain_deps,
                    project_deps = project_deps,
                    libs_tset = libs_tset,
                    link_group_tset = link_group_tset,
                    link_args = link_args,
                    allow_cache_upload = allow_cache_upload,
                ),
                toolchain_lib_dyn_infos = toolchain_lib_dyn_infos,
                pkg_deps = pkg_deps,
                extra_lib_dyns = extra_lib_dyns,
            ))

            if link_style == actual_link_style:
                providers.append(DefaultInfo(default_outputs = [lib]))

            lg_provider.link_group[link_style] = HaskellLinkGroupInfo(
                pkgname = pkgname,
                db = db,
                lib = lib,
                libraries = hlibinfos,
            )

            link_group_tsets = actions.tset(
                HaskellLinkGroupTSet,
                value = lg_provider.link_group[link_style],
                children = direct_deps_lg_tsets,
            )
            lg_tset_provider.link_group_tsets[link_style] = link_group_tsets

    providers.append(lg_provider)
    providers.append(lg_tset_provider)

    return providers

def haskell_link_group_impl(ctx: AnalysisContext) -> list[Provider]:
    registerer = ctx.attrs._ghc_pkg_registerer[RunInfo]
    haskell_toolchain = ctx.attrs._haskell_toolchain[HaskellToolchainInfo]
    linker_info = ctx.attrs._cxx_toolchain[CxxToolchainInfo].linker_info

    hlibs = dedupe(filter(
        None,
        [
            d.get(HaskellLibraryProvider)
            for d in attr_deps(ctx)
        ],
    ))

    results = make_haskell_link_group(
        ctx,
        label = ctx.label,
        hlibs = hlibs,
        registerer = registerer,
        haskell_toolchain = haskell_toolchain,
        linker_info = linker_info,
        allow_cache_upload = ctx.attrs.allow_cache_upload,
    )
    return results

def haskell_test_impl(ctx: AnalysisContext) -> list[Provider]:
    exe = _haskell_executable(ctx)

    # Add test arguments if provided
    test_cmd = cmd_args(exe.run)
    if ctx.attrs.args:
        test_cmd.add(ctx.attrs.args)

    # Prepare environment variables
    test_env = {}
    if ctx.attrs.env:
        test_env.update(ctx.attrs.env)

    # Setup RE executors based on the `remote_execution` param.
    re_config = get_re_executors_from_props(ctx)

    # The return type changed upstream, so we need to polyfill a back-compatible shim here.
    #
    # TODO: Remove this block once the buck2 version is >=2026-07-31.
    if type(re_config) != "record":
        re_config = struct(
            default_executor = re_config[0],
            executor_overrides = re_config[1],
        )

    run_from_project_root = "buck2_run_from_project_root" in (ctx.attrs.labels or []) or re_config.default_executor != None

    # Add test execution info using the inject_test_run_info function
    providers = [
        DefaultInfo(exe.binary, other_outputs = exe.runtime_files, sub_targets = exe.sub_targets),
    ] + inject_test_run_info(
        ctx,
        ExternalRunnerTestInfo(
            type = "haskell_test",
            command = [test_cmd],
            env = test_env,
            labels = ctx.attrs.labels,
            contacts = ctx.attrs.contacts,
            default_executor = re_config.default_executor,
            executor_overrides = re_config.executor_overrides,
            run_from_project_root = run_from_project_root,
            use_project_relative_paths = re_config.default_executor != None,
        ),
    )

    if exe.index_info:
        providers.append(exe.index_info)

    return providers
