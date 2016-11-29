#!/bin/bash
set -e

# if command starts with an option, prepend mysqld
if [ "${1:0:1}" = '-' ]; then
	CMDARG="$@"
fi

[ -z "$TTL" ] && TTL=30

if [ -z "$CLUSTER_NAME" ]; then
	echo >&2 'Error:  You need to specify CLUSTER_NAME'
	exit 1
fi
	# Get config
	DATADIR="$("mysqld" --verbose --help 2>/dev/null | awk '$1 == "datadir" { print $2; exit }')"
	echo "Content of $DATADIR:"
	ls -al $DATADIR

	if [ ! -s "$DATADIR/grastate.dat" ]; then
		if [ -z "$MYSQL_ROOT_PASSWORD" -a -z "$MYSQL_ALLOW_EMPTY_PASSWORD" -a -z "$MYSQL_RANDOM_ROOT_PASSWORD" ]; then
                        echo >&2 'error: database is uninitialized and password option is not specified '
                        echo >&2 '  You need to specify one of MYSQL_ROOT_PASSWORD, MYSQL_ALLOW_EMPTY_PASSWORD and MYSQL_RANDOM_ROOT_PASSWORD'
                        exit 1
                fi
		mkdir -p "$DATADIR"
		chown -R mysql:mysql "$DATADIR"

		echo 'Running mysql_install_db'
		mysql_install_db --user=mysql --datadir="$DATADIR" --rpm --keep-my-cnf
		echo 'Finished mysql_install_db'

		mysqld --user=mysql --datadir="$DATADIR" --skip-networking &
		pid="$!"

		mysql=( mysql --protocol=socket -uroot )

		for i in {30..0}; do
			if echo 'SELECT 1' | "${mysql[@]}" &> /dev/null; then
				break
			fi
			echo 'MySQL init process in progress...'
			sleep 1
		done
		if [ "$i" = 0 ]; then
			echo >&2 'MySQL init process failed.'
			exit 1
		fi

		# sed is for https://bugs.mysql.com/bug.php?id=20545
		mysql_tzinfo_to_sql /usr/share/zoneinfo | sed 's/Local time zone must be set--see zic manual page/FCTY/' | "${mysql[@]}" mysql
		if [ ! -z "$MYSQL_RANDOM_ROOT_PASSWORD" ]; then
			MYSQL_ROOT_PASSWORD="$(pwmake 128)"
			echo "GENERATED ROOT PASSWORD: $MYSQL_ROOT_PASSWORD"
		fi
		"${mysql[@]}" <<-EOSQL
			-- What's done in this file shouldn't be replicated
			--  or products like mysql-fabric won't work
			SET @@SESSION.SQL_LOG_BIN=0;
			DELETE FROM mysql.user ;
			CREATE USER 'root'@'%' IDENTIFIED BY '${MYSQL_ROOT_PASSWORD}' ;
			GRANT ALL ON *.* TO 'root'@'%' WITH GRANT OPTION ;
			CREATE USER 'xtrabackup'@'localhost' IDENTIFIED BY '$XTRABACKUP_PASSWORD';
			GRANT RELOAD,LOCK TABLES,REPLICATION CLIENT ON *.* TO 'xtrabackup'@'localhost';
			GRANT REPLICATION CLIENT ON *.* TO monitor@'%' IDENTIFIED BY 'monitor';
			DROP DATABASE IF EXISTS test ;
			FLUSH PRIVILEGES ;
		EOSQL
		if [ ! -z "$MYSQL_ROOT_PASSWORD" ]; then
			mysql+=( -p"${MYSQL_ROOT_PASSWORD}" )
		fi

		if [ "$MYSQL_DATABASE" ]; then
			echo "CREATE DATABASE IF NOT EXISTS \`$MYSQL_DATABASE\` ;" | "${mysql[@]}"
			mysql+=( "$MYSQL_DATABASE" )
		fi

		if [ "$MYSQL_USER" -a "$MYSQL_PASSWORD" ]; then
			echo "CREATE USER '"$MYSQL_USER"'@'%' IDENTIFIED BY '"$MYSQL_PASSWORD"' ;" | "${mysql[@]}"

			if [ "$MYSQL_DATABASE" ]; then
				echo "GRANT ALL ON \`"$MYSQL_DATABASE"\`.* TO '"$MYSQL_USER"'@'%' ;" | "${mysql[@]}"
			fi

			echo 'FLUSH PRIVILEGES ;' | "${mysql[@]}"
		fi

		if [ ! -z "$MYSQL_ONETIME_PASSWORD" ]; then
			"${mysql[@]}" <<-EOSQL
				ALTER USER 'root'@'%' PASSWORD EXPIRE;
			EOSQL
		fi
		if ! kill -s TERM "$pid" || ! wait "$pid"; then
			echo >&2 'MySQL init process failed.'
			exit 1
		fi

		echo
		echo 'MySQL init process done. Ready for start up.'
		echo
	fi
	chown -R mysql:mysql "$DATADIR"

function join { local IFS="$1"; shift; echo "$*"; }

if [ -z "$DISCOVERY_SERVICE" ]; then
	cluster_join=$CLUSTER_JOIN
