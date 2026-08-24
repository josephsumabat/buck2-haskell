load("@prelude//cxx:link_groups_types.bzl", "LINK_GROUP_MAP_ATTR")
load("@prelude//decls:common.bzl", "LinkableDepType", "buck")
load("@prelude//decls:native_common.bzl", "native_common")
load("@prelude//decls:re_test_common.bzl", "re_test_common")
load("@prelude//decls/toolchains_common.bzl", "toolchains_common")
load("@prelude//linking:link_info.bzl", "MergedLinkInfo")
load("@prelude//linking:types.bzl", "Linkage")
load(
    ":haskell.bzl",
    "haskell_binary_impl",
    "haskell_library_impl",
    "haskell_link_group_impl",
    "haskell_prebuilt_library_impl",
    "haskell_test_impl",
    "haskell_toolchain_library_impl",
)
load(":ghc_plugin.bzl", "GhcPluginInfo", "ghc_plugin_impl")
load(":haskell_ghci.bzl", "haskell_ghci_global_impl", "haskell_ghci_impl")
load(":haskell_haddock.bzl", "haskell_haddock_impl")
load(":haskell_ide.bzl", "haskell_ide_impl")
load(":library_info.bzl", "HaskellLibraryProvider", "HaskellSourceInfo")
load(":link_info.bzl", "GhcLinkableInfo", "HaskellLinkInfo")
load(":toolchain.bzl", "haskell_toolchain")
load(":worker_config.bzl", "worker_per_configuration")

def _srcs_arg():
    return {
        "srcs": attrs.named_set(attrs.source(), sorted = True, default = [], doc = """
    A list of Haskell sources to be built by this rule. The dictionary option is deprecated.
"""),
    }

def _deps_arg():
    return {
        "deps": attrs.list(attrs.dep(), default = [], doc = """
    Either `haskell_library()` or `prebuilt_haskell_library()` rules
     from which this rules sources import modules or native linkable rules exporting symbols
     this rules sources call into.
"""),
        "srcs_deps": attrs.dict(attrs.source(), attrs.list(attrs.source()), default = {}, doc = """
    Allows to declare dependencies for sources manually, additionally to the dependencies automatically detected.
        """),
    }

def _compiler_flags_arg():
    return {
        "compiler_flags": attrs.list(attrs.arg(), default = [], doc = """
    Flags to pass to the Haskell compiler when compiling this rule's sources.
"""),
    }

def _ghc_rts_flags_arg():
    return {
        "ghc_rts_flags": attrs.list(attrs.string(), default = [], doc = """
    RTS options passed to GHC, changing the behavior of the compiler process, not the resulting binaries like
    `-with-rtsopts` would.
"""),
    }

def _exported_linker_flags_arg():
    return {
        "exported_linker_flags": attrs.list(attrs.string(), default = [], doc = """
    Linker flags used by dependent rules when linking with this library.
"""),
    }

def _worker_attr():
    if worker_per_configuration():
        # One provider per target/exec configuration pair prevents GHC state
        # from leaking while preserving the consumer's selected exec platform.
        return attrs.option(attrs.toolchain_dep(providers = [WorkerInfo]), default = None)
    # This escape hatch saves memory but is unsound when a build compiles
    # Haskell under more than one target configuration.
    return attrs.option(attrs.exec_dep(providers = [WorkerInfo]), default = None)

def _scripts_arg():
    return {
        "_generate_target_metadata": attrs.dep(
            providers = [RunInfo],
            default = "@buck2-haskell//tools:generate_target_metadata",
        ),
        "_ghc_wrapper": attrs.dep(
            providers = [RunInfo],
            default = "@buck2-haskell//tools:ghc_wrapper",
        ),
        "_ghc_pkg_registerer": attrs.dep(
            providers = [RunInfo],
            default = "@buck2-haskell//tools:ghc_pkg_registerer",
        ),
        # Configuration scope is controlled by ghc-worker.per_configuration.
        # FIXME(DUX-5633): Retire workers when their configuration becomes
        # inactive or the build is under memory pressure, perhaps in buck-proxy.
        "_worker": _worker_attr(),
    }

