#!/bin/bash
#
# Licensed to the Apache Software Foundation (ASF) under one or more
# contributor license agreements.  See the NOTICE file distributed with
# this work for additional information regarding copyright ownership.
# The ASF licenses this file to You under the Apache License, Version 2.0
# (the "License"); you may not use this file except in compliance with
# the License.  You may obtain a copy of the License at
#
#    http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#
# Specifically, this script is intended SOLELY to support the Confluent
# Quick Start offering in Amazon Web Services. It is not recommended
# for use in any other production environment.
#
#
#
#
# Generate the clusters hosts files for a AWS Cloudformation Stack.
# If no stack is given, we try to figure out out from tags of this
# instance.
#
# The assumption is that the Cloudformation Stack deploys 1 or more
# autoscaling groups.
#	BrokerNodes	(/tmp/brokers)
#	ZookeeperNodes	(/tmp/zookeepers)
#	WorkerNodes	(/tmp/workers)
#
# The complete list of hosts for this stack is saved
# to CP_HOSTS_FILE (default is /tmp/cphosts)
#
# Zookeeper nodes and Worker nodes are optional.  If no instances for
# those autoscaling groups are found, the node list will default to
# the list from /tmp/brokers.

murl_top=http://169.254.169.254/latest/meta-data

CP_HOSTS_FILE=${CP_HOSTS_FILE:-/tmp/cphosts}

ThisInstance=$(curl -f $murl_top/instance-id 2> /dev/null)
if [ -z "$ThisInstance" ] ; then
	ThisInstance="unknown"
fi

ThisRegion=$(curl -f $murl_top/placement/availability-zone 2> /dev/null)
if [ -z "$ThisRegion" ] ; then
	ThisRegion="us-east-1"
else
	ThisRegion="${ThisRegion%[a-z]}"
fi

ThisKeyPair=$(aws ec2 describe-instances --region $ThisRegion --output text --instance-ids $ThisInstance --query 'Reservations[].Instances[].KeyName')

if [ -z "${1}" ] ; then
	ThisStack=$(aws ec2 describe-instances --region $ThisRegion --output text --instance-ids $ThisInstance --query 'Reservations[].Instances[].Tags[?Key==`aws:cloudformation:stack-name`].Value ')
else
	ThisStack=$1
fi


if [ -z "$ThisStack" ] ; then
	echo "No AWS Cloudformation Stack specified; aborting script"
	exit 1
elif [ -z "$ThisRegion" ] ; then
	echo "Failed to determine AWS region; aborting script"
	exit 1
# elif [ -z "$ThisKeyPair" ] ; then
# 	echo "No KeyPair specified; aborting script"
# 	exit 1
fi

# List out cluster_hosts in time-based launch order (with no domain spec)
# This MAY correspond to AmiLaunchIndex order, so we do our best to keep
# that ordering aligned for the different cluster roles (remember that we
# may have multiple AutoScalingGroups comprising a single cluster).
#	NOTE: I don't think there's a way for two stacks with the same
#	name to be deployed in the same region with different keys
#	(even with IAM users), but we could do the extra filtering
#	on KeyName if necessary.
# ISSUE 46: tag:Name has been added to the output of this command to be used
# later in this script for BROKERNODE labeling.
#
aws ec2 describe-instances --output text --region $ThisRegion \
  --filters 'Name=instance-state-name,Values=running,stopped' \
  --query 'Reservations[].Instances[].[PrivateDnsName,InstanceId,LaunchTime,AmiLaunchIndex,KeyName,Tags[?Key == `aws:autoscaling:groupName`] | [0].Value,Tags[?Key == `Name`] | [0].Value]' \
  | grep -w "$ThisStack" | sort -k 3,4 \
  | awk '{split ($1,fqdn,"."); print fqdn[1]" "$2" "$3" "$4" "$5" "$6" "$7}' \
  > ${CP_HOSTS_FILE}

# Now we have the hosts from this stack ... divide them into the
# our node roles.
#

# Since this script only runs on nodes we've deployed via Cloudformation,
# this should never happen ... but let's be REALLY SURE we have nodes

total_nodes=$(cat ${CP_HOSTS_FILE} | wc -l)
if [ ${total_nodes:-0} -lt 1 ] ; then
	echo "No nodes found in  Cloudformation Stack; aborting script"
	exit 1
