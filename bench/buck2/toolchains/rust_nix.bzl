# A rust toolchain named by store path instead of by `$PATH`.
#
# This rule exists because the prelude gives no other way to do it. Every other
# toolchain this bench needs takes its tools as plain strings and so can be
# pointed at the store directly — `system_cxx_toolchain` has `compiler`,
# `linker` and `archiver`, `system_python_bootstrap_toolchain` has
# `interpreter`. `system_rust_toolchain` alone hardcodes
# `RunInfo(args = ["rustc"])` in its implementation and exposes no attribute to
# override it, so the only way to name a different compiler is to construct
# `RustToolchainInfo` here.
#
# It is otherwise the prelude's rule with three lines changed. Fields not named
# below keep their provider defaults; `panic_runtime` is the one field with no
# default, and `unwind` is what the flags in `BUCK` already ask for.

load("@prelude//rust:rust_toolchain.bzl", "PanicRuntime", "RustToolchainInfo")

def _nix_rust_toolchain_impl(ctx):
    return [
        DefaultInfo(),
        RustToolchainInfo(
            compiler = RunInfo(args = [ctx.attrs.rustc]),
            rustdoc = RunInfo(args = [ctx.attrs.rustdoc]),
            clippy_driver = RunInfo(args = [ctx.attrs.clippy_driver]),
            default_edition = ctx.attrs.default_edition,
            panic_runtime = PanicRuntime("unwind"),
            rustc_flags = ctx.attrs.rustc_flags,
            rustc_target_triple = ctx.attrs.rustc_target_triple,
        ),
    ]

nix_rust_toolchain = rule(
    impl = _nix_rust_toolchain_impl,
    attrs = {
        "rustc": attrs.string(),
        "rustdoc": attrs.string(),
        # Not optional, despite nothing here asking for a lint run. The prelude
        # builds a clippy wrapper in `compile_context` for every rust rule
        # before it knows whether a clippy subtarget was requested, so leaving
        # this unset fails analysis of an ordinary binary.
        "clippy_driver": attrs.string(),
        "default_edition": attrs.option(attrs.string(), default = None),
        "rustc_flags": attrs.list(attrs.arg(), default = []),
        # The prelude's equivalent defaults this to a `select()` over os and
        # cpu. That select is private to `prelude//toolchains:rust.bzl` and so
        # cannot be loaded, and reproducing it here would be twenty-five lines
        # standing in for a value this bench only ever resolves one way: it
        # measures one machine against itself.
        "rustc_target_triple": attrs.string(),
    },
    is_toolchain_rule = True,
)