def _external_tools_arg():
    return {
        "external_tools": attrs.list(attrs.dep(providers = [RunInfo]), default = [], doc = """
    External executables called from Haskell compiler during preprocessing or compilation.
"""),
    }

def _srcs_envs_arg():
    return {
        "srcs_envs": attrs.dict(attrs.source(), attrs.dict(attrs.string(), attrs.arg()), default = {}, doc = """
    Individual run-time env for each source compilation.
"""),
    }

def _module_prefix_arg():
    return {
        "module_prefix": attrs.option(attrs.string(), default = None, doc = """
    Module prefix if needed
"""),
    }

def _strip_prefix_arg():
    return {
        "strip_prefix": attrs.list(attrs.string(), default = [], doc = """
    Strip prefix such as src, lib, app or test
"""),
    }

def _extra_libraries_arg():
    return {
        "extra_libraries": attrs.list(attrs.dep(providers = [GhcLinkableInfo, MergedLinkInfo]), default = [], doc = """
    Non-Haskell deps (C/C++ libraries)
"""),
    }

def _incremental_arg():
    return {
        "incremental": attrs.bool(default = True, doc = """
    Use module-level incremental build. Setting it to `False` is mutually
    exclusive with `srcs_plugins`.
"""),
    }

def _allow_cache_upload_arg():
    return {
        "allow_cache_upload": attrs.bool(default = True, doc = """
    Whether to upload artifacts to the cache
"""),
    }

def _resources_arg():
    return {
        "resources": attrs.named_set(attrs.one_of(attrs.dep(), attrs.source()), sorted = True, default = []),
    }

def _plugins_arg():
    return {
        "plugins": attrs.list(attrs.dep(providers = [GhcPluginInfo]), default = [], doc = """
    A list of GHC compiler plugins to enable globally for all modules in this target.
    Each entry must be a `ghc_plugin()` target. Mutually exclusive with `srcs_plugins`.
"""),
        "srcs_plugins": attrs.dict(attrs.source(), attrs.list(attrs.dep(providers = [GhcPluginInfo])), default = {}, doc = """
    Per-module plugin configuration. Maps source files to lists of `ghc_plugin()` targets
    to enable for that specific module. Modules without an entry have no plugins enabled.
    Mutually exclusive with `plugins` and `incremental = False`.
"""),
    }

haskell_common = struct(
    srcs_arg = _srcs_arg,
    deps_arg = _deps_arg,
    compiler_flags_arg = _compiler_flags_arg,
    ghc_rts_flags_arg = _ghc_rts_flags_arg,
    exported_linker_flags_arg = _exported_linker_flags_arg,
    scripts_arg = _scripts_arg,
    external_tools_arg = _external_tools_arg,
    srcs_envs_arg = _srcs_envs_arg,
    module_prefix_arg = _module_prefix_arg,
    strip_prefix_arg = _strip_prefix_arg,
    extra_libraries_arg = _extra_libraries_arg,
    incremental_arg = _incremental_arg,
    allow_cache_upload_arg = _allow_cache_upload_arg,
    resources_arg = _resources_arg,
    plugins_arg = _plugins_arg,
)

