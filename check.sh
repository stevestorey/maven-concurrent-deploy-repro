#!/bin/sh
# Runs "clean deploy" into a file repository under target-repos/ and reports what was deployed.
# app's test always fails, so app must never be deployed, and with -DdeployAtEnd=true nothing
# from the reactor should be. Installs go to a separate local repository under target-repos/,
# which reads through to ~/.m2/repository, so they never touch the real local repository.
# Usage: ./check.sh [extra maven args...]   (MVN defaults to mvn; e.g. MVN=mvn4 ./check.sh -b concurrent -T1C)
set -u
cd "$(dirname "$0")"
MVN=${MVN:-mvn}
REPOS=$PWD/target-repos
rm -rf "$REPOS"
mkdir -p "$REPOS/deploy" "$REPOS/local"
"$MVN" -B clean deploy \
    -DaltDeploymentRepository=check::file://"$REPOS/deploy" \
    -Dmaven.repo.local="$REPOS/local" \
    -Dmaven.repo.local.tail="$HOME/.m2/repository" \
    "$@" > "$REPOS/build.log" 2>&1
status=$?
echo "Maven exit code: $status (expected non-zero: app's test fails)"
for module in deploy-repro-parent lib app; do
    count=$(find "$REPOS/deploy/example/$module" -type f \( -name '*.jar' -o -name '*.pom' \) 2>/dev/null | wc -l)
    echo "deployed $module files: $count"
done
app=$(find "$REPOS/deploy/example/app" -type f -name '*.jar' 2>/dev/null | wc -l)
all=$(find "$REPOS/deploy" -type f \( -name '*.jar' -o -name '*.pom' \) | wc -l)
case " $* " in
    *deployAtEnd=true*) broken=$all; rule="nothing deployed (deployAtEnd)" ;;
    *) broken=$app; rule="app not deployed" ;;
esac
if [ "$status" -eq 0 ]; then
    echo "RESULT: UNEXPECTED - the build passed although app's test fails (see $REPOS/build.log)"
    exit 3
elif [ "$broken" -eq 0 ]; then
    echo "RESULT: OK - $rule"
else
    echo "RESULT: BROKEN - artifacts were deployed although app's test failed (expected: $rule)"
    exit 2
fi
