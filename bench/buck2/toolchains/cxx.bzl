# The C toolchain, as a `CxxToolsInfo` naming binaries out of a Nix store path.
#
# This is buck2.nix's job, and buck2.nix has a rule for it — `nix_cxx_toolchain`
# — which this deliberately does not use. That rule builds `CxxToolchainInfo` by
# hand, field by field, and the prelude bundled with buck2 2026-07-14 has since
# made `runtime_dependency_handling` a required field of it, so the rule fails
# analysis before it ever runs a compiler. buck2.nix's last commit is
# 2025-08-29; its own CI pins an equally old nixpkgs, so the breakage is not
# visible from there. Its `nix_rust_toolchain` and
# `nix_python_bootstrap_toolchain` are unaffected and are used as-is.
#
# The prelude has a seam for exactly this, one level below the toolchain:
# `cxx_tools_info_toolchain` takes a dependency providing `CxxToolsInfo` — just
# the tool binaries and their flavours — and derives the whole
# `CxxToolchainInfo` itself. So the local part is only the part that is actually
# specific to Nix, and every field neither of us names stays the prelude's
# problem, including the next one it makes required.
#
# `prelude//toolchains/cxx/clang:path_clang_tools` is the same rule against
# `$PATH`, and is what `system_cxx_toolchain` used before this. The difference
# between them is the entire point: strings there, store paths here.

load("@prelude//cxx:cxx_toolchain_types.bzl", "LinkerType")
load("@prelude//toolchains:cxx.bzl", "CxxToolsInfo")

def _nix_cxx_tools_impl(ctx: AnalysisContext) -> list[Provider]:
    # Sub-targets of the `nix_cc` flake package: `cc` and `c++` are wrappers
    # carrying cc-wrapper's `$NIX_*` variables, `ar` a plain symlink. See the
    # `cxx` derivation in ../flake.nix.
    tools = ctx.attrs.nix_cc[DefaultInfo].sub_targets
    cc = tools["cc"][RunInfo]
    cxx = tools["c++"][RunInfo]

    return [
        DefaultInfo(),
        CxxToolsInfo(
            compiler = cc,
            compiler_type = ctx.attrs.compiler_type,
            cxx_compiler = cxx,
            asm_compiler = cc,
            asm_compiler_type = ctx.attrs.compiler_type,
            rc_compiler = None,
            cvtres_compiler = None,
            archiver = tools["ar"][RunInfo],
            archiver_type = "gnu",
            # Rust binaries are linked by the C++ driver, not by `ld` directly,
            # which is what lets cc-wrapper's `$NIX_LDFLAGS` apply to them.
            linker = cxx,
            linker_type = LinkerType(ctx.attrs.linker_type),
        ),
    ]

nix_cxx_tools = rule(
    impl = _nix_cxx_tools_impl,
    attrs = {
        # Which compiler nixpkgs' `stdenv` actually is on the host being built
        # for. The prelude reads this to pick a header-dependency mode as well,
        # so it is not only cosmetic.
        "compiler_type": attrs.string(default = select({
            "DEFAULT": "gcc",
            "config//os:macos": "clang",
        })),
        "linker_type": attrs.string(default = select({
            "DEFAULT": "gnu",
            "config//os:macos": "darwin",
        })),
        "nix_cc": attrs.exec_dep(),
    },
)
