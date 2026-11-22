# Concurrent builder: install and deploy run after a test failure, and deployAtEnd deploys the whole reactor

### Affected version

4.0.0-SNAPSHOT (4.0.x, b5e7863). Java 25 (Corretto 25.0.5.1), Linux.

### Bug description

With `-b concurrent`, a project whose tests fail is still installed and deployed. The build reports BUILD FAILURE, but only after the artifacts have been published. With `-DdeployAtEnd=true` the whole reactor is deployed. It happens with any number of threads, including `-T1`, so it is not a race. The default builder and Maven 3 do not install or deploy the failing project.

Reproducer: https://github.com/stevestorey/maven-concurrent-deploy-repro. It is a parent POM with two jar modules, `lib` and `app`. `app`'s only test sleeps for 5 seconds and then fails. `check.sh` runs `clean deploy` into a file repository under `target-repos/` and counts what was deployed.

```sh
MVN=mvn4 ./check.sh -b concurrent -T1C                     # BROKEN: app deployed
MVN=mvn4 ./check.sh -b concurrent -T1C -DdeployAtEnd=true  # BROKEN: parent, lib and app deployed
MVN=mvn4 ./check.sh -T1C                                   # OK (default builder)
MVN=mvn3 ./check.sh -T1C -DdeployAtEnd=true                # OK: nothing deployed
```

| Command | Deployed |
| --- | --- |
| Maven 4 `-b concurrent -T1C` | parent, `lib` and `app` |
| Maven 4 `-b concurrent -T1C -fae` | parent, `lib` and `app` |
| Maven 4 `-b concurrent -T1` | parent, `lib` and `app` |
| Maven 4 `-b concurrent -T1C -DdeployAtEnd=true` | parent, `lib` and `app` |
| Maven 4 default builder `-T1C` | parent and `lib` |
| Maven 4 default builder `-T1C -DdeployAtEnd=true` | nothing |
| Maven 3.10.2 `-T1C` | parent and `lib` |
| Maven 3.10.2 `-T1C -DdeployAtEnd=true` | nothing |

`clean install -b concurrent -T1C` installs `app` in the same way.

#### Cause

The ordering is right. The build plan lists `test` among the predecessors of `app`'s `deploy` step, and `deploy:deploy` starts only after the test has failed:

```
17:12:55.138 [ERROR] Tests run: 1, Failures: 1, ... <<< FAILURE! -- in example.AppTest
17:12:55.152 [INFO] --- deploy:3.2.0:deploy (default-deploy) @ app ---
17:12:55.158 [INFO] Uploaded to check: .../example/app/1.0-SNAPSHOT/app-1.0-...jar
17:12:55.162 [ERROR] BUILD FAILURE
```

The failure is lost on the way. In the default lifecycle, `test` is nested in `unit-test`, which is nested in `verify`, and `install` and `deploy` both come `after(VERIFY)`. `BuildPlanExecutor.BuildContext.processStep` decides whether to run an `after:*` step only from the status of its `before:*` step and whether any direct predecessor is `FAILED`:

1. `test` throws, so its step becomes `FAILED`, and the exception is stored for the TEARDOWN step.
2. `after:test`: `before:test` ran and a predecessor failed, so it runs for cleanup and is marked `SKIPPED` ("Running after:* step BuildStep[project=example:app, phase=after:test] for cleanup but marking it as SKIPPED because a predecessor failed" in the debug log).
3. `after:unit-test`: `before:unit-test` ran, and its predecessor `after:test` is `SKIPPED`, not `FAILED`. So it runs normally and becomes `EXECUTED`.
4. `after:verify` and then `deploy` see only `EXECUTED` predecessors and run.

The reactor is only halted, or the project blacklisted, when the TEARDOWN step handles the stored exception, which is too late to stop these steps. `deployAtEnd` relies on the last project's `deploy:deploy` running only when the whole build has succeeded, so here it uploads every project.

#### Expected behaviour

A step that follows a failed step, directly or through `after:*` cleanup steps, should not run. In particular `install` and `deploy` must not run for a project whose tests failed, and `deployAtEnd` must not deploy anything from a failed build.

Possible directions:

- treat a predecessor that is `SKIPPED` because of a failure like a `FAILED` one when deciding whether an `after:*` step runs normally, or give such cleanup steps their own status so that the failure propagates;
- check `allPredecessorsExecuted` for `after:*` steps as well, and only run them for cleanup otherwise;
- halt the reactor, or blacklist the project, as soon as a step fails, as the default builder does, rather than in TEARDOWN.

#### Related

With `-b concurrent`, `deploy` also no longer runs `install` (`install` and `deploy` are both `after(VERIFY)` and not ordered after each other), whereas the default builder installs and then deploys. This may be intended by the new lifecycle, but it is a change from Maven 3 behaviour that users of `mvn deploy` will notice.
