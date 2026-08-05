# Loaded by the generated `bench/BUCK` — see `alias` and `buckfile_imports` in
# ../reindeer.toml.

def omit_alias(name, actual, **kwargs):
    """
    Drop reindeer's unversioned public aliases instead of registering them.

    Reindeer gives every first-order dependency of every workspace member an
    unversioned alias — `//:anyhow` for `:anyhow-1` — so that hand-written BUCK
    files can name a crate without pinning its version. There are no
    hand-written BUCK files here: every target in the generated file names its
    dependencies by their versioned target, so all 124 aliases are unreferenced.

    Unreferenced, but not free. Both of the things that go wrong with them go
    away with the aliases themselves:

    - **Collisions.** The alias name is the crate name, which reindeer assumes
      identifies one version — true of the third-party directory it is normally
      pointed at, false of a real workspace. Two of rust-analyzer's members want
      different majors of `hashbrown`, and `ungrammar` resolves both from
      crates.io and from the in-tree `lib/ungrammar`. buck2 rejects a duplicate
      target outright.

    - **Compatibility.** An alias to a target that is `target_compatible_with`
      some other OS is itself incompatible, but reindeer's plain `alias` carries
      no compatibility attribute of its own, so it fails analysis rather than
      being skipped. See fixups/inotify/fixups.toml.
    """
    _ = (name, actual, kwargs)  # @unused