else
	echo
	echo '>> Registering in the discovery service'

	etcd_hosts=$(echo $DISCOVERY_SERVICE | tr ',' ' ')
	flag=1

	echo
	# Loop to find a healthy etcd host
	for i in $etcd_hosts
	do
		echo ">> Connecting to http://$i"
		curl -s http://$i/health || continue
		if curl -s http://$i/health | jq -e 'contains({ "health": "true"})'; then
			healthy_etcd=$i
			flag=0
			break
		else
			echo >&2 ">> Node $i is unhealty. Proceed to the next node."
		fi
	done

	# Flag is 0 if there is a healthy etcd host
	if [ $flag -ne 0 ]; then
		echo ">> Couldn't reach healthy etcd nodes."
		exit 1
	fi

	echo 
	echo ">> Selected healthy etcd: $healthy_etcd"

	if [ ! -z "$healthy_etcd" ]; then
		URL="http://$healthy_etcd/v2/keys/galera/$CLUSTER_NAME"

		set +e
		# Read the list of registered IP addresses
		echo >&2 ">> Retrieving list of keys for $CLUSTER_NAME"
		sleep $[ ( $RANDOM % 5 )  + 1 ]s
		addr=$(curl -s $URL | jq -r '.node.nodes[]?.key' | awk -F'/' '{print $(NF)}')
		cluster_join=$(join , $addr)

		ipaddr=$(hostname -I | awk {'print $1'})

		echo
		if [ -z $cluster_join ]; then
			echo >&2 ">> Cluster address is empty. This is a the first node to come up."
			echo 
			echo >&2 ">> Registering $ipaddr in http://$healthy_etcd"
			curl -s $URL/$ipaddr/ipaddress -X PUT -d "value=$ipaddr"
		else
			curl -s ${URL}?recursive=true\&sorted=true > /tmp/out
			running_nodes=$(cat /tmp/out | jq -r '.node.nodes[].nodes[] | select(.key | contains ("wsrep_local_state_comment")) | select(.value == "Synced") | .key' | awk -F'/' '{print $(NF-1)}' | tr "\n" ' '| sed -e 's/[[:space:]]*$//')
			echo
			echo ">> Running nodes: [${running_nodes}]"

			if [ -z "$running_nodes" ]; then
				# if there is no Synced node, determine the sequence number.
                                TMP=/tmp/wsrep-recover
                                echo >&2 ">> There is no node in synced state."
				echo >&2 ">> It's unsafe to bootstrap unless the sequence number is the latest."
                                echo >&2 ">> Determining the Galera last committed seqno.."
				echo
                                mysqld_safe --wsrep-recover 2>&1 | tee $TMP
                                seqno=$(cat $TMP | tr ' ' "\n" | grep -e '[a-z0-9]*-[a-z0-9]*:[0-9]' | head -1 | cut -d ":" -f 2)
				echo
                                if [ ! -z $seqno ]; then
                                        echo ">> Reporting seqno:$seqno to ${healthy_etcd}."
                                        WAIT=$(($TTL * 2))
                                        curl -s $URL/$ipaddr/seqno -X PUT -d "value=$seqno&ttl=$WAIT"
                                else
                                        echo ">> Unable to determine Galera sequence number."
                                        exit 1
                                fi
                                rm $TMP

                                echo
                                echo ">> Sleeping for $TTL seconds to wait for other nodes to report."
                                sleep $TTL

                                echo
                                echo >&2 ">> Retrieving list of seqno for $CLUSTER_NAME"
                                bootstrap_flag=1
				cluster_seqno=$(curl -s "${URL}?recursive=true\&sorted=true" | jq -r '.node.nodes[].nodes[] | select(.key | contains ("seqno")) | .value' | tr '\n' ' ')

                                for i in $cluster_seqno; do
                                        if [ $i -gt $seqno ]; then
                                                bootstrap_flag=0
                                                echo >&2 ">> Found another node holding a greater seqno ($i/$seqno)"
                                        fi
                                done

				echo
                                if [ $bootstrap_flag -eq 1 ]; then
                                        echo >&2 ">> This node is safe to bootstrap."
                                        cluster_join=
                                else
                                        echo >&2 ">> Refusing to start for now."
                                        echo >&2 ">> Wait again for $TTL seconds to look for a bootstrapped node."
                                        sleep $TTL
					curl -s ${URL}?recursive=true\&sorted=true > /tmp/out
					running_nodes2=$(cat /tmp/out | jq -r '.node.nodes[].nodes[] | select(.key | contains ("wsrep_local_state_comment")) | select(.value == "Synced") | .key' | awk -F'/' '{print $(NF-1)}' | tr "\n" ' '| sed -e 's/[[:space:]]*$//')

					echo
					echo ">> Running nodes: [${running_nodes2}]"

					if [ ! -z "$running_nodes2" ]; then
						cluster_join=$(join , $running_nodes2)
					else
						echo
						echo >&2 ">> Unable to find a bootstrapped node to join."
						echo >&2 ">> Exiting."
						exit 1
					fi
                                fi
			else
				# if there is a Synced node, join the address
				cluster_join=$(join , $running_nodes)
			fi
		
		fi
		set -e
		
		echo 
		echo >&2 ">> Cluster address is gcomm://$cluster_join"
	else
		echo
		echo >&2 '>> No healthy etcd host detected. Refused to start.'
		exit 1
	fi
fi

echo 
echo ">> Starting reporting script in the background"
nohup /report_status.sh root $MYSQL_ROOT_PASSWORD $CLUSTER_NAME $TTL $DISCOVERY_SERVICE &

echo
echo ">> Starting mysqld process"
mysqld --user=mysql --wsrep_cluster_name=$CLUSTER_NAME --wsrep_cluster_address="gcomm://$cluster_join" --wsrep_sst_method=xtrabackup-v2 --wsrep_sst_auth="xtrabackup:$XTRABACKUP_PASSWORD" --log-error=${DATADIR}error.log $CMDARG

