#!/bin/bash

if [ -z "$type" ]; then
  type=rls
fi

export ROCKSDB_KICK_OUT_OPTIONS_FILE=1
export MULTI_PROCESS=1

# Flink 企业版(包含 topling-rocks 模块) 必须配置该变量
export ZIP_SERVER_OPTIONS="listening_ports=8090:num_threads=320"
export ZipServer_nltBuildThreads=11

#export ToplingZipTable_debugLevel=2

#export LOG_LEVEL=3
#export SidePluginRepo_DebugLevel=3
export CPU_CORE_COUNT=`nproc`

# 本地测试，手工启动 http mock 竞价实例回收检测，http 不可达或 code 404 表示正常，其它表示即将回收
#export TERMINATION_CHECK_URL=http://192.168.31.100:2011

# AWS Spot Instance termination check, http 404 indicate ok, others for going to terminating
#export TERMINATION_CHECK_URL=http://169.254.169.254/latest/meta-data/spot/termination-time

# 阿里云抢占式实例回收检测
#export TERMINATION_CHECK_URL=http://100.100.100.200/latest/meta-data/instance/spot/termination-time

# 腾讯云竞价实例回收检测
#export TERMINATION_CHECK_URL=http://metadata.tencentyun.com/latest/meta-data/spot/termination-time

# 华为云竞价实例回收检测，AWS EC2 兼容 API？
#export TERMINATION_CHECK_URL=http://169.254.169.254/latest/meta-data/spot/termination-time

# 华为云 openstack
#export TERMINATION_CHECK_URL=http://169.254.169.254/openstack/latest/meta_data.json

WORKER_NAME=dcompact-worker-1
#export MAX_PARALLEL_COMPACTIONS=3 # for test queue scheduling
export MAX_PARALLEL_COMPACTIONS=$[$CPU_CORE_COUNT * 4]
export MAX_WAITING_COMPACTIONS=$[$CPU_CORE_COUNT * 5]
export DEL_WORKER_TEMP_DB=0
export ENABLE_HTTP_STOP=1
export WORKER_DB_ROOT=/tmp/infolog/${WORKER_NAME}
export NFS_MOUNT_ROOT=/tmp
export DictZipBlobStore_zipThreads=32
export ToplingZipTable_localTempDir=/dev/shm
rm -f ${ToplingZipTable_localTempDir}/Topling-* # 清理上次运行结束时的遗留垃圾文件

mkdir -p $WORKER_DB_ROOT

# In production, DB_INSTANCE_NAME is from DB's compact request.instance_name,
# and it will be auto mounted by auto-mount daemon
DB_INSTANCE_NAME=`awk '$1 == "instance_name:"{print $2}' config.yaml`
mkdir -p $WORKER_DB_ROOT/${DB_INSTANCE_NAME}

ulimit -n 100000
#sudo sysctl -w vm.max_map_count=1048576

if [ -f ../ftoplingdb/java/target/librocksdbjni-linux64.so ]; then
  JNI_LIB_DIR=`realpath ../ftoplingdb/java/target`
  if [ -f ${JNI_LIB_DIR}/librocksdbjni-linux64.so ]; then
    pushd ${JNI_LIB_DIR}
    ln -sfT librocksdbjni-linux64.so librocksdb.so.8.10
    popd
  fi
else
  if [ ! -f frocksdbjni-8.10.2-topling-1.0/librocksdbjni-linux64.so ]; then
    rm -rf frocksdbjni-8.10.2-topling-1.0*
    mkdir frocksdbjni-8.10.2-topling-1.0
    TOPLING_JAR=${HOME}/.m2/repository/cn/topling/frocksdbjni/8.10.2-topling-1.0/frocksdbjni-8.10.2-topling-1.0.jar
    if [ ! -f ${TOPLING_JAR} ]; then
      echo -e '###########################################################################'
      echo -e '#### It seems you have not installed \033[1;31mtopling flink\033[0m'
      echo -e '###########################################################################'
      echo 'Please run following commands first:
    cd ..
    git clone https://github.com/topling/flink.git
    cd flink

    # other jdk also works ok, such as jdk17/11
    ./mvnw clean install -DskipTests -Djdk21 -Pjava21-target -T 2C

    cd - # back to this directory and continue
  '
      exit 1
      # if wget https://github.com/topling/toplingdb/releases/download/topling-8.10.2-frocks-1.0/frocksdbjni-8.10.2-topling-1.0.jar; then
      #   TOPLING_JAR=frocksdbjni-8.10.2-topling-1.0.jar
      # fi
    fi
    (
      cd frocksdbjni-8.10.2-topling-1.0
      #unzip ${HOME}/.m2/repository/cn/topling/frocksdbjni/8.10.2-topling-1.0/frocksdbjni-8.10.2-topling-1.0.jar
      unzip ${TOPLING_JAR} '*.so' index.html style.css
      cp index.html style.css $WORKER_DB_ROOT
    )
  fi
  JNI_LIB_DIR=frocksdbjni-8.10.2-topling-1.0
fi
export LD_LIBRARY_PATH=${JNI_LIB_DIR}:${LD_LIBRARY_PATH}

if [ -f ./dcompact_worker ]; then
  dcompact=./dcompact_worker
else
  dcompact=`command -v dcompact_worker.exe`
  if [ -z "${dcompact}" ]; then
    wget https://github.com/topling/toplingdb/releases/download/topling-8.10.2-frocks-1.0/dcompact_worker.gz
    gunzip dcompact_worker.gz
    chmod a+x dcompact_worker
    dcompact=./dcompact_worker
  fi
fi

if [ $type = dbg ]; then
  dbg="gdb --args"
fi
#dbg="ldd"

if [ -z "$dbg" ]; then
  (
  sleep 0.3
  echo -e '\033[31m#################################################################\033[0m'
  echo -e '\033[31m###\033[0m  Compaction Service   stat: \033[1;34mhttp://127.0.0.1:8080/stat  \033[0m  \033[31m###\033[0m'
  echo -e '\033[31m###\033[0m  Compaction Service   jobs: \033[1;34mhttp://127.0.0.1:8080/list  \033[0m  \033[31m###\033[0m'
  echo -e '\033[31m###\033[0m  Compaction Service health: \033[1;34mhttp://127.0.0.1:8080/health\033[0m  \033[31m###\033[0m'
  echo -e '\033[31m#################################################################\033[0m'
  ) &
fi
$dbg ${dcompact} \
    -D listening_ports=8080 -D num_threads=50 \
    -D document_root=$WORKER_DB_ROOT #>> $WORKER_DB_ROOT/stdout 2>> $WORKER_DB_ROOT/stderr