_common_binary_attrs = (
    # @unsorted-dict-items
    {
        "main": attrs.option(attrs.string(), default = None, doc = """
            A custom entry point for your Haskell program. It can be simply (module name) or
            (module name).(function name). If not specified, the default is Main.main.
        """),
        "src_main": attrs.option(attrs.source(), default = None, doc = """
            The source file of the Main module. The Main module is special since the file name
            does not have to match with the module name and we can omit 'module Main where'.
        """),
    } |
    native_common.link_group_deps() |
    native_common.link_group_public_deps_label() |
    native_common.link_style() |
    haskell_common.srcs_arg() |
    haskell_common.external_tools_arg() |
    haskell_common.srcs_envs_arg() |
    haskell_common.extra_libraries_arg() |
    haskell_common.compiler_flags_arg() |
    haskell_common.ghc_rts_flags_arg() |
    haskell_common.deps_arg() |
    haskell_common.resources_arg() |
    haskell_common.plugins_arg() |
    haskell_common.scripts_arg() |
    haskell_common.module_prefix_arg() |
    haskell_common.strip_prefix_arg() |
    haskell_common.incremental_arg() |
    haskell_common.allow_cache_upload_arg() |
    {
        "contacts": attrs.list(attrs.string(), default = []),
        "default_host_platform": attrs.option(attrs.configuration_label(), default = None),
        "deps_query": attrs.option(attrs.query(), default = None),
        "enable_profiling": attrs.bool(default = False),
        "ghci_platform_preload_deps": attrs.list(attrs.tuple(attrs.regex(), attrs.set(attrs.dep(), sorted = True)), default = []),
        "ghci_preload_deps": attrs.set(attrs.dep(), sorted = True, default = []),
        "labels": attrs.list(attrs.string(), default = []),
        "licenses": attrs.list(attrs.source(), default = []),
        "link_deps_query_whole": attrs.bool(default = False),
        "linker_flags": attrs.list(attrs.arg(), default = []),
        "platform": attrs.option(attrs.string(), default = None),
        "platform_linker_flags": attrs.list(attrs.tuple(attrs.regex(), attrs.list(attrs.arg())), default = []),
        "allow_worker": attrs.bool(default = True),
        "link_haskell_objects_at_once": attrs.bool(
            default = False,
            doc = """
    Linking all of Haskell modules for the binary target and its in-project
    transitive dependencies as bare objects, not as aggregated libraries.

    In case of many granular target dependencies, say 1000 haskell_library
    deps for a given dynamic executable, the dynamic library loading time
    can be painfully big, so deferring the component object linking until
    the final executable link time is desirable.

    This is in the same vein as haskell_link_group (can be thought as
    haskell_binary counterpart to that). So the flag exempts the objects
    that are already included in haskell_link_group deps of the current
    target binary.
""",
        ),

        # extra needed (from rules_impl.bzl)
        "auto_link_groups": attrs.bool(default = False),
        "link_group_map": LINK_GROUP_MAP_ATTR,
        "template_deps": attrs.list(attrs.exec_dep(providers = [HaskellLibraryProvider]), default = []),
        "_cxx_toolchain": toolchains_common.cxx(),
        "_haskell_toolchain": haskell_toolchain(),
    }
)

haskell_binary = rule(
    impl = haskell_binary_impl,
    attrs = _common_binary_attrs,
)

haskell_test = rule(
    impl = haskell_test_impl,
    doc = """
        A `haskell_test()` rule builds a Haskell binary from the supplied set of Haskell source files
        and dependencies and runs it as a test.

        ```
        # A rule that builds and runs a Haskell test.
        haskell_test(
          name = 'my_test',
          srcs = [
            'MyTest.hs',
          ],
          deps = [
            ':my_library',
          ],
        )

        ```
    """,
    attrs = (
        _common_binary_attrs |
        # @unsorted-dict-items
        {
            "main": attrs.option(attrs.string(), default = None, doc = """
                The main module serving as the entry point into the test binary. If not specified,
                 the compiler default is used.
            """),
            "env": attrs.dict(key = attrs.string(), value = attrs.arg(), sorted = False, default = {}, doc = """
                A map of environment names and values to set when running the test.


                It is also possible to expand references to other rules within the **values** of
                these environment variables, using builtin `string parameter macros`:

                `$(location //path/to:target)`
                Expands to the location of the output of the build rule. This
                 means that you can refer to these without needing to be aware of how
                 Buck is storing data on the disk mid-build.
            """),
            "args": attrs.list(attrs.arg(), default = [], doc = """
                A list of additional arguments to pass to the test when it's run.


                It is also possible to expand references to other rules within these
                arguments, using builtin `string parameter macros`:

                `$(location //path/to:target)`
                Expands to the location of the output of the build rule. This
                 means that you can refer to these without needing to be aware of how
                 Buck is storing data on the disk mid-build.
            """),
        } |
        buck.run_test_separately_arg(run_test_separately_type = attrs.option(attrs.bool(), default = None)) |
        buck.test_rule_timeout_ms() |
        {
            #"_worker": attrs.option(attrs.exec_dep(providers = [WorkerInfo]), default = None),
            "_inject_test_env": attrs.default_only(attrs.dep(default = "prelude//test/tools:inject_test_env")),
        } |
        re_test_common.test_args()
    ),
)

