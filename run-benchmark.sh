#!/usr/bin/bash

# usage:
# env EMAIL=YourEmail ENGINE=toplingdb[or rocksdb] bash run_benchmark.sh

#set -x
set -e

export FLINK_CONF_DIR=`realpath .`
doc_root=`awk '$1 == "document_root:"{print $2}' config.yaml`
shopt -s extglob
shopt -s globstar
rm -rf "${doc_root}"/benchmark+([0-9])

if [ "$ENGINE" = "toplingdb" ]; then
  #export LD_PRELOAD=libjemalloc.so:librocksdbjni-linux64.so
  export FLINK_TOPLINGDB_CONF=${FLINK_CONF_DIR}/config.yaml
  export SidePluginRepo_DebugLevel=0
  export USE_INTERNAL_UNSAFE=true
  if [ -f ../ftoplingdb/java/target/librocksdbjni-linux64.so ]; then
    export LD_LIBRARY_PATH=`realpath ../ftoplingdb/java/target`:$LD_LIBRARY_PATH
    cp ../ftoplingdb/java/target/{index.html,style.css} ${doc_root}
  elif [ -f frocksdbjni-8.10.2-topling-1.0/librocksdbjni-linux64.so ]; then
    cp frocksdbjni-8.10.2-topling-1.0/{index.html,style.css} ${doc_root}
    if pgrep dcompact_worker; then
      echo dcompact_worker is running, enable dcompact
      sed -i 's/compaction_executor_factory_disabled: dcompact/compaction_executor_factory: dcompact/' config.yaml
    else
      echo dcompact_worker is not running, disable dcompact
      sed -i 's/compaction_executor_factory: dcompact/compaction_executor_factory_disabled: dcompact/' config.yaml
    fi
  else
    echo search librocksdbjni-linux64.so in system path or in frocksdbjni-8.10.2-topling-1.0.jar
    echo if dcompact_worker is online, it will be used, if not, it will fallback to local compaction
    ( # run in a sub shell
      cd ${doc_root}
      if [ -f index.html -a -f style.css ]; then
        echo index.html and style.css exist, skip download
      else
        # download fail is not a fatal error
        wget https://github.com/topling/toplingdb/releases/download/topling-8.10.2-frocks-1.0/index.html \
             https://github.com/topling/toplingdb/releases/download/topling-8.10.2-frocks-1.0/style.css
      fi
    )
  fi
  BENCHMARK_VERSION=0.1-toplingdb
  FLINK_VERSION=2.0-topling-1.0
else
  ENGINE=rocksdb
  BENCHMARK_VERSION=0.1-rocksdb
  FLINK_VERSION=2.0-SNAPSHOT
fi
# comment this mvn line out if it has been done
mvn package -Dproject.version=${BENCHMARK_VERSION} -Dflink.version=${FLINK_VERSION} -DskipTests -T 1C

# sysctl kernel.perf_event_paranoid kernel.kptr_restrict kernel.perf_event_max_stack
# sudo sysctl -w kernel.perf_event_paranoid=-1
# sudo sysctl -w kernel.kptr_restrict=0
# sudo sysctl -w kernel.perf_event_max_stack=128
# echo "Current kernel settings:"
# sysctl kernel.perf_event_paranoid kernel.kptr_restrict kernel.perf_event_max_stack

#LIB_ASYNC_PROFILER=`realpath ../async-profiler-3.0-linux-x64/lib/libasyncProfiler.so`
ASYNC_HOME=`realpath ../async-profiler-4.1-linux-x64`
LIB_ASYNC_PROFILER=${ASYNC_HOME}/lib/libasyncProfiler.so
if [ -f ${LIB_ASYNC_PROFILER} ]; then
  echo "Using async-profiler: ${LIB_ASYNC_PROFILER}"
  PROF_ARGS=(-prof "async:libPath=${LIB_ASYNC_PROFILER};output=jfr;event=cpu;dir=flame_${ENGINE}_$(date +%Y_%m_%d_%H_%M_%S)")
else
  echo "Async-profiler not found, profiling will be skipped."
fi

TIMESTAMP=`date +%Y_%m_%d_%H_%M_%S`
LOG_FILE=${ENGINE}-${TIMESTAMP}.log

args=(
  --add-opens java.base/java.lang=ALL-UNNAMED
  --add-opens java.base/java.nio=ALL-UNNAMED
  --add-opens java.base/jdk.internal.misc=ALL-UNNAMED
  #-Xss1m
  #-Xcheck:jni
  -XX:+UseFastJNIAccessors
  #-XX:JNIDetachReleasesMonitors=false
  -XX:+UnlockDiagnosticVMOptions
  -XX:+DebugNonSafepoints
  -XX:+PreserveFramePointer

  -Dflink.version=${FLINK_VERSION}
  -jar target/benchmarks-${BENCHMARK_VERSION}.jar
  -f 1 -wi  1  -i  1
  -p backendType=ROCKSDB
  #-p backendType=HEAP
  ${PROF_ARGS[@]}
  #"org.apache.flink.state.benchmark.*"
  #org.apache.flink.state.benchmark.ListStateBenchmark
  #org.apache.flink.state.benchmark.ListStateBenchmark.listAppend
  #org.apache.flink.state.benchmark.ListStateBenchmark.listAddAll
  #org.apache.flink.state.benchmark.MapStateBenchmark
  #org.apache.flink.state.benchmark.MapStateBenchmark.mapAdd
  org.apache.flink.state.benchmark.MapStateBenchmark.mapGet
  #org.apache.flink.state.benchmark.MapStateBenchmark.mapPutAll
  #org.apache.flink.state.benchmark.MapStateBenchmark.mapContains
  #org.apache.flink.state.benchmark.ttl.TtlListStateBenchmark.listAppend
)
echo -e '\033[31m###########################################################################\033[0m'
echo -e '\033[31m####\033[0m  StateBackend ToplingDB consol: \033[1;34mhttp://127.0.0.1:2013\033[0m'
echo -e '\033[31m###########################################################################\033[0m'
java ${args[@]} $@ 2>&1 | tee ${LOG_FILE}

function ArrayContains() {
  local seeking=$1; shift
  local in=1
  for element; do
    if [[ $element == $seeking ]]; then
      in=0
      break
    fi
  done
  return $in
}
if ArrayContains "-prof" "${args[@]}"; then
  FLAME_FILE=/mnt/c/osc/flame/flink_${ENGINE}_${TIMESTAMP}-${args[-1]##*.}.html
  jfrconv=${ASYNC_HOME}/bin/jfrconv
  ${jfrconv} -o html flame_${ENGINE}_${TIMESTAMP}/*/*.jfr ${FLAME_FILE}
  mailargs+=(-A ${FLAME_FILE})
fi
if [ -z "${EMAIL}" ]; then
  exit 0
fi
mailargs=(
  ${EMAIL}
  -s ${ENGINE}-flink-benchmarks-${HOSTNAME} # subject
  -A ${LOG_FILE}
  -A config.yaml
)
sed -n '/# Run complete/,$p' ${LOG_FILE} | mail ${mailargs[@]}
