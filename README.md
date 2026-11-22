# Maven 4 concurrent builder: install and deploy run after a test failure

With `-b concurrent`, a project whose tests fail is still installed and deployed. The build
reports BUILD FAILURE, but by then the artifacts have been published. `-DdeployAtEnd=true` makes
it worse: the whole reactor is deployed. This happens with any number of threads, including
`-T1`.

## Reproduce

```sh
git clone https://github.com/stevestorey/maven-concurrent-deploy-repro.git
cd maven-concurrent-deploy-repro
MVN=/path/to/maven-4/bin/mvn ./check.sh -b concurrent -T1C                     # RESULT: BROKEN
MVN=/path/to/maven-4/bin/mvn ./check.sh -b concurrent -T1C -DdeployAtEnd=true  # RESULT: BROKEN
MVN=/path/to/maven-4/bin/mvn ./check.sh -T1C                                   # RESULT: OK (default builder)
MVN=/path/to/maven-3/bin/mvn ./check.sh -T1C -DdeployAtEnd=true                # RESULT: OK
```

The reactor is a parent POM and two jar modules, `lib` and `app`. `app`'s only test sleeps for
5 seconds and then fails. `check.sh` runs `clean deploy` into a file repository under
`target-repos/` and counts what was deployed. Installs go to a separate local repository under
`target-repos/` that reads through to `~/.m2/repository`, so the real local repository is never
written to. `app` must not be deployed, and with `-DdeployAtEnd=true` nothing should be.

Tested with Maven 4.0.0-SNAPSHOT (4.0.x, b5e7863) and Maven 3.10.2, Java 25.

| Command | Result | Deployed |
| --- | --- | --- |
| Maven 4 `-b concurrent -T1C` | BUILD FAILURE | parent, `lib` and `app` |
| Maven 4 `-b concurrent -T1C -fae` | BUILD FAILURE | parent, `lib` and `app` |
| Maven 4 `-b concurrent -T1` | BUILD FAILURE | parent, `lib` and `app` |
| Maven 4 `-b concurrent -T1C -DdeployAtEnd=true` | BUILD FAILURE | parent, `lib` and `app` |
| Maven 4 default builder `-T1C` | BUILD FAILURE | parent and `lib` |
| Maven 4 default builder `-T1C -DdeployAtEnd=true` | BUILD FAILURE | nothing |
| Maven 3 `-T1C` | BUILD FAILURE | parent and `lib` |
| Maven 3 `-T1C -DdeployAtEnd=true` | BUILD FAILURE | nothing |

`clean install -b concurrent -T1C` installs `app` in the same way.

## Cause

The ordering is right. The build plan (`-X`, `PROJECT BUILD PLAN`) lists `test` among the
predecessors of `app`'s `deploy` step, and `deploy:deploy` starts only after the test has failed:

```
17:12:55.138 [ERROR] Tests run: 1, Failures: 1, ... <<< FAILURE! -- in example.AppTest
17:12:55.152 [INFO] --- deploy:3.2.0:deploy (default-deploy) @ app ---
17:12:55.158 [INFO] Uploaded to check: .../example/app/1.0-SNAPSHOT/app-1.0-...jar
17:12:55.162 [ERROR] BUILD FAILURE
```

The failure is lost on the way. In the Maven 4 lifecycle, `test` is nested in `unit-test`, which
is nested in `verify`, and `install` and `deploy` both come `after(VERIFY)`.
`BuildPlanExecutor.BuildContext.processStep` decides whether to run an `after:*` step only from
the status of its `before:*` step and whether any direct predecessor is `FAILED`:

1. `test` throws, so its step becomes `FAILED`. The exception is kept for the TEARDOWN step.
2. `after:test`: `before:test` ran and a predecessor failed, so it runs for cleanup and is
   marked `SKIPPED`. The debug log shows "Running after:* step BuildStep[project=example:app,
   phase=after:test] for cleanup but marking it as SKIPPED because a predecessor failed".
3. `after:unit-test`: `before:unit-test` ran, and its predecessor `after:test` is `SKIPPED`,
   not `FAILED`. So it runs normally and becomes `EXECUTED`.
4. `after:verify` and then `deploy` see only `EXECUTED` predecessors and run.

The reactor is only halted, or the project blacklisted, when the TEARDOWN step handles the stored
exception, which is too late to stop these steps. `deployAtEnd` relies on the last project's
`deploy:deploy` running only when the whole build has succeeded, so it uploads the whole reactor.