haskell_ghci = rule(
    impl = haskell_ghci_impl,
    attrs = (
        # @unsorted-dict-items
        {
            "compiler_flags": attrs.list(attrs.string(), default = []),
            "contacts": attrs.list(attrs.string(), default = []),
            "default_host_platform": attrs.option(attrs.configuration_label(), default = None),
            "deps": attrs.list(attrs.dep(), default = []),
            "deps_query": attrs.option(attrs.query(), default = None),
            "enable_profiling": attrs.bool(default = False),
            "extra_script_templates": attrs.list(attrs.source(), default = []),
            "ghci_bin_dep": attrs.option(attrs.dep(), default = None),
            "ghci_init": attrs.option(attrs.source(), default = None),
            "labels": attrs.list(attrs.string(), default = []),
            "licenses": attrs.list(attrs.source(), default = []),
            "linker_flags": attrs.list(attrs.arg(), default = []),
            "platform": attrs.option(attrs.string(), default = None),
            "platform_deps": attrs.list(attrs.tuple(attrs.regex(), attrs.set(attrs.dep(), sorted = True)), default = []),
            "platform_preload_deps": attrs.list(attrs.tuple(attrs.regex(), attrs.set(attrs.dep(), sorted = True)), default = []),
            "preload_deps": attrs.set(attrs.dep(), sorted = True, default = []),
            "srcs": attrs.named_set(attrs.source(), sorted = True, default = []),
            "srcs_deps": attrs.dict(attrs.source(), attrs.list(attrs.source()), default = {}),
            "allow_worker": attrs.bool(default = True),

            # extra needed (from rules_impl.bzl)
            "template_deps": attrs.list(attrs.exec_dep(providers = [HaskellLibraryProvider]), default = []),
            "_cxx_toolchain": toolchains_common.cxx(),
            "_haskell_toolchain": haskell_toolchain(),
        } |
        haskell_common.srcs_envs_arg() |
        haskell_common.module_prefix_arg() |
        haskell_common.strip_prefix_arg() |
        haskell_common.ghc_rts_flags_arg() |
        haskell_common.external_tools_arg() |
        haskell_common.incremental_arg() |
        haskell_common.allow_cache_upload_arg() |
        haskell_common.extra_libraries_arg() |
        haskell_common.plugins_arg() |
        haskell_common.scripts_arg()
    ),
)

