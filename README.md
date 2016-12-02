# Percona XtraDB Cluster 5.6 Docker Image #

## Table of Contents ##

1. [Overview](#overview)
2. [Requirement](#requirement)
3. [Image Description](#image-description)
4. [Run Container](#run-container)
5. [Build Image](#build-image)
6. [Discovery Service](#discovery-service)
8. [Limitations](#limitations)
9. [Development](#development)

## Overview ##

Derived from [perconalab/percona-xtradb-cluster](https://github.com/Percona-Lab/percona-xtradb-cluster-docker), the image supports running Percona XtraDB Cluster 5.6 with Docker orchestration tool like Docker Engine Swarm Mode and Kubernetes and requires etcd to operate correctly. It can also run on a standalone environment. The image supports work in Docker Network, including overlay networks, so that you can install Percona XtraDB Cluster nodes on different boxes.

Example deployment at Severalnines' [blog post](http://www.severalnines.com/blog).

## Requirement ##

A healthy etcd cluster. Please refer to Severalnines' [blog post](http://www.severalnines.com/blog) for details.

## Image Description ##

To pull the image, simply:
```bash
$ docker pull severalnines/pxc56
```

The image consists of Percona XtraDB Cluster 5.6 and all of its components:
* MySQL client package.
* Percona Xtrabackup.
* jq - Lightweight and flexible command-line JSON processor.
* report_status.sh - report Galera status to etcd every `TTL`.

## Run Container ##

The Docker image accepts the following parameters:

* One of `MYSQL_ROOT_PASSWORD` must be defined.
* The image will create the user `xtrabackup@localhost` for the XtraBackup SST method. If you want to use a password for the `xtrabackup` user, set `XTRABACKUP_PASSWORD`. 
* If you want to use the discovery service (right now only `etcd` is supported), set the address (ip:port format) to `DISCOVERY_SERVICE`. It can accept multiple addresses separated by a comma. The image will automatically find a running cluser by `CLUSTER_NAME` and join to the existing cluster (or start a new one).
* If you want to start without the discovery service, use the `CLUSTER_JOIN` variable. Empty variables will start a new cluster. To join an existing cluster, set `CLUSTER_JOIN` to the list of IP addresses running cluster nodes.
* `TTL` by default is 30 seconds. Container will report every `TTL - 2` seconds when it's alive (wsrep_cluster_state\_comment=Synced) via `report_status.sh`. If a container is down, it will no longer send an update to etcd thus the key (wsrep_cluster_state_comment) is removed after expiration. This simply indicates that the registered node is no longer synced with the cluster and it will be skipped when constructing the Galera communication address.

Minimum of 3 containers is recommended for high availability. Running standalone is also possible with standard "docker run" command as shown further down.

### Docker Engine Swarm Mode ###

#### Epheremal Storage ####

Assuming:

* etcd cluster is running on 192.168.55.111:2379, 192.168.55.112:2379 and 192.168.55.113:2379.
* Created an overlay network called ``galera-net``.

Then, to run a three-node Percona XtraDB Cluster on Docker Swarm mode (with epheremal storage):

```bash
$ docker service create \
--name mysql-galera \
--replicas 3 \
-p 3306:3306 \
--network galera-net \
--env MYSQL_ROOT_PASSWORD=mypassword \
--env DISCOVERY_SERVICE=192.168.55.111:2379,192.168.55.112:2379,192.168.55.113:2379 \
--env XTRABACKUP_PASSWORD=mypassword \
--env CLUSTER_NAME=my_wsrep_cluster \
severalnines/pxc56
```

#### Persistent Storage ####

Assuming:

* Directory ``/mnt/docker/mysql`` is exist on all Docker host for persistent storage.
* etcd cluster is running on 192.168.55.111:2379, 192.168.55.112:2379 and 192.168.55.113:2379.
* Created an overlay network called ``galera-net``.

Then, to run a three-node Percona XtraDB Cluster on Docker Swarm mode (with persistent storage):

```bash
$ docker service create \
--name mysql-galera \
--replicas 3 \
-p 3306:3306 \
--network galera-net \
--mount type=volume,source=galera-vol,destination=/var/lib/mysql \
--env MYSQL_ROOT_PASSWORD=mypassword \
--env DISCOVERY_SERVICE=192.168.55.111:2379,192.168.55.112:2379,192.168.55.113:2379 \
--env XTRABACKUP_PASSWORD=mypassword \
--env CLUSTER_NAME=my_wsrep_cluster \
severalnines/pxc56
```

#### Custom my.cnf ####

Assuming:

* Directory ``/mnt/docker/mysql-config`` is exist on all Docker host for data volume mapping. All custom my.cnf should be located under this directory.
* etcd cluster is running on 192.168.55.111:2379, 192.168.55.112:2379 and 192.168.55.113:2379.
* Created an overlay network called ``galera-net``.

Then, to run a three-node Percona XtraDB Cluster on Docker Swarm mode:

$ docker service create \
--name mysql-galera \
--replicas 3 \
-p 3306:3306 \
--network galera-net \
--mount type=volume,source=galera-vol,destination=/var/lib/mysql \
--mount type=bind,src=/mnt/docker/mysql-config,dst=/etc/my.cnf.d \
--env MYSQL_ROOT_PASSWORD=mypassword \
--env DISCOVERY_SERVICE=192.168.55.111:2379,192.168.55.112:2379,192.168.55.113:2379 \
--env XTRABACKUP_PASSWORD=mypassword \
--env CLUSTER_NAME=my_wsrep_cluster \
severalnines/pxc56

Verify with:

```
$ docker service ps mysql-galera
```

Application should connect to the service via virtual IP address assigned by Docker Swarm mode:

```bash
$ docker service inspect mysql-galera -f "{{ .Endpoint.VirtualIPs }}"
```

### Kubernetes ###

Coming soon.

### Without Orchestration Tool ###

To run a standalone Galera node, the command would be:

```bash
$ docker run -d \
-p 3306 \
--name=galera \
-e MYSQL_ROOT_PASSWORD=mypassword \
-e DISCOVERY_SERVICE=192.168.55.111:2379,192.168.55.112:2379,192.168.55.113:2379 \
-e CLUSTER_NAME=my_wsrep_cluster \
-e XTRABACKUP_PASSWORD=mypassword \
severalnines/pxc56
```

With some iterations, you can create a three-node Galera cluster, as shown in the following example:

```bash
$ for i in 1 2 3; 
do \
docker run -d \
-p 3306 \
--name=galera${i} \
-e MYSQL_ROOT_PASSWORD=mypassword \
-e DISCOVERY_SERVICE=192.168.55.111:2379,192.168.55.112:2379,192.168.55.113:2379 \
-e CLUSTER_NAME=my_wsrep_cluster \
-e XTRABACKUP_PASSWORD=mypassword \
severalnines/pxc56;
done
```

Verify with:

```bash
$ docker ps
```

## Build Image ##

To build Docker image, download the Docker related files available at [our Github repository](https://github.com/severalnines/galera-docker-pxc56):

```bash
$ git clone https://github.com/severalnines/galera-docker-pxc56
$ cd galera-docker-pxc56
$ docker build -t --rm=true severalnines/pxc56 .
```

Verify with:
```bash
$ docker images
```

## Discovery Service ##

All nodes should report to etcd periodically with an expiring key. The default `TTL` value is 30 seconds. Container will report every `TTL - 2` seconds when it's alive (wsrep_cluster_state\_comment=Synced) via `report_status.sh`. If a container is down, it will no longer send an update to etcd thus the key (wsrep_cluster_state_comment) is removed after expiration. This simply indicates that the registered node is no longer synced with the cluster and it will be skipped when constructing the Galera communication address.

To check the list of running nodes via etcd, run the following (assuming CLUSTER_NAME="my_wsrep_cluster"):
```javascript
$ curl -s "http://192.168.55.111:2379/v2/keys/galera/my_wsrep_cluster?recursive=true" | python -m json.tool
{
    "action": "get",
    "node": {
        "createdIndex": 10049,
        "dir": true,
        "key": "/galera/my_wsrep_cluster",
        "modifiedIndex": 10049,
        "nodes": [
            {
                "createdIndex": 10067,
                "dir": true,
                "key": "/galera/my_wsrep_cluster/10.255.0.6",
                "modifiedIndex": 10067,
                "nodes": [
                    {
                        "createdIndex": 10075,
                        "expiration": "2016-11-29T10:55:35.37622336Z",
                        "key": "/galera/my_wsrep_cluster/10.255.0.6/wsrep_last_committed",
                        "modifiedIndex": 10075,
                        "ttl": 10,
                        "value": "0"
                    },
                    {
                        "createdIndex": 10073,
                        "expiration": "2016-11-29T10:55:34.788170259Z",
                        "key": "/galera/my_wsrep_cluster/10.255.0.6/wsrep_local_state_comment",
                        "modifiedIndex": 10073,
                        "ttl": 10,
                        "value": "Synced"
                    }
                ]
            },
            {
                "createdIndex": 10049,
                "dir": true,
                "key": "/galera/my_wsrep_cluster/10.255.0.7",
                "modifiedIndex": 10049,
                "nodes": [
                    {
                        "createdIndex": 10049,
                        "key": "/galera/my_wsrep_cluster/10.255.0.7/ipaddress",
                        "modifiedIndex": 10049,
                        "value": "10.255.0.7"
                    },
                    {
                        "createdIndex": 10074,
                        "expiration": "2016-11-29T10:55:35.218496083Z",
                        "key": "/galera/my_wsrep_cluster/10.255.0.7/wsrep_last_committed",
                        "modifiedIndex": 10074,
                        "ttl": 10,
                        "value": "0"
                    },
                    {
                        "createdIndex": 10072,
                        "expiration": "2016-11-29T10:55:34.650574629Z",
                        "key": "/galera/my_wsrep_cluster/10.255.0.7/wsrep_local_state_comment",
                        "modifiedIndex": 10072,
                        "ttl": 10,
                        "value": "Synced"
                    }
                ]
            },
            {
                "createdIndex": 10070,
                "dir": true,
                "key": "/galera/my_wsrep_cluster/10.255.0.8",
                "modifiedIndex": 10070,
                "nodes": [
                    {
                        "createdIndex": 10077,
                        "expiration": "2016-11-29T10:55:39.681757381Z",
                        "key": "/galera/my_wsrep_cluster/10.255.0.8/wsrep_last_committed",
                        "modifiedIndex": 10077,
                        "ttl": 15,
                        "value": "0"
                    },
                    {
                        "createdIndex": 10076,
                        "expiration": "2016-11-29T10:55:38.638268679Z",
                        "key": "/galera/my_wsrep_cluster/10.255.0.8/wsrep_local_state_comment",
                        "modifiedIndex": 10076,
                        "ttl": 14,
                        "value": "Synced"
                    }
                ]
            }
        ]
    }
}
```


## Limitations ##

* The image are tested and built using Docker version 1.12.3, build 6b644ec on CentOS 7.1.
* Currently there is no automatic cleanup for the discovery service registry. You can remove all entries using:
```bash
curl http://192.168.55.111:2379/v2/keys/galera/my_wsrep_cluster?recursive=true -XDELETE
```

Or using etcdctl command:
```bash
etcdctl rm /galera/my_wsrep_cluster --recursive
```

## Development ##

Please report bugs, improvements or suggestions by creating issue in [Github](https://github.com/severalnines/galera-docker-pxc56) or via our support channel: [https://support.severalnines.com](https://support.severalnines.com)