# ============================================================
# 阶段1：编译 rocketmq-connect 及插件
# ============================================================
FROM maven:3.9.9-eclipse-temurin-17 AS builder

WORKDIR /build

# 克隆 rocketmq-connect 源码
RUN git clone --depth 1 -b master https://github.com/apache/rocketmq-connect.git .

# 配置 Maven 阿里云镜像加速（国内必备）
RUN mkdir -p /root/.m2 && \
    echo '<?xml version="1.0" encoding="UTF-8"?><settings><mirrors><mirror><id>aliyun</id><mirrorOf>central</mirrorOf><name>Aliyun Maven</name><url>https://maven.aliyun.com/repository/public</url></mirror></mirrors></settings>' > /root/.m2/settings.xml

# 编译 Connect Runtime（跳过测试）
RUN mvn -Prelease-connect -Dmaven.test.skip=true clean install -U --no-transfer-progress

# 编译 Debezium 父模块（kafka-connect-adaptor + debezium-core，PostgreSQL 插件依赖这些）
WORKDIR /build/connectors/rocketmq-connect-debezium
RUN mvn clean install -Dmaven.test.skip=true -Dcheckstyle.skip=true -pl rocketmq-connect-debezium-core,kafka-connect-adaptor -am --no-transfer-progress

# 编译 Debezium PostgreSQL 插件
WORKDIR /build/connectors/rocketmq-connect-debezium/rocketmq-connect-debezium-postgresql
RUN mvn clean package -Dmaven.test.skip=true --no-transfer-progress

# 编译 JDBC 插件
WORKDIR /build/connectors/rocketmq-connect-jdbc
RUN mvn clean package -Dmaven.test.skip=true --no-transfer-progress

# ============================================================
# 阶段2：运行镜像（复用本地已有镜像，避免从 Docker Hub 拉取）
# ============================================================
FROM maven:3.9.9-eclipse-temurin-17

WORKDIR /opt/rocketmq-connect

# 创建插件目录
RUN mkdir -p /usr/local/connector-plugins

# 从构建阶段复制 Connect Runtime
COPY --from=builder /build/distribution/target/rocketmq-connect-0.0.1-SNAPSHOT/rocketmq-connect-0.0.1-SNAPSHOT/ ./

# 复制 Debezium PostgreSQL 插件 jar
COPY --from=builder /build/connectors/rocketmq-connect-debezium/rocketmq-connect-debezium-postgresql/target/rocketmq-connect-debezium-postgresql-*-jar-with-dependencies.jar /usr/local/connector-plugins/

# 复制 JDBC 插件（目录包，非单 jar）
COPY --from=builder /build/connectors/rocketmq-connect-jdbc/target/rocketmq-connect-jdbc-*-SNAPSHOT-package/share/java/rocketmq-connect-jdbc /usr/local/connector-plugins/rocketmq-connect-jdbc

# 复制配置文件
COPY connect-standalone.conf conf/connect-standalone.conf