haskell_ghci_global = rule(
    impl = haskell_ghci_global_impl,
    attrs = (
        # @unsorted-dict-items
        {
            "extra_srcs": attrs.named_set(attrs.source(), sorted = True, default = []),
            "compiler_flags": attrs.list(attrs.string(), default = []),
            "contacts": attrs.list(attrs.string(), default = []),
            "default_host_platform": attrs.option(attrs.configuration_label(), default = None),
            "deps": attrs.list(attrs.dep(providers = [HaskellLinkInfo, HaskellSourceInfo])),
            "enable_profiling": attrs.bool(default = False),
            "bash": attrs.option(attrs.exec_dep(providers = [RunInfo]), default = None),
            "precompiled_deps": attrs.list(attrs.dep(providers = [HaskellLinkInfo]), default = []),
            "extra_script_templates": attrs.list(attrs.source(), default = []),
            "ghci_bin_dep": attrs.option(attrs.dep(), default = None),
            "ghci_init": attrs.option(attrs.source(), default = None),
            "labels": attrs.list(attrs.string(), default = []),
            "licenses": attrs.list(attrs.source(), default = []),
            "linker_flags": attrs.list(attrs.arg(), default = []),
            "platform": attrs.option(attrs.string(), default = None),
            "native_deps": attrs.list(attrs.dep(), default = []),
            "platform_preload_deps": attrs.list(attrs.tuple(attrs.regex(), attrs.set(attrs.dep(), sorted = True)), default = []),
            "preload_deps": attrs.set(attrs.dep(), sorted = True, default = []),
            # List of (package_to_thin, preferred_package) pairs.
            # When two packages export the same module name, thin the less-preferred
            # package to expose only non-conflicting modules, letting the preferred
            # package win for the overlapping names (GHC thinning syntax).
            # Module lists are computed automatically from .conf files at build time.
            # Thinning only applies when preferred_package is also present.
            "thin_packages": attrs.list(
                attrs.tuple(attrs.string(), attrs.string()),
                default = [],
            ),

            # extra needed (from rules_impl.bzl)
            "template_deps": attrs.list(attrs.exec_dep(providers = [HaskellLibraryProvider]), default = []),
            "_compute_exposed_packages": attrs.dep(
                providers = [RunInfo],
                default = "@buck2-haskell//tools:compute_exposed_packages",
            ),
            "_ghc_pkg_registerer": attrs.dep(
                providers = [RunInfo],
                default = "@buck2-haskell//tools:ghc_pkg_registerer",
            ),
            # Configuration scope is controlled by ghc-worker.per_configuration.
            # FIXME(DUX-5633): Retire workers when their configuration becomes
            # inactive or the build is under memory pressure, perhaps in buck-proxy.
            "_worker": _worker_attr(),
            "_cxx_toolchain": toolchains_common.cxx(),
            "_haskell_toolchain": haskell_toolchain(),
        }
    ),
)

haskell_haddock = rule(
    impl = haskell_haddock_impl,
    attrs = (
        # @unsorted-dict-items
        {
            "contacts": attrs.list(attrs.string(), default = []),
            "default_host_platform": attrs.option(attrs.configuration_label(), default = None),
            "deps": attrs.list(attrs.dep(), default = []),
            "deps_query": attrs.option(attrs.query(), default = None),
            "haddock_flags": attrs.list(attrs.arg(), default = []),
            "labels": attrs.list(attrs.string(), default = []),
            "licenses": attrs.list(attrs.source(), default = []),
            "platform": attrs.option(attrs.string(), default = None),
            "platform_deps": attrs.list(attrs.tuple(attrs.regex(), attrs.set(attrs.dep(), sorted = True)), default = []),

            # extra needed (from rules_impl.bzl)
            "_cxx_toolchain": toolchains_common.cxx(),
            "_haskell_toolchain": haskell_toolchain(),
        }
    ),
)

haskell_ide = rule(
    impl = haskell_ide_impl,
    attrs = (
        # @unsorted-dict-items
        {
            "compiler_flags": attrs.list(attrs.string(), default = []),
            "contacts": attrs.list(attrs.string(), default = []),
            "default_host_platform": attrs.option(attrs.configuration_label(), default = None),
            "deps": attrs.list(attrs.dep(), default = []),
            "deps_query": attrs.option(attrs.query(), default = None),
            "extra_script_templates": attrs.list(attrs.source(), default = []),
            "labels": attrs.list(attrs.string(), default = []),
            "licenses": attrs.list(attrs.source(), default = []),
            "link_style": attrs.enum(LinkableDepType),
            "linker_flags": attrs.list(attrs.arg(), default = []),
            "platform": attrs.option(attrs.string(), default = None),
            "platform_deps": attrs.list(attrs.tuple(attrs.regex(), attrs.set(attrs.dep(), sorted = True)), default = []),
            "srcs": attrs.named_set(attrs.source(), sorted = True, default = []),

            # extra needed (from rules_impl.bzl)
            "include_projects": attrs.list(attrs.dep(), default = []),
            "_haskell_toolchain": haskell_toolchain(),
        }
    ),
)

