# qbx_core server test harness

Regression tests for the fixes in the `fix/core-hardening` pull request. The harness runs the **unmodified** qbx_core server files under stock Lua 5.4.

- `tests/cfx.lua` translates the CfxLua syntax qbx_core uses (`+=`, `?.`, backtick hashes) to plain Lua 5.4.
- `tests/env.lua` is a fake FiveM server runtime: natives, events, exports, state bags, ox_lib and oxmysql. Its cooperative scheduler makes `Wait` and every `MySQL.*.await` yield like a real database round trip, which is what exposes the login races.
- `tests/boot.lua` loads the server scripts in fxmanifest order.
- `tests/run.lua` holds the tests: 17 bug reproductions and 8 non-regression checks.

## Run

```sh
git clone https://github.com/Qbox-project/qbx_core && cd qbx_core
git fetch https://github.com/ZsombiiHUN/qbx_core qbx-tests && git worktree add ../qbx-tests FETCH_HEAD

lua5.4 ../qbx-tests/tests/run.lua .            # v1.24.1: 17 bug tests fail, 8 regression tests pass
git fetch https://github.com/ZsombiiHUN/qbx_core fix/core-hardening && git checkout FETCH_HEAD
lua5.4 ../qbx-tests/tests/run.lua .            # with the fixes: 25 passed, 0 failed
```

Run a subset of tests with a name filter, e.g. `lua5.4 ../qbx-tests/tests/run.lua . "vehicle persistence"`.
