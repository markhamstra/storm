#!/bin/bash

if [ "$#" -ne 1 ]; then
  cat >&2 <<EOT
Usage: ${0##/} <action> [<options>]

where <action> is

  install - build and install storm and storm-lib to the local Maven repository
  deploy - build and deploy storm and storm-lib to Maven repository

EOT
  exit 1
fi

action=$1
if [ "$action" != "install" ] && [ "$action" != "deploy" ]; then
  echo "Invalid action: $action" >&2
  exit 1
fi

if [ "$action" == "deploy" ]; then
  if [ -z "$MAVEN_REPOSITORY_ID" ] ||
     [ -z "$MAVEN_REPOSITORY_URL" ]; then
    echo "MAVEN_REPOSITORY_ID and MAVEN_REPOSITORY_URL must be set" >&2
    exit 1
  fi
fi

set -e -u -o pipefail -x
cd $(dirname $0)/..

build() {
  mkdir -p target

  version=`head -1 project.clj | awk '{print $3}' | sed -e 's/\"//' | sed -e 's/\"//'`

  # Build storm jar and pom
  if [ ! -f target/storm-$version.jar ] ||
     [ ! -f target/storm-$version.pom ];
  then
    rm -rf classes
    rm -f *.jar
    rm -f *.xml

    lein jar
    lein pom

    mv -f storm-$version.jar target
    cp -f pom.xml target/storm-$version.pom
  fi
  set +x
  echo "storm jar/pom build complete"
  set -x

  # Build storm-lib jar and pom
  if [ ! -f target/storm-lib-$version.jar ] ||
     [ ! -f target/storm-lib-$version.pom ];
  then
    rm -f *.jar
    rm -rf classes
    rm -f conf/log4j.properties

    lein jar
    lein pom
    mv pom.xml old-pom.xml
    sed 's/artifactId\>storm/artifactId\>storm-lib/g' old-pom.xml > pom.xml

    mv -f storm-$version.jar target/storm-lib-$version.jar
    mv -f pom.xml target/storm-lib-$version.pom

    rm -f *xml
    rm -f *jar
  fi
  set +x
  echo "storm-lib jar/pom build complete"
  set -x

  git checkout conf/log4j.properties
}

time build

deployment_error=""
for artifact_id in storm storm-lib; do
  path_prefix=target/$artifact_id-$version
  for f in $path_prefix.jar $path_prefix.pom; do
    if [ ! -f "$f" ]; then
      echo "File $f not found" >&2
      exit 1
    fi
  done
  set +x
  mvn_common_args="-Dfile=$path_prefix.jar \
                   -DpomFile=$path_prefix.pom \
                   -DgroupId=storm \
                   -DartifactId=$artifact_id \
                   -Dversion=$version \
                   -DgeneratePom=false \
                   -Dpackaging=jar"
  mvn_common_args=$( echo $mvn_common_args )
  set -x
  case "$action" in
    install)
      mvn install:install-file $mvn_common_args ;;
    deploy)
      set +e  # Ignore failures to deploy
      mvn deploy:deploy-file \
        $mvn_common_args \
        -DrepositoryId=$MAVEN_REPOSITORY_ID \
        -Durl=$MAVEN_REPOSITORY_URL
      if [ $? != 0 ]; then
        deployment_error=1
      fi
      set -e
      ;;
    *)
      set +x
      echo "Invalid action: $action" >&2
      exit 1
  esac
done

if [ "$deployment_error" ]; then
  echo "Deployment failed" >&2
  exit 1
fi