haskell_library = rule(
    impl = haskell_library_impl,
    attrs = (
        # @unsorted-dict-items
        haskell_common.srcs_arg() |
        haskell_common.external_tools_arg() |
        haskell_common.srcs_envs_arg() |
        haskell_common.extra_libraries_arg() |
        haskell_common.compiler_flags_arg() |
        haskell_common.ghc_rts_flags_arg() |
        haskell_common.deps_arg() |
        haskell_common.resources_arg() |
        haskell_common.plugins_arg() |
        haskell_common.scripts_arg() |
        haskell_common.module_prefix_arg() |
        haskell_common.strip_prefix_arg() |
        haskell_common.incremental_arg() |
        haskell_common.allow_cache_upload_arg() |
        native_common.link_whole(link_whole_type = attrs.bool(default = False)) |
        native_common.preferred_linkage(preferred_linkage_type = attrs.enum(Linkage.values())) |
        {
            "contacts": attrs.list(attrs.string(), default = []),
            "default_host_platform": attrs.option(attrs.configuration_label(), default = None),
            "enable_profiling": attrs.bool(default = False),
            "ghci_platform_preload_deps": attrs.list(attrs.tuple(attrs.regex(), attrs.set(attrs.dep(), sorted = True)), default = []),
            "ghci_preload_deps": attrs.set(attrs.dep(), sorted = True, default = []),
            "haddock_flags": attrs.list(attrs.arg(), default = []),
            "labels": attrs.list(attrs.string(), default = []),
            "licenses": attrs.list(attrs.source(), default = []),
            "linker_flags": attrs.list(attrs.arg(), default = []),
            "platform": attrs.option(attrs.string(), default = None),
            "platform_linker_flags": attrs.list(attrs.tuple(attrs.regex(), attrs.list(attrs.arg())), default = []),
            "use_same_package_name": attrs.bool(default = False),
            "allow_worker": attrs.bool(default = True),
            "no_default_info": attrs.bool(default = False),
            "default_output": attrs.enum(["manifest", "library"], default = "manifest"),

            # extra needed (from rules_impl.bzl)
            "preferred_linkage": attrs.enum(Linkage.values(), default = "any"),
            "template_deps": attrs.list(attrs.exec_dep(providers = [HaskellLibraryProvider]), default = []),
            "_cxx_toolchain": toolchains_common.cxx(),
            "_haskell_toolchain": haskell_toolchain(),
        }
    ),
)

haskell_link_group = rule(
    impl = haskell_link_group_impl,
    attrs = haskell_common.allow_cache_upload_arg() | {
        "deps": attrs.list(attrs.dep(), default = [], doc = """
    haskell_library dependencies which will be grouped by this target.
"""),
        "_ghc_pkg_registerer": attrs.dep(
            providers = [RunInfo],
            default = "@buck2-haskell//tools:ghc_pkg_registerer",
        ),

        # extra needed (from rules_impl.bzl)
        "preferred_linkage": attrs.enum(Linkage.values(), default = "any"),
        "template_deps": attrs.list(attrs.exec_dep(providers = [HaskellLibraryProvider]), default = []),
        "_cxx_toolchain": toolchains_common.cxx(),
        "_haskell_toolchain": haskell_toolchain(),
    },
)

haskell_toolchain_library = rule(
    impl = haskell_toolchain_library_impl,
    attrs = {
        # extra needed (from rules_impl.bzl)
        "_haskell_toolchain": haskell_toolchain(),
        "_generate_toolchain_lib_metadata": attrs.dep(
            providers = [RunInfo],
            default = "@buck2-haskell//tools:generate_toolchain_lib_metadata",
        ),
    },
)