fi

# We have two different Cloudformation models, one flat and one nested.
# The different models will have slightly different labels for the
# nodes associated with each group ... but it's simple to handle both cases.
#
# ISSUE-46 See: https://github.com/aws-quickstart/quickstart-confluent-kafka/issues/46
# This area has been reworked to grep the CP_HOSTS_FILE for the tag:Name that would exist
# if a cluster already exists. This can happen when a node was shut down by AWS
# because it was failing the health checks. The auto scaling group will automatically
# bring up another instance, however, the script would just blindly pick the highest number
# based off of the launch time. This will now look for existing nodes by tag:Name
# (i.e. cluster-name-broker-0, cluster-name-worker-0, etc.) and automatically fill
# in the gaps of the existing nodes. If the stack is just starting up, the tag:Name will
# not exist, and you'll get 'None' as the value for the tag:Name. We will pick up the
# nodes in launch order and assign the nodes in the same order as it was done previously.
#

grep -q -e "-BrokerNodes-" -e "-BrokerStack-" ${CP_HOSTS_FILE}
if [ $? -eq 0 ] ; then
    line=0
    replacement=1
    while [ $line -lt $total_nodes ]; do
        grep -q -e "broker-$line" ${CP_HOSTS_FILE}
        if [ $? -eq 0 ] ; then
            awk -v p="broker-$line" -v line="$line" '$0~p{print $1" BROKERNODE"line" "$2" "$3" "$4; exit}' ${CP_HOSTS_FILE} >> /tmp/brokers
        else
            grep -e "-BrokerNodes-.*None" -e "-BrokerStack-.*None" ${CP_HOSTS_FILE} | \
                awk -v p="None" -v n="$replacement" -v line="$line" '$0~p{i++}i==n{print $1" BROKERNODE"line" "$2" "$3" "$4; exit}' >> /tmp/brokers
            replacement=$((replacement + 1))
        fi
        line=$((line + 1))
    done
else
	cp ${CP_HOSTS_FILE} /tmp/brokers
fi

grep -q -e "-ZookeeperNodes-" -e "-ZookeeperStack-" ${CP_HOSTS_FILE}
if [ $? -eq 0 ] ; then
    line=0
    replacement=1
    while [ $line -lt $total_nodes ]; do
        grep -q -e "zookeeper-$line" ${CP_HOSTS_FILE}
        if [ $? -eq 0 ] ; then
            awk -v p="zookeeper-$line" -v line="$line" '$0~p{print $1" ZOOKEEPERNODE"line" "$2" "$3" "$4; exit}' ${CP_HOSTS_FILE} >> /tmp/zookeepers
        else
            grep -e "-ZookeeperNodes-.*None" -e "-ZookeeperStack-.*None" ${CP_HOSTS_FILE} | \
                awk -v p="None" -v n="$replacement" -v line="$line" '$0~p{i++}i==n{print $1" ZOOKEEPERNODE"line" "$2" "$3" "$4; exit}' >> /tmp/zookeepers
            replacement=$((replacement + 1))
        fi
        line=$((line + 1))
    done
else
	head -3 /tmp/brokers > /tmp/zookeepers
fi

grep -q -e "-WorkerNodes-" -e "-WorkerStack-" ${CP_HOSTS_FILE}
if [ $? -eq 0 ] ; then
    line=0
    replacement=1
    while [ $line -lt $total_nodes ]; do
        grep -q -e "worker-$line" ${CP_HOSTS_FILE}
        if [ $? -eq 0 ] ; then
            awk -v p="worker-$line" -v line="$line" '$0~p{print $1" WORKERNODE"line" "$2" "$3" "$4; exit}' ${CP_HOSTS_FILE} >> /tmp/workers
        else
            grep -e "-WorkerNodes-.*None" -e "-WorkerStack-.*None" ${CP_HOSTS_FILE} | \
                awk -v p="None" -v n="$replacement" -v line="$line" '$0~p{i++}i==n{print $1" WORKERNODE"line" "$2" "$3" "$4; exit}' >> /tmp/workers
            replacement=$((replacement + 1))
        fi
        line=$((line + 1))
    done
else
	cp /tmp/brokers /tmp/workers
fi

