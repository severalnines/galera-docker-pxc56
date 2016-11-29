FROM centos:7
MAINTAINER Severalnines <ashraf@severalnines.com>

RUN rpmkeys --import https://www.percona.com/downloads/RPM-GPG-KEY-percona

ARG PXC_VERSION
ENV PXC_VERSION ${PS_VERSION:-5.6.32}

RUN yum install -y http://www.percona.com/downloads/percona-release/redhat/0.1-3/percona-release-0.1-3.noarch.rpm
RUN yum install -y which Percona-XtraDB-Cluster-56-${PXC_VERSION} 

ADD node.cnf /etc/my.cnf
VOLUME /var/lib/mysql

COPY entrypoint.sh /entrypoint.sh
COPY report_status.sh /report_status.sh
COPY jq /usr/bin/jq
RUN chmod a+x /usr/bin/jq

ENTRYPOINT ["/entrypoint.sh"]

EXPOSE 3306 4567 4568
ONBUILD RUN yum update -y

CMD [""]