haskell_prebuilt_library = rule(
    impl = haskell_prebuilt_library_impl,
    attrs = (
        # @unsorted-dict-items
        {
            "deps": attrs.list(attrs.dep(), default = [], doc = """
                Other `prebuilt_haskell_library()` rules from which this library
                 imports modules.
            """),
            "static_libs": attrs.list(attrs.source(), default = [], doc = """
                The libraries to use when building a statically linked top-level target.
            """),
            "shared_libs": attrs.dict(key = attrs.string(), value = attrs.source(), sorted = False, default = {}, doc = """
                A map of shared library names to shared library paths to use when building a
                 dynamically linked top-level target.
            """),
            "exported_compiler_flags": attrs.list(attrs.string(), default = [], doc = """
                Compiler flags used by dependent rules when compiling with this library.
            """),
        } |
        haskell_common.exported_linker_flags_arg() |
        haskell_common.resources_arg() |
        {
            "exported_post_linker_flags": attrs.list(attrs.arg(anon_target_compatible = True), default = []),
            "contacts": attrs.list(attrs.string(), default = []),
            "cxx_header_dirs": attrs.list(attrs.source(), default = []),
            "db": attrs.source(),
            "default_host_platform": attrs.option(attrs.configuration_label(), default = None),
            "enable_profiling": attrs.bool(default = False),
            "id": attrs.string(default = ""),
            "import_dirs": attrs.list(attrs.source(), default = []),
            "labels": attrs.list(attrs.string(), default = []),
            "licenses": attrs.list(attrs.source(), default = []),
            "pic_profiled_static_libs": attrs.list(attrs.source(), default = []),
            "pic_static_libs": attrs.list(attrs.source(), default = []),
            "profiled_static_libs": attrs.list(attrs.source(), default = []),
            "version": attrs.string(default = ""),
        }
    ),
)

ghc_plugin = rule(
    impl = ghc_plugin_impl,
    doc = """
        A `ghc_plugin` rule defines a plugin from a Haskell library.
        When a `haskell_library`, `haskell_binary`,
        `haskell_test`, or `haskell_ghci` target depends on a plugin via the `plugins`
        attribute, the plugin is enabled globally for all modules in the unit. The
        `srcs_plugins` attribute instead enables plugins on a per-module basis.

        ## Example: global plugin

        ```python
        ghc_plugin(
            name = "my_plugin",
            module = "MyPlugin",
            deps = [":my_plugin_lib"],
        )

        haskell_library(
            name = "my_lib",
            srcs = ["Lib.hs"],
            plugins = [":my_plugin"],
            deps = ["//tests:base"],
        )
        ```

        ## Example: per-module plugin via srcs_plugins

        ```python
        ghc_plugin(
            name = "my_plugin",
            module = "MyPlugin",
            deps = [":my_plugin_lib"],
        )

        haskell_library(
            name = "my_lib",
            srcs = ["A.hs", "B.hs"],
            srcs_plugins = {
                "A.hs": [":my_plugin"],
            },
            deps = ["//tests:base"],
        )
        ```

        ## Example: plugin with tools

        ```python
        ghc_plugin(
            name = "my_plugin",
            module = "MyPlugin",
            deps = [":my_plugin_lib"],
            tools = [":my_tool"],
        )

        haskell_binary(
            name = "my_bin",
            srcs = ["Main.hs"],
            plugins = [":my_plugin"],
            deps = ["//tests:base"],
        )
        ```
    """,
    attrs = {
        "deps": attrs.list(attrs.dep(), default = [], doc = """
            Haskell library or toolchain library dependencies that provide the plugin module.
        """),
        "module": attrs.string(doc = """
            The Haskell module name that provides the plugin (e.g. "MyPlugin").
        """),
        "tools": attrs.list(attrs.dep(providers = [RunInfo]), default = [], doc = """
            External tools that must be available when using the plugin during compilation.
        """),
        "plugin_opts": attrs.list(attrs.string(), default = [], doc = """
            Options to pass to the plugin via `-fplugin-opt`.
        """),
    },
)

haskell_rules = struct(
    ghc_plugin = ghc_plugin,
    haskell_binary = haskell_binary,
    haskell_ghci = haskell_ghci,
    haskell_ghci_global = haskell_ghci_global,
    haskell_haddock = haskell_haddock,
    haskell_ide = haskell_ide,
    haskell_library = haskell_library,
    haskell_link_group = haskell_link_group,
    haskell_prebuilt_library = haskell_prebuilt_library,
    haskell_test = haskell_test,
    haskell_toolchain_library = haskell_toolchain_library,
)
